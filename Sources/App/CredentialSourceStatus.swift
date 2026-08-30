import Foundation

/// Cheap, local-only "is a CLI login present" check per service (ТЗ §6, §7),
/// shared by the onboarding screen and the Settings "Services" list so the
/// two surfaces never drift. Wraps each provider's `hasLocalCredentials()`
/// (no network, per the frozen `UsageProvider` contract) using a **silent**
/// Claude auth store so opening Settings/onboarding never itself raises a
/// Keychain "allow access" dialog — the same silent/interactive split
/// `AppDelegate.makeUsageCoordinator` already uses for polling.
enum CredentialSourceStatus {
    /// Fine-grained result of a credential-source check (ТЗ §7 addendum). A
    /// plain found/not-found conflates "found" (a login exists and is
    /// readable) with "found in the Keychain, but Mana lacks permission to
    /// read it silently yet" — this splits the middle case out so onboarding
    /// and Settings can explain it distinctly, instead of it either silently
    /// showing "Found" (misleading — it won't actually work until the grant)
    /// or landing under "Not found" (also misleading — no re-login needed).
    enum Finding: Equatable, Sendable {
        case notFound
        /// A Keychain item is confirmed present, but reading it silently is
        /// denied, and no other credential source can serve usage either. One
        /// interactive "Refresh Now" + "Always Allow" fixes this permanently.
        case needsKeychainPermission
        case found
    }

    private static let claudeSilentAuth = ClaudeAuthStore(allowsKeychainInteraction: false)
    private static let codexSilentAuth = CodexAuthStore(allowsKeychainInteraction: false)
    private static let cursorSilentAuth = CursorAuthStore(allowsKeychainInteraction: false)

    /// Whether a local credential source was found for `serviceID`.
    /// `.needsKeychainPermission` counts as found here — a login does exist,
    /// it is a permission gate rather than a missing login. Callers that want
    /// the distinction should use `status(_:)` instead.
    static func check(_ serviceID: ServiceID) async -> Bool {
        await status(serviceID) != .notFound
    }

    /// Fine-grained check (ТЗ §7 addendum): distinguishes "found and
    /// readable" from "found but needs a one-time Keychain grant" from "not
    /// found at all". Uses the same silent auth stores `hasLocalCredentials`
    /// does, so opening Settings/onboarding never itself raises a Keychain
    /// dialog.
    static func status(_ serviceID: ServiceID) async -> Finding {
        switch serviceID {
        case .claude:
            if !claudeSilentAuth.loadCredentials().isEmpty { return .found }
            return claudeSilentAuth.keychainAccessIsDenied() ? .needsKeychainPermission : .notFound
        case .chatgpt:
            if !codexSilentAuth.loadCredentials().isEmpty { return .found }
            return codexSilentAuth.keychainAccessIsDenied() ? .needsKeychainPermission : .notFound
        case .cursor:
            if !cursorSilentAuth.loadCredentials().isEmpty { return .found }
            return cursorSilentAuth.keychainAccessIsDenied() ? .needsKeychainPermission : .notFound
        }
    }

    /// Short "install & log in" hint shown for `.notFound`
    /// (ТЗ §7: "подсказка, что установить и куда залогиниться").
    static func hint(_ serviceID: ServiceID) -> String {
        switch serviceID {
        case .claude: return "Install Claude Code and run `claude` in a terminal to log in."
        case .chatgpt: return "Install the Codex CLI and run `codex` in a terminal to log in."
        case .cursor: return "Install Cursor and sign in to your account in the app."
        }
    }

    /// Shown for `.needsKeychainPermission`: the login is already there, only
    /// a one-time Keychain grant is missing.
    static func permissionHint(_ serviceID: ServiceID) -> String {
        "Found in Keychain, but Mana needs one-time access — click \u{201C}Refresh Now\u{201D} and choose \u{201C}Always Allow\u{201D}."
    }
}
