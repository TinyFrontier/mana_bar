import Foundation

/// `UsageProvider` for Claude (Pro/Max/Team), reading the OAuth login that
/// Claude Code — or, optionally, Claude Desktop — already holds on this machine
/// (ТЗ §4.1, §4.2). The user is never asked to paste a token.
///
/// Split follows the reference architecture (research doc §3.2):
/// `ClaudeAuthStore` finds credentials, `ClaudeUsageClient` performs HTTP,
/// `ClaudeUsageMapper` produces `ServiceUsage`. This type only sequences them:
/// pick a credential → refresh if needed → fetch with one retry → map, falling
/// through to the next credential source when a token turns out to be dead.
///
/// Keeping the last good snapshot on failure and honouring a rate-limit cooldown
/// belong to the store layer above (research doc §9.2 п.1, п.4); this provider
/// reports errors truthfully, including `retryAfter` on a 429.
struct ClaudeProvider: UsageProvider {
    let serviceID: ServiceID = .claude

    var authStore: ClaudeAuthStore
    var usageClient: ClaudeUsageClient
    var now: @Sendable () -> Date

    init(
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        usageClient: ClaudeUsageClient = ClaudeUsageClient(),
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
        let credentials = authStore.loadCredentials().filter(\.hasUsableAccessToken)
        guard !credentials.isEmpty else {
            // A Keychain item that exists but could not be read silently must
            // not be reported as "not logged in" — the fix is one interactive
            // grant, not a re-login (research doc: silent-path Keychain fix).
            throw authStore.keychainAccessIsDenied() ? UsageError.keychainAccessDenied : UsageError.notLoggedIn
        }

        var fallbackError: UsageError?
        for credential in credentials {
            do {
                return try await fetchUsage(with: credential)
            } catch let error as UsageError where Self.allowsCredentialFallback(error) {
                // A stale token in the preferred source must not shadow a fresh
                // `claude` login that landed in another one (research doc §4.5).
                fallbackError = error
                continue
            }
        }
        throw fallbackError ?? UsageError.notLoggedIn
    }

    /// Only a bad-token error is worth retrying against the next source. A 429,
    /// a transport failure or a 5xx would just repeat — and hammering a
    /// rate-limited endpoint makes the limit worse (research doc §9.2 п.4).
    private static func allowsCredentialFallback(_ error: UsageError) -> Bool {
        switch error {
        case .sessionExpired, .missingScope, .notLoggedIn, .keychainAccessDenied:
            return true
        case .rateLimited, .requestFailed, .connectionFailed, .decodingFailed:
            return false
        }
    }

    private func fetchUsage(with credential: ClaudeCredential) async throws -> ServiceUsage {
        // A token minted by `claude setup-token` can run inference but has no
        // `user:profile` scope, so the usage endpoint would reject it. Say so
        // instead of burning a request (research doc §9.3).
        guard authStore.liveUsageAvailability(credential) == .available else {
            throw UsageError.missingScope
        }
        guard var accessToken = credential.oauth.accessToken?.nilIfBlank else {
            throw UsageError.notLoggedIn
        }

        var current = credential
        if authStore.needsRefresh(current.oauth) {
            accessToken = try await renewToken(&current, currentToken: accessToken)
        }

        // The token the first attempt uses, so the 401/403 path can tell "the CLI
        // already replaced it" from "we must refresh it ourselves".
        let attemptToken = accessToken
        let response = try await ProviderAuthRetry.fetch(
            token: attemptToken,
            attempt: { try await usageClient.fetchUsage(accessToken: $0) },
            refreshAccessToken: { try await renewToken(&current, currentToken: attemptToken) }
        )
        try ProviderAuthRetry.requireSuccess(response, now: now())

        return try ClaudeUsageMapper.map(
            body: response.body,
            credentials: current.oauth,
            now: now()
        )
    }

    /// Produces a usable access token, preferring one the CLI already rotated in
    /// on disk over minting our own.
    ///
    /// Re-reading first is mandatory (ТЗ §4.2): `claude` may have rotated the
    /// token between our read and now, and replaying a spent refresh token can
    /// invalidate the user's legitimate CLI session.
    private func renewToken(
        _ credential: inout ClaudeCredential,
        currentToken: String?
    ) async throws -> String {
        if let live = authStore.reload(credential.source),
           let liveToken = live.oauth.accessToken?.nilIfBlank,
           liveToken != currentToken {
            credential = live
            if !authStore.needsRefresh(live.oauth) { return liveToken }
        }

        guard credential.canRefresh,
              let refreshToken = credential.oauth.refreshToken?.nilIfBlank
        else {
            // Claude Desktop tokens have no usable refresh path by design, and a
            // login with no refresh token can only be renewed by the CLI itself.
            if let token = credential.oauth.accessToken?.nilIfBlank, token != currentToken {
                return token
            }
            throw UsageError.sessionExpired
        }

        let refreshed = try await usageClient.refresh(refreshToken: refreshToken)
        var updated = credential
        updated.oauth.accessToken = refreshed.accessToken
        if let rotated = refreshed.refreshToken {
            updated.oauth.refreshToken = rotated
        }
        if let expiresIn = refreshed.expiresIn {
            updated.oauth.expiresAt = now().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }
        // Best-effort write-back to the same source; a conflicting rotation by
        // the CLI is skipped silently (ТЗ §4.2).
        authStore.persistRotation(updated, expectedRefreshToken: refreshToken)
        credential = updated
        return refreshed.accessToken
    }
}
