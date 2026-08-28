import Foundation
import LocalAuthentication
import Security

/// Read/write access to macOS Keychain generic-password items.
///
/// Mana does **not** keep secrets of its own (ТЗ §4.2): OAuth tokens are read
/// on demand out of the Keychain entries that the CLI tools (`claude`, `codex`)
/// already own, and a rotated token is written back to that same entry. This
/// type is the single place that talks to the Security framework, so the
/// provider-side auth stores stay testable behind `KeychainReading`.
///
/// Security note: values returned here are credential blobs. They must never be
/// logged, cached to disk, or copied into UserDefaults — not even in debug.
protocol KeychainReading: Sendable {
    /// Reads a generic-password item. `nil` means "no such item"; a throw means
    /// the lookup itself failed (locked keychain, denied access, cancelled
    /// prompt) — which is NOT the same as "not logged in".
    ///
    /// `allowInteraction: false` forbids any system UI, so a background poll can
    /// never pop another app's Keychain prompt at the user (research doc §4.1):
    /// the read fails with `.accessDenied` instead — **promptly**, which is the
    /// part a background poll depends on. An item this process is not authorized
    /// to read is therefore indistinguishable, on the silent path, from an item
    /// that is not there; callers treat both as "no credentials" and leave the
    /// interactive path to obtain the grant.
    func readGenericPassword(service: String, account: String?, allowInteraction: Bool) throws -> String?

    /// Attributes-only existence probe: never requests the secret and never
    /// shows UI, so it is safe on the launch path (`hasLocalCredentials()`).
    /// `nil` means the probe itself could not answer (locked/denied).
    func genericPasswordExists(service: String, account: String?) -> Bool?

    /// Creates or replaces a generic-password item.
    func writeGenericPassword(service: String, account: String?, value: String) throws
}

extension KeychainReading {
    func readGenericPassword(service: String, account: String?) throws -> String? {
        try readGenericPassword(service: service, account: account, allowInteraction: true)
    }

    func readGenericPassword(service: String) throws -> String? {
        try readGenericPassword(service: service, account: nil, allowInteraction: true)
    }

    func genericPasswordExists(service: String) -> Bool? {
        genericPasswordExists(service: service, account: nil)
    }
}

enum KeychainError: Error, Equatable {
    /// The item exists but the current process may not read it (ACL denied,
    /// keychain locked, user cancelled the prompt).
    case accessDenied
    /// Stored bytes are not UTF-8 text.
    case invalidData
    /// Any other `OSStatus` from the Security framework.
    case unhandled(OSStatus)
}

struct KeychainStore: KeychainReading {
    init() {}

    /// `SecKeychainSetUserInteractionAllowed` (see `withKeychainGate`)
    /// is **process-global**, so every Security-framework call in this type is
    /// serialized behind this gate: a background poll must never leave
    /// interaction disabled underneath an interactive read on another thread.
    private static let gate = NSLock()

    /// How long a silent caller waits for the gate before giving up. An
    /// interactive read holds it for as long as the user leaves the system
    /// dialog open, and a background poll must not inherit that wait.
    private static let silentGateTimeout: TimeInterval = 1

    func readGenericPassword(
        service: String,
        account: String?,
        allowInteraction: Bool
    ) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if !allowInteraction {
            // Covers the data-protection keychain. It does *not* cover the
            // legacy one — that is what `withKeychainGate` is for.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = try Self.withKeychainGate(allowInteraction: allowInteraction) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.invalidData }
            guard let text = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unhandled(status)
        }
    }

    func genericPasswordExists(service: String, account: String?) -> Bool? {
        // Attributes only — `kSecReturnData` is deliberately absent (and the
        // result pointer is `nil`), so the secret is never requested. On its own
        // that is not enough: a legacy item owned by another app still sends the
        // query through `securityd`'s authorization path — measured at 8.2 s
        // from Mana's own test binary — so the probe takes the gate too.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        let status = try? Self.withKeychainGate(allowInteraction: false) {
            SecItemCopyMatching(query as CFDictionary, nil)
        }
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        // The probe could not answer — the caller decides its own safe side.
        default: return nil
        }
    }

    func writeGenericPassword(service: String, account: String?, value: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.invalidData }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        // A rotation write-back only ever follows a successful read, so it is
        // treated as interactive: it takes the gate and leaves the process-wide
        // interaction policy alone.
        let update = [kSecValueData as String: data]
        let updateStatus = try Self.withKeychainGate(allowInteraction: true) {
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = try Self.withKeychainGate(allowInteraction: true) {
                SecItemAdd(insert as CFDictionary, nil)
            }
            guard addStatus != errSecSuccess else { return }
            throw Self.writeError(addStatus)
        default:
            throw Self.writeError(updateStatus)
        }
    }

    private static func writeError(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .accessDenied
        default:
            return .unhandled(status)
        }
    }

    // MARK: - Interaction policy

    /// Runs one Security-framework call with the macOS **legacy** keychain's
    /// interaction policy pinned for its duration.
    ///
    /// This is the load-bearing part of the silent path. `claude` and `codex`
    /// keep their logins in legacy, file-based login-keychain items owned by
    /// those apps. For such items `kSecUseAuthenticationContext`
    /// (`LAContext.interactionNotAllowed`) and its predecessor
    /// `kSecUseAuthenticationUI` are **ignored** — both govern the
    /// data-protection keychain only — so a nominally silent query still went
    /// through `securityd`'s interactive authorization path. Measured from
    /// Mana's own test binary on a machine that had not been granted access to
    /// `Claude Code-credentials`: 8.2 s for the attributes-only existence probe
    /// and 6.3 s for the read, occasionally not returning at all, which is what
    /// stalled background polls past the coordinator's fetch timeout.
    ///
    /// `SecKeychainSetUserInteractionAllowed(false)` is the one switch that path
    /// honours. The same read then fails with `errSecAuthFailed` in ~30 ms,
    /// which `readGenericPassword` maps to `.accessDenied` — "the item is there,
    /// but not readable without asking the user". Callers on the silent path
    /// treat that as "no credentials" rather than waiting; the interactive
    /// "Refresh Now" path passes `allowInteraction: true` and is unaffected.
    ///
    /// The API is deprecated with no replacement for the legacy keychain, and
    /// its scope is the whole process — hence the gate.
    private static func withKeychainGate(
        allowInteraction: Bool,
        _ body: () -> OSStatus
    ) throws -> OSStatus {
        if allowInteraction {
            gate.lock()
            defer { gate.unlock() }
            return body()
        }

        guard gate.lock(before: Date().addingTimeInterval(silentGateTimeout)) else {
            // An interactive call holds the gate and its dialog may stay open
            // for minutes. Silent callers fail fast rather than queue behind it.
            throw KeychainError.accessDenied
        }
        defer { gate.unlock() }

        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        let wasAllowed = previous.boolValue
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed) }
        return body()
    }
}
