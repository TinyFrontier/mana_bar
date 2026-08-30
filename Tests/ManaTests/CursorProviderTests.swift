import XCTest
@testable import Mana

/// Cursor auth discovery, usage mapping and the provider that sequences them.
final class CursorProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    // MARK: - Auth store

    func testStateDatabaseLoginIsFound() {
        let store = makeStore(sqlite: StubSQLite(values: [
            CursorAuthStore.accessTokenKey: "state-token",
            CursorAuthStore.refreshTokenKey: "state-refresh",
            CursorAuthStore.membershipTypeKey: "pro",
        ]))

        let credential = store.loadCredentials().first
        XCTAssertEqual(credential?.accessToken, "state-token")
        XCTAssertEqual(credential?.refreshToken, "state-refresh")
        XCTAssertEqual(credential?.membershipType, "pro")
        XCTAssertEqual(credential?.source, .stateDatabase)
    }

    /// Cursor writes the same tokens to both places, and the database is the
    /// copy it keeps current — so it must outrank the Keychain, not the other
    /// way round.
    func testStateDatabaseOutranksKeychainButBothAreOffered() {
        let store = makeStore(
            sqlite: StubSQLite(values: [CursorAuthStore.accessTokenKey: "state-token"]),
            keychain: StubKeychain(items: [
                "\(CursorAuthStore.keychainAccessTokenService)\u{1}": "keychain-token",
            ])
        )

        let credentials = store.loadCredentials()
        XCTAssertEqual(credentials.map(\.accessToken), ["state-token", "keychain-token"])
        XCTAssertEqual(credentials.map(\.source), [.stateDatabase, .keychain])
    }

    /// The Keychain item is there but a silent read of it is refused: that is a
    /// one-time grant away, not a missing login.
    func testKeychainOnlyLoginThatCannotBeReadSilentlyIsAccessDenied() async {
        let keychain = StubKeychain(items: [
            "\(CursorAuthStore.keychainAccessTokenService)\u{1}": "keychain-token",
        ])
        keychain.silentReadError = .accessDenied
        let store = makeStore(sqlite: StubSQLite(), keychain: keychain, allowsInteraction: false)

        XCTAssertTrue(store.keychainAccessIsDenied())

        let provider = CursorProvider(
            authStore: store,
            usageClient: CursorUsageClient(http: StubHTTPClient([])),
            now: { self.now }
        )
        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .keychainAccessDenied)
    }

    func testNoCredentialsAnywhereIsNotLoggedIn() async {
        let provider = CursorProvider(
            authStore: makeStore(sqlite: StubSQLite()),
            usageClient: CursorUsageClient(http: StubHTTPClient([])),
            now: { self.now }
        )
        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .notLoggedIn)
    }

    /// An unreadable database (Cursor holding a write lock, file missing) must
    /// read as "no credentials here", never as a crash or an error.
    func testUnavailableDatabaseFallsBackToKeychain() {
        let sqlite = StubSQLite(values: [CursorAuthStore.accessTokenKey: "state-token"])
        sqlite.isUnavailable = true
        let store = makeStore(
            sqlite: sqlite,
            keychain: StubKeychain(items: [
                "\(CursorAuthStore.keychainAccessTokenService)\u{1}": "keychain-token",
            ])
        )

        XCTAssertEqual(store.loadCredentials().map(\.source), [.keychain])
    }

    // MARK: - Refresh policy

    /// Cursor's access token carries an `exp` its own API ignores — a token
    /// observed nearly two years past `exp` still answers the usage endpoint.
    /// Refreshing on that claim would spend a refresh token every poll and
    /// report `sessionExpired` for a login that works, so the first attempt
    /// always uses the stored token as-is.
    func testExpiredLookingTokenIsUsedAsIsWithoutAPreemptiveRefresh() async throws {
        let http = StubHTTPClient(.json(ProviderFixtures.cursorUsage(totalPercentUsed: 3)))
        let provider = CursorProvider(
            authStore: makeStore(sqlite: StubSQLite(values: [
                CursorAuthStore.accessTokenKey: expiredToken,
                CursorAuthStore.refreshTokenKey: "refresh-token",
            ])),
            usageClient: CursorUsageClient(http: http),
            now: { self.now }
        )

        _ = try await provider.fetchUsage()

        XCTAssertEqual(http.sentRequests.count, 1, "a refresh was attempted before the usage call")
        XCTAssertEqual(http.sentRequests.first?.url, CursorUsageClient.usageURL)
        XCTAssertEqual(http.sentRequests.first?.headers["Authorization"], "Bearer \(expiredToken)")
    }

    // MARK: - Mapping

    func testUsageMapsIntoABillingPeriodWindow() throws {
        let usage = try CursorUsageMapper.map(
            response: .json(ProviderFixtures.cursorUsage(totalPercentUsed: 42)),
            membershipType: "pro",
            now: now
        )

        XCTAssertEqual(usage.serviceID, .cursor)
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.windows.count, 1)

        let window = try XCTUnwrap(usage.billingPeriodWindow)
        XCTAssertEqual(window.kind, .billingPeriod)
        XCTAssertEqual(window.label, "Included usage")
        XCTAssertEqual(window.usedPercent, 42)
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1_788_243_815.253))
        XCTAssertEqual(try XCTUnwrap(window.periodDuration), 2_678_400, accuracy: 1)
    }

    /// The ring reads `primaryWindow`, and Cursor has no session window — so
    /// the billing period has to fill that role or the ring sits at zero.
    func testBillingPeriodDrivesTheRing() throws {
        let usage = try CursorUsageMapper.map(
            response: .json(ProviderFixtures.cursorUsage(totalPercentUsed: 63)),
            membershipType: nil,
            now: now
        )

        XCTAssertNil(usage.sessionWindow)
        XCTAssertEqual(usage.primaryWindow?.usedPercent, 63)
        XCTAssertEqual(try XCTUnwrap(usage.primaryFraction), 0.63, accuracy: 0.0001)
    }

    /// A separate API figure earns its own row; one that merely repeats the
    /// total does not.
    func testApiUsageBecomesASecondWindowOnlyWhenItDiffers() throws {
        let distinct = try CursorUsageMapper.map(
            response: .json(ProviderFixtures.cursorUsage(totalPercentUsed: 50, apiPercentUsed: 20)),
            membershipType: nil,
            now: now
        )
        XCTAssertEqual(distinct.windows.count, 2)
        XCTAssertEqual(distinct.windows.last?.label, "API usage")

        let identical = try CursorUsageMapper.map(
            response: .json(ProviderFixtures.cursorUsage(totalPercentUsed: 50, apiPercentUsed: 50)),
            membershipType: nil,
            now: now
        )
        XCTAssertEqual(identical.windows.count, 1)
    }

    /// Research doc §9.2 п.10: a missing figure is reported, never rendered as
    /// a 0% window — "you have used nothing" is a claim Mana cannot make.
    func testMissingPercentageIsAnErrorRatherThanAZeroWindow() {
        let body = #"{"billingCycleEnd":"1788243815253","planUsage":{}}"#
        XCTAssertUsageError(
            try CursorUsageMapper.map(response: .json(body), membershipType: nil, now: now),
            .decodingFailed("Cursor usage response carries no totalPercentUsed")
        )
    }

    func testExplicitlyDisabledUsageIsMissingScope() {
        XCTAssertUsageError(
            try CursorUsageMapper.map(
                response: .json(ProviderFixtures.cursorUsage(enabled: false)),
                membershipType: nil,
                now: now
            ),
            .missingScope
        )
    }

    func testMembershipTypeBecomesThePlanLabel() {
        XCTAssertEqual(CursorUsageMapper.planLabel("free"), "Free")
        XCTAssertEqual(CursorUsageMapper.planLabel("PRO"), "Pro")
        XCTAssertNil(CursorUsageMapper.planLabel(nil))
        XCTAssertNil(CursorUsageMapper.planLabel("  "))
    }

    // MARK: - Provider

    func testProviderFetchesUsageWithTheStateDatabaseToken() async throws {
        let http = StubHTTPClient(.json(ProviderFixtures.cursorUsage(totalPercentUsed: 12)))
        let provider = CursorProvider(
            authStore: makeStore(sqlite: StubSQLite(values: [
                CursorAuthStore.accessTokenKey: "state-token",
                CursorAuthStore.membershipTypeKey: "free",
            ])),
            usageClient: CursorUsageClient(http: http),
            now: { self.now }
        )

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.plan, "Free")
        XCTAssertEqual(usage.primaryWindow?.usedPercent, 12)

        let request = try XCTUnwrap(http.sentRequests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, CursorUsageClient.usageURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer state-token")
        XCTAssertEqual(request.headers["Connect-Protocol-Version"], "1")
    }

    /// A 401 refreshes once and retries — the same contract the other two
    /// providers hold to.
    func testExpiredTokenIsRefreshedAndTheCallRetriedOnce() async throws {
        let http = StubHTTPClient(
            .status(401),
            .json(#"{"access_token":"fresh-token"}"#),
            .json(ProviderFixtures.cursorUsage(totalPercentUsed: 7))
        )
        let provider = CursorProvider(
            authStore: makeStore(sqlite: StubSQLite(values: [
                CursorAuthStore.accessTokenKey: "stale-token",
                CursorAuthStore.refreshTokenKey: "refresh-token",
            ])),
            usageClient: CursorUsageClient(http: http),
            now: { self.now }
        )

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.primaryWindow?.usedPercent, 7)
        XCTAssertEqual(http.sentRequests.count, 3)
        XCTAssertEqual(http.sentRequests[1].url, CursorUsageClient.refreshURL)
        XCTAssertEqual(http.sentRequests[2].headers["Authorization"], "Bearer fresh-token")
    }

    /// Cursor owns both stores; a rotated token stays in memory for this
    /// session rather than being written back (CLAUDE.md, 2026-08-29).
    func testRotatedTokenIsNeverWrittenBackToCursorsOwnStores() async throws {
        let keychain = StubKeychain()
        let http = StubHTTPClient(
            .status(401),
            .json(#"{"access_token":"fresh-token","refresh_token":"rotated"}"#),
            .json(ProviderFixtures.cursorUsage())
        )
        let provider = CursorProvider(
            authStore: makeStore(
                sqlite: StubSQLite(values: [
                    CursorAuthStore.accessTokenKey: "stale-token",
                    CursorAuthStore.refreshTokenKey: "refresh-token",
                ]),
                keychain: keychain
            ),
            usageClient: CursorUsageClient(http: http),
            now: { self.now }
        )

        _ = try await provider.fetchUsage()
        XCTAssertNil(keychain.value(service: CursorAuthStore.keychainAccessTokenService))
        XCTAssertNil(keychain.value(service: CursorAuthStore.keychainRefreshTokenService))
    }

    // MARK: - Helpers

    private func makeStore(
        sqlite: StubSQLite,
        keychain: StubKeychain = StubKeychain(),
        allowsInteraction: Bool = true
    ) -> CursorAuthStore {
        CursorAuthStore(
            sqlite: sqlite,
            keychain: keychain,
            allowsKeychainInteraction: allowsInteraction,
            now: { self.now }
        )
    }

    /// A JWT whose `exp` is long past — the shape Cursor actually stores.
    private let expiredToken: String = {
        let payload = Data("{\"exp\":1725377923}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }()
}
