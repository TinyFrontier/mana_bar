import XCTest
@testable import Mana

/// End-to-end behaviour of the ChatGPT provider against a scripted HTTP client.
final class ChatGPTProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_900_000)

    private func makeProvider(
        directory: TemporaryDirectory,
        keychain: StubKeychain = StubKeychain(),
        http: StubHTTPClient
    ) -> ChatGPTProvider {
        let authStore = CodexAuthStore(
            environment: StaticEnvironment(["CODEX_HOME": directory.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            now: { self.now }
        )
        return ChatGPTProvider(
            authStore: authStore,
            usageClient: CodexUsageClient(http: http),
            now: { self.now }
        )
    }

    // MARK: - Happy path

    func testFetchesAndMapsUsage() async throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let http = StubHTTPClient(.json(ProviderFixtures.codexUsage))
        let provider = makeProvider(directory: directory, http: http)

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.serviceID, .chatgpt)
        XCTAssertEqual(usage.window(.session)?.usedPercent, 17.5)
        XCTAssertEqual(usage.window(.weekly)?.usedPercent, 63)
        XCTAssertEqual(usage.plan, "Pro 20x")

        let request = try XCTUnwrap(http.sentRequests.first)
        XCTAssertEqual(request.url, CodexUsageClient.usageURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer header.payload.signature")
        XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "acct-123")
    }

    func testAccountHeaderIsOmittedWhenTheLoginHasNoAccountID() async throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(accountID: nil), to: "auth.json")
        let http = StubHTTPClient(.json(ProviderFixtures.codexUsage))
        let provider = makeProvider(directory: directory, http: http)

        _ = try await provider.fetchUsage()
        XCTAssertNil(http.sentRequests.first?.headers["ChatGPT-Account-Id"])
    }

    func testReportsLocalCredentialsWithoutAnyNetworkCall() async {
        let directory = TemporaryDirectory(self)
        let http = StubHTTPClient([])
        let provider = makeProvider(directory: directory, http: http)
        var hasCredentials = await provider.hasLocalCredentials()
        XCTAssertFalse(hasCredentials)

        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
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

    func testRateLimitSurfacesRetryAfter() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let provider = makeProvider(
            directory: directory,
            http: StubHTTPClient(.status(429, headers: ["retry-after": "45"]))
        )
        await XCTAssertUsageErrorAsync(
            try await provider.fetchUsage(),
            .rateLimited(retryAfter: 45)
        )
    }

    func testServerErrorSurfacesTheStatusCode() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let provider = makeProvider(directory: directory, http: StubHTTPClient(.status(502)))
        await XCTAssertUsageErrorAsync(
            try await provider.fetchUsage(),
            .requestFailed(statusCode: 502)
        )
    }

    // MARK: - Refresh and retry

    func testUnauthorizedRefreshesOnceRetriesAndPersistsTheRotation() async throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let http = StubHTTPClient(
            .status(401),
            .json(#"{"access_token":"new.access.sig","refresh_token":"new-refresh"}"#),
            .json(ProviderFixtures.codexUsage)
        )
        let provider = makeProvider(directory: directory, http: http)

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.window(.session)?.usedPercent, 17.5)

        let requests = http.sentRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].url, CodexUsageClient.refreshURL)
        XCTAssertEqual(
            requests[1].headers["Content-Type"],
            "application/x-www-form-urlencoded"
        )
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer new.access.sig")

        let stored = try XCTUnwrap(directory.read("auth.json"))
        let parsed = try XCTUnwrap(CodexAuthStore.parseAuth(stored))
        XCTAssertEqual(parsed.tokens?.accessToken, "new.access.sig")
        XCTAssertEqual(parsed.tokens?.refreshToken, "new-refresh")
        XCTAssertEqual(parsed.tokens?.accountID, "acct-123")
    }

    func testASecondUnauthorizedIsSessionExpired() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let http = StubHTTPClient(
            .status(403),
            .json(#"{"access_token":"new.access.sig"}"#),
            .status(401)
        )
        let provider = makeProvider(directory: directory, http: http)

        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .sessionExpired)
        XCTAssertEqual(http.sentRequests.count, 3)
    }

    func testReusedRefreshTokenIsReportedAsSessionExpired() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let http = StubHTTPClient(
            .status(401),
            .json(#"{"error":{"code":"refresh_token_reused"}}"#, status: 400)
        )
        let provider = makeProvider(directory: directory, http: http)
        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .sessionExpired)
    }

    func testUnrecognizedRefreshFailureReportsTheStatusNotARelogin() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let http = StubHTTPClient(
            .status(401),
            .json("<html>blocked</html>", status: 400)
        )
        let provider = makeProvider(directory: directory, http: http)
        await XCTAssertUsageErrorAsync(
            try await provider.fetchUsage(),
            .requestFailed(statusCode: 400)
        )
    }

    /// The rotation the CLI performed under us must be adopted instead of
    /// replaying our own (now spent) refresh token — the `refresh_token_reused`
    /// trap from research doc §9.3.
    func testTokenRotatedByTheCLIIsAdoptedWithoutRefreshing() async throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let http = StubHTTPClient(
            .status(401),
            .json(ProviderFixtures.codexUsage)
        )
        // Between our attempt and the retry, `codex` rewrites auth.json.
        http.afterRequest = { index in
            guard index == 0 else { return }
            directory.write(
                ProviderFixtures.codexAuth(accessToken: "cli.rotated.sig"),
                to: "auth.json"
            )
        }
        let provider = makeProvider(directory: directory, http: http)

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.window(.weekly)?.usedPercent, 63)

        let requests = http.sentRequests
        // Two usage calls, and crucially NO call to the token endpoint.
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { $0.url == CodexUsageClient.refreshURL })
        XCTAssertEqual(requests[1].headers["Authorization"], "Bearer cli.rotated.sig")
    }

    // MARK: - Keychain fallback

    func testDeadFileLoginFallsThroughToTheKeychain() async throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(accessToken: "file.token.sig"), to: "auth.json")
        let keychain = StubKeychain(items: [
            "Codex Auth\u{1}": ProviderFixtures.codexAuth(accessToken: "keychain.token.sig"),
        ])
        let http = StubHTTPClient(
            .status(401),
            .json(#"{"error":{"code":"refresh_token_expired"}}"#, status: 400),
            .json(ProviderFixtures.codexUsage)
        )
        let provider = makeProvider(directory: directory, keychain: keychain, http: http)

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.window(.session)?.usedPercent, 17.5)
        XCTAssertEqual(
            http.sentRequests.last?.headers["Authorization"],
            "Bearer keychain.token.sig"
        )
    }
}
