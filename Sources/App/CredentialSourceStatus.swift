import Foundation

/// Cheap, local-only "is a CLI login present" check per service (ТЗ §6, §7),
/// shared by the onboarding screen and the Settings "Services" list so the
/// two surfaces never drift. Wraps each provider's `hasLocalCredentials()`
/// (no network, per the frozen `UsageProvider` contract) using a **silent**
/// Claude auth store so opening Settings/onboarding never itself raises a
/// Keychain "allow access" dialog — the same silent/interactive split
/// `AppDelegate.makeUsageCoordinator` already uses for polling.
enum CredentialSourceStatus {
    private static let claudeProvider = ClaudeProvider(authStore: ClaudeAuthStore(allowsKeychainInteraction: false))
    private static let chatgptProvider = ChatGPTProvider()

    /// Whether a local credential source was found for `serviceID`.
    static func check(_ serviceID: ServiceID) async -> Bool {
        switch serviceID {
        case .claude: return await claudeProvider.hasLocalCredentials()
        case .chatgpt: return await chatgptProvider.hasLocalCredentials()
        }
    }

    /// Short "install & log in" hint shown when `check` returns `false`
    /// (ТЗ §7: "подсказка, что установить и куда залогиниться").
    static func hint(_ serviceID: ServiceID) -> String {
        switch serviceID {
        case .claude: return "Install Claude Code and run `claude` in a terminal to log in."
        case .chatgpt: return "Install the Codex CLI and run `codex` in a terminal to log in."
        }
    }
}
