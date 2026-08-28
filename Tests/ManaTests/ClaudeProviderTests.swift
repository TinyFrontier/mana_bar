import XCTest
@testable import Mana

/// End-to-end provider behaviour with a scripted HTTP client: credential
/// selection, the single refresh-and-retry, rate limiting, and the
/// `UsageError` each failure maps to.
final class ClaudeProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_900_000)

    private func makeProvider(
        directory: TemporaryDirectory,
        keychain: StubKeychain = StubKeychain(),
        http: StubHTTPClient
    ) -> ClaudeProvider {
        let authStore = ClaudeAuthStore(
            environment: StaticEnvironment(["CLAUDE_CONFIG_DIR": directory.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            desktop: ClaudeDesktopAuthStore(
                files: LocalTextFileAccessor(),
                keychain: keychain,
                homeDirectory: { directory.url },
                now: { self.now }
            ),
            now: { self.now }
        )
        return ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(http: http),
            now: { self.now }
        )
    }

    // MARK: - Happy path

    func testFetchesAndMapsUsage() async throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let http = StubHTTPClient(.json(ProviderFixtures.claudeUsage))
        let provider = makeProvider(directory: directory, http: http)

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.serviceID, .claude)
        XCTAssertEqual(usage.window(.session)?.usedPercent, 42.5)
        XCTAssertEqual(usage.window(.weekly)?.usedPercent, 71)
        XCTAssertEqual(usage.plan, "Max 5x")
        XCTAssertEqual(usage.refreshedAt, now)

        let request = try XCTUnwrap(http.sentRequests.first)
        XCTAssertEqual(request.url, ClaudeUsageClient.usageURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer fake-access-token")
        XCTAssertEqual(request.headers["anthropic-beta"], "oauth-2025-04-20")
    }

    func testReportsLocalCredentialsWithoutAnyNetworkCall() async {
        let directory = TemporaryDirectory(self)
        let http = StubHTTPClient([])
        let provider = makeProvider(directory: directory, http: http)
        var hasCredentials = await provider.hasLocalCredentials()
        XCTAssertFalse(hasCredentials)

        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
        XCTAssertTrue(http.sentRequests.isEmpty)
    }

    // MARK: - Failure mapping

    func testNoCredentialsIsNotLoggedIn() async {
        let directory = TemporaryDirectory(self)
        let provider = makeProvider(directory: directory, http: StubHTTPClient([]))
        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .notLoggedIn)
    }

    func testTokenWithoutProfileScopeIsMissingScopeAndSkipsTheNetwork() async {
        let directory = TemporaryDirectory(self)
        directory.write(
            ProviderFixtures.claudeCredentials(scopes: ["user:inference"]),
            to: ".credentials.json"
        )
        let http = StubHTTPClient([])
        let provider = makeProvider(directory: directory, http: http)

        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .missingScope)
        XCTAssertTrue(http.sentRequests.isEmpty)
    }

    func testRateLimitSurfacesRetryAfter() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let http = StubHTTPClient(.status(429, headers: ["Retry-After": "90"]))
        let provider = makeProvider(directory: directory, http: http)

        // The cooldown itself belongs to the store layer; the provider's job is
        // to report the delay truthfully.
        await XCTAssertUsageErrorAsync(
            try await provider.fetchUsage(),
            .rateLimited(retryAfter: 90)
        )
    }

    func testServerErrorSurfacesTheStatusCode() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let provider = makeProvider(
            directory: directory,
            http: StubHTTPClient(.status(503))
        )
        await XCTAssertUsageErrorAsync(
            try await provider.fetchUsage(),
            .requestFailed(statusCode: 503)
        )
    }

    func testTransportFailureIsConnectionFailed() async {
        struct Offline: Error {}
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let provider = makeProvider(
            directory: directory,
            http: StubHTTPClient([.failure(Offline())])
        )
        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .connectionFailed)
    }

    // MARK: - Refresh and retry

    func testUnauthorizedRefreshesOnceRetriesAndPersistsTheRotation() async throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let http = StubHTTPClient(
            .status(401),
            .json(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#),
            .json(ProviderFixtures.claudeUsage)
        )
        let provider = makeProvider(directory: directory, http: http)

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.window(.session)?.usedPercent, 42.5)

        let requests = http.sentRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer fake-access-token")
        XCTAssertEqual(requests[1].url, ClaudeUsageClient.refreshURL)
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer new-access")

        // The rotated token is written back to the source it came from (ТЗ §4.2).
        let stored = try XCTUnwrap(directory.read(".credentials.json"))
        let parsed = try XCTUnwrap(ClaudeAuthStore.parseCredentials(stored))
        XCTAssertEqual(parsed.claudeAiOauth?.accessToken, "new-access")
        XCTAssertEqual(parsed.claudeAiOauth?.refreshToken, "new-refresh")
    }

    func testASecondUnauthorizedIsSessionExpired() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let http = StubHTTPClient(
            .status(401),
            .json(#"{"access_token":"new-access"}"#),
            .status(403)
        )
        let provider = makeProvider(directory: directory, http: http)

        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .sessionExpired)
        // Exactly one refresh and two usage attempts — no retry storm.
        XCTAssertEqual(http.sentRequests.count, 3)
    }

    func testInvalidGrantOnRefreshIsSessionExpired() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let http = StubHTTPClient(
            .status(401),
            .json(#"{"error":"invalid_grant"}"#, status: 400)
        )
        let provider = makeProvider(directory: directory, http: http)
        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .sessionExpired)
    }

    func testUnrecognizedRefreshFailureReportsTheStatusNotARelogin() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let http = StubHTTPClient(
            .status(401),
            .json("<html>gateway</html>", status: 400)
        )
        let provider = makeProvider(directory: directory, http: http)
        await XCTAssertUsageErrorAsync(
            try await provider.fetchUsage(),
            .requestFailed(statusCode: 400)
        )
    }

    func testCredentialWithoutARefreshTokenCannotSelfHeal() async {
        let directory = TemporaryDirectory(self)
        directory.write(
            ProviderFixtures.claudeCredentials(refreshToken: nil),
            to: ".credentials.json"
        )
        let http = StubHTTPClient(.status(401))
        let provider = makeProvider(directory: directory, http: http)

        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .sessionExpired)
        XCTAssertEqual(http.sentRequests.count, 1)
    }

    // MARK: - Credential fallback

    func testDeadKeychainLoginFallsThroughToTheFile() async throws {
        let directory = TemporaryDirectory(self)
        directory.write(
            ProviderFixtures.claudeCredentials(accessToken: "file-token"),
            to: ".credentials.json"
        )
        let keychain = StubKeychain(items: [
            "Claude Code-credentials\u{1}":
                ProviderFixtures.claudeCredentials(accessToken: "keychain-token"),
        ])
        let http = StubHTTPClient(
            // Keychain credential: 401, refresh rejected, dead.
            .status(401),
            .json(#"{"error":"invalid_grant"}"#, status: 400),
            // File credential: works.
            .json(ProviderFixtures.claudeUsage)
        )
        let provider = makeProvider(directory: directory, keychain: keychain, http: http)

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.window(.weekly)?.usedPercent, 71)
        XCTAssertEqual(http.sentRequests.last?.headers["Authorization"], "Bearer file-token")
    }

    func testRateLimitDoesNotBurnTheNextCredential() async {
        let directory = TemporaryDirectory(self)
        directory.write(
            ProviderFixtures.claudeCredentials(accessToken: "file-token"),
            to: ".credentials.json"
        )
        let keychain = StubKeychain(items: [
            "Claude Code-credentials\u{1}":
                ProviderFixtures.claudeCredentials(accessToken: "keychain-token"),
        ])
        let http = StubHTTPClient(.status(429, headers: ["Retry-After": "30"]))
        let provider = makeProvider(directory: directory, keychain: keychain, http: http)

        await XCTAssertUsageErrorAsync(
            try await provider.fetchUsage(),
            .rateLimited(retryAfter: 30)
        )
        // Hammering an already rate-limited endpoint with the next credential
        // would only make the limit worse.
        XCTAssertEqual(http.sentRequests.count, 1)
    }
}
