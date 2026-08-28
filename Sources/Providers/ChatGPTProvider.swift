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

    func fetchUsage() async throws -> ServiceUsage {
        // TODO: read session cookie from Keychain, call the chatgpt.com usage
        // endpoint, parse session/weekly percentages + reset timestamps,
        // and map network/auth failures to `ServiceUsage.state == .error`.
        fatalError("ChatGPTProvider.fetchUsage() not implemented — setup-phase stub")
    }
}
