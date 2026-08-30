import Foundation

/// `UsageProvider` for Cursor, reading the login the Cursor app already holds
/// on this machine (ТЗ §4.1 applied to Cursor). The user is never asked to
/// paste a token or a cookie.
///
/// Same three-part split as the Claude and ChatGPT sides: auth store → usage
/// client → mapper, sequenced here.
struct CursorProvider: UsageProvider {
    let serviceID: ServiceID = .cursor

    var authStore: CursorAuthStore
    var usageClient: CursorUsageClient
    var now: @Sendable () -> Date

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        usageClient: CursorUsageClient = CursorUsageClient(),
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
            // A Keychain item that exists but could not be read silently is a
            // missing grant, not a missing login — the same distinction the
            // other two providers make.
            throw authStore.keychainAccessIsDenied() ? UsageError.keychainAccessDenied : UsageError.notLoggedIn
        }

        var fallbackError: UsageError?
        for credential in credentials {
            do {
                return try await fetchUsage(with: credential)
            } catch let error as UsageError where Self.allowsCredentialFallback(error) {
                // A stale token in the state database must not shadow a fresh
                // one in the Keychain, or the other way round.
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

    private func fetchUsage(with credential: CursorCredential) async throws -> ServiceUsage {
        var current = credential

        // No preemptive refresh, deliberately. Cursor's access token carries an
        // `exp` that its own API ignores — a token observed nearly two years
        // past `exp` still answers `GetCurrentPeriodUsage` — so refreshing on
        // that claim would burn a refresh token on every poll and report
        // `sessionExpired` for a login that works. The 401/403 retry below is
        // what decides a token is actually dead.
        let attemptToken = current.accessToken
        let response = try await ProviderAuthRetry.fetch(
            token: attemptToken,
            attempt: { try await usageClient.fetchUsage(accessToken: $0) },
            refreshAccessToken: { try await renewToken(&current) }
        )
        try ProviderAuthRetry.requireSuccess(response, now: now())

        return try CursorUsageMapper.map(
            response: response,
            membershipType: current.membershipType,
            now: now()
        )
    }

    /// Re-read the source before refreshing: Cursor rotates its own token in
    /// the background, and replaying a spent refresh token would invalidate the
    /// session the app itself is using.
    ///
    /// The refreshed token is deliberately **not** written back anywhere — both
    /// sources belong to Cursor, and rewriting them is what breaks an app's
    /// access to its own credentials (see the 2026-08-29 decision in
    /// CLAUDE.md). It lives for this session only; the next poll re-reads
    /// whatever Cursor has stored by then.
    private func renewToken(_ credential: inout CursorCredential) async throws -> String {
        let currentToken = credential.accessToken

        // Cursor may have rotated the token itself since this fetch started.
        if let live = authStore.loadCredentials().first(where: { $0.source == credential.source }),
           live.accessToken != currentToken {
            credential = live
            return live.accessToken
        }

        guard let refreshToken = credential.refreshToken?.nilIfBlank else {
            if credential.accessToken != currentToken { return credential.accessToken }
            throw UsageError.sessionExpired
        }

        let refreshed = try await usageClient.refresh(refreshToken: refreshToken)
        credential.accessToken = refreshed.accessToken
        if let rotated = refreshed.refreshToken {
            credential.refreshToken = rotated
        }
        return refreshed.accessToken
    }
}
