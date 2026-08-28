import Foundation

/// `UsageProvider` for claude.ai (Pro/Max/Team plans).
///
/// Per docs/ТЗ-Mana.md §4.1: hits the internal claude.ai usage endpoint,
/// authorized with a user-supplied session token (stored in `KeychainStore`),
/// returning 5-hour session-window and 7-day window percentages + reset
/// times. Reference implementations: Usage4Claude, AIQuotaBar, ClaUse Bar.
///
/// Setup-phase stub only — no networking yet. Not called by anything in
/// this skeleton, so the `fatalError` below is inert until the
/// implementation phase wires it up.
struct ClaudeProvider: UsageProvider {
    let serviceID: ServiceID = .claude

    // TODO: inject KeychainStore (or a token accessor) here.
    // private let keychainStore: KeychainStore

    func hasLocalCredentials() async -> Bool {
        // TODO: probe Claude Code keychain entry / ~/.claude/.credentials.json /
        // Claude Desktop safe storage (ТЗ §4.2).
        false
    }

    func fetchUsage() async throws -> ServiceUsage {
        // TODO: discover OAuth token (Claude Code CLI / Claude Desktop), call
        // api.anthropic.com/api/oauth/usage, map five_hour/seven_day/limits
        // into UsageWindow values (ТЗ §4.1, research doc §4).
        fatalError("ClaudeProvider.fetchUsage() not implemented — setup-phase stub")
    }
}
