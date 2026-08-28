import Foundation

/// `UsageProvider` for chatgpt.com.
///
/// Per docs/ТЗ-Mana.md §4.1: analogous to `ClaudeProvider`, authorized via a
/// chatgpt.com session cookie (stored in `KeychainStore`). Reference
/// implementation: AIQuotaBar.
///
/// Setup-phase stub only — no networking yet. Not called by anything in
/// this skeleton, so the `fatalError` below is inert until the
/// implementation phase wires it up.
struct ChatGPTProvider: UsageProvider {
    let serviceID: ServiceID = .chatgpt

    // TODO: inject KeychainStore (or a token accessor) here.
    // private let keychainStore: KeychainStore

    func hasLocalCredentials() async -> Bool {
        // TODO: probe Codex CLI auth.json / "Codex Auth" keychain entry (ТЗ §4.2).
        false
    }

    func fetchUsage() async throws -> ServiceUsage {
        // TODO: discover Codex CLI OAuth token, call
        // chatgpt.com/backend-api/wham/usage, classify windows by
        // limit_window_seconds (ТЗ §4.1, research doc §5).
        fatalError("ChatGPTProvider.fetchUsage() not implemented — setup-phase stub")
    }
}
