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
    /// the read fails with `.accessDenied` instead.
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
            // Forbids any system UI: the read fails rather than prompting.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
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
        // Attributes only — `kSecReturnData` is deliberately absent, so the
        // secret is never requested and the item's ACL is never consulted. That
        // is what keeps this prompt-free on the launch path.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        switch SecItemCopyMatching(query as CFDictionary, nil) {
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

        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
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
}
