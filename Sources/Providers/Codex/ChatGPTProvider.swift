import Foundation

/// `UsageProvider` for ChatGPT, reading the OAuth login the Codex CLI already
/// holds on this machine (ТЗ §4.1, §4.2). The user is never asked to paste a
/// token or a cookie.
///
/// Same three-part split as the Claude side (research doc §3.2): auth store →
/// usage client → mapper, sequenced here. Keeping the last good snapshot and
/// honouring a rate-limit cooldown belong to the store layer above.
struct ChatGPTProvider: UsageProvider {
    let serviceID: ServiceID = .chatgpt

    var authStore: CodexAuthStore
    var usageClient: CodexUsageClient
    var now: @Sendable () -> Date

    init(
        authStore: CodexAuthStore = CodexAuthStore(),
        usageClient: CodexUsageClient = CodexUsageClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    func hasLocalCredentials() async -> Bool {
        authStore.hasCredentialMaterial()
    }

    func fetchUsage() async throws -> ServiceUsage {
        let credentials = authStore.loadCredentials()
        guard !credentials.isEmpty else {
            // A Keychain item that exists but could not be read silently must
            // not be reported as "not logged in" — same distinction the
            // Claude provider makes.
            throw authStore.keychainAccessIsDenied() ? UsageError.keychainAccessDenied : UsageError.notLoggedIn
        }

        var fallbackError: UsageError?
        for credential in credentials {
            do {
                return try await fetchUsage(with: credential)
            } catch let error as UsageError where Self.allowsCredentialFallback(error) {
                fallbackError = error
                continue
            }
        }
        throw fallbackError ?? UsageError.notLoggedIn
    }

    private static func allowsCredentialFallback(_ error: UsageError) -> Bool {
        switch error {
        case .sessionExpired, .missingScope, .notLoggedIn, .keychainAccessDenied:
            return true
        case .rateLimited, .requestFailed, .connectionFailed, .decodingFailed:
            return false
        }
    }

    private func fetchUsage(with credential: CodexCredential) async throws -> ServiceUsage {
        // An `auth.json` holding only `OPENAI_API_KEY` is a legitimate Codex
        // setup, but API keys cannot read subscription usage — report the
        // missing capability, not a decoding error (research doc §9.3).
        if credential.isAPIKeyOnly { throw UsageError.missingScope }
        guard var accessToken = credential.auth.tokens?.accessToken?.nilIfBlank else {
            throw UsageError.notLoggedIn
        }

        var current = credential
        if authStore.needsRefresh(current.auth) {
            accessToken = try await renewToken(&current, currentToken: accessToken)
        }

        let accountID = current.accountID
        // The token the first attempt uses, so the 401/403 path can tell "the CLI
        // already replaced it" from "we must refresh it ourselves".
        let attemptToken = accessToken
        let response = try await ProviderAuthRetry.fetch(
            token: attemptToken,
            attempt: { try await usageClient.fetchUsage(accessToken: $0, accountID: accountID) },
            refreshAccessToken: { try await renewToken(&current, currentToken: attemptToken) }
        )
        try ProviderAuthRetry.requireSuccess(response, now: now())

        return try CodexUsageMapper.map(response: response, now: now())
    }

    /// Re-read the source before refreshing: the `codex` CLI rotates tokens in
    /// the background, and replaying a spent refresh token trips
    /// `refresh_token_reused` and can log the user's CLI session out
    /// (ТЗ §4.2, research doc §9.3).
    private func renewToken(
        _ credential: inout CodexCredential,
        currentToken: String?
    ) async throws -> String {
        if let live = authStore.reload(credential.source),
           let liveToken = live.auth.tokens?.accessToken?.nilIfBlank,
           liveToken != currentToken {
            credential = live
            if !authStore.needsRefresh(live.auth) { return liveToken }
        }

        guard let refreshToken = credential.auth.tokens?.refreshToken?.nilIfBlank else {
            if let token = credential.auth.tokens?.accessToken?.nilIfBlank, token != currentToken {
                return token
            }
            throw UsageError.sessionExpired
        }

        let refreshed = try await usageClient.refresh(refreshToken: refreshToken)
        var updated = credential
        updated.auth.tokens?.accessToken = refreshed.accessToken
        if let rotated = refreshed.refreshToken {
            updated.auth.tokens?.refreshToken = rotated
        }
        if let idToken = refreshed.idToken {
            updated.auth.tokens?.idToken = idToken
        }
        updated.auth.lastRefresh = ISO8601.string(from: now())
        // Best-effort; a conflicting rotation by the CLI is skipped silently.
        authStore.persistRotation(updated, expectedRefreshToken: refreshToken)
        credential = updated
        return refreshed.accessToken
    }
}
