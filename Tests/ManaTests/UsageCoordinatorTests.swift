import XCTest
@testable import Mana

/// Fully scripted `UsageProvider`: hands back queued results in order and
/// counts fetches, so the coordinator's cooldown/staleness logic can be
/// asserted without any network or real time passing.
final class FakeUsageProvider: UsageProvider, @unchecked Sendable {
    let serviceID: ServiceID

    private let lock = NSLock()
    private var queued: [Result<ServiceUsage, UsageError>]
    private var _fetchCount = 0

    var fetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _fetchCount
    }

    func enqueue(_ result: Result<ServiceUsage, UsageError>) {
        lock.lock()
        queued.append(result)
        lock.unlock()
    }

    /// When set, `fetchUsage()` never returns — simulating the real hang a
    /// live smoke test found in a silent Keychain read (`SecItemCopyMatching`
    /// with `allowInteraction: false` blocking far longer than any network
    /// timeout on some machines). Verifies `UsageCoordinator`'s `fetchTimeout`
    /// mitigation actually bounds the wait.
    var hangsForever = false

    init(serviceID: ServiceID, queued: [Result<ServiceUsage, UsageError>] = [], hangsForever: Bool = false) {
        self.serviceID = serviceID
        self.queued = queued
        self.hangsForever = hangsForever
    }

    func hasLocalCredentials() async -> Bool { true }

    func fetchUsage() async throws -> ServiceUsage {
        if hangsForever {
            // Never resumes — exercises the coordinator's own timeout, not a
            // real (finite) async delay.
            return try await withCheckedThrowingContinuation { _ in }
        }
        lock.lock()
        _fetchCount += 1
        let next = queued.isEmpty ? nil : queued.removeFirst()
        lock.unlock()
        guard let next else { throw UsageError.connectionFailed }
        return try next.get()
    }
}

/// A `Date`-returning closure the test controls explicitly, standing in for
/// `UsageCoordinator`'s injected `now`. Every timing-sensitive assertion in
/// this suite advances this instead of sleeping.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

@MainActor
final class UsageCoordinatorTests: XCTestCase {
    private func usage(_ id: ServiceID, refreshedAt: Date, percent: Double = 10) -> ServiceUsage {
        ServiceUsage(
            serviceID: id,
            plan: nil,
            windows: [UsageWindow(kind: .session, label: "Session", usedPercent: percent, resetsAt: nil, periodDuration: 5 * 3600)],
            refreshedAt: refreshedAt,
            warning: nil
        )
    }

    private func makeCoordinator(
        claude: FakeUsageProvider,
        chatgpt: FakeUsageProvider,
        clock: TestClock,
        forceRefreshStaleness: TimeInterval = 60,
        fixedCooldown: TimeInterval = 60,
        fetchTimeout: TimeInterval = 999_999
    ) -> (UsageCoordinator, PanelModel) {
        let model = PanelModel(serviceOrder: [.claude, .chatgpt], statuses: [:])
        let providers: [ServiceID: UsageCoordinator.ProviderPair] = [
            .claude: UsageCoordinator.ProviderPair(claude),
            .chatgpt: UsageCoordinator.ProviderPair(chatgpt),
        ]
        let coordinator = UsageCoordinator(
            model: model,
            providers: providers,
            pollInterval: 999_999,
            forceRefreshStaleness: forceRefreshStaleness,
            fixedCooldown: fixedCooldown,
            observesWake: false,
            fetchTimeout: fetchTimeout,
            now: clock.now
        )
        return (coordinator, model)
    }

    // MARK: - Independent success/failure (ТЗ §11)

    func testIndependentProvidersSuccessAndFailure() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.success(usage(.claude, refreshedAt: clock.now()))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock)

        await coordinator.handleTimerTick()

        XCTAssertEqual(model.status(for: .claude), .ready(usage(.claude, refreshedAt: clock.now())))
        XCTAssertEqual(model.status(for: .chatgpt), .unavailable(.connectionFailed))
        XCTAssertEqual(claude.fetchCount, 1)
        XCTAssertEqual(chatgpt.fetchCount, 1)
    }

    // MARK: - Status transitions (research doc §9 п.1)

    func testSuccessAfterFailureBecomesReady() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.connectionFailed)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 0)

        await coordinator.handleTimerTick()
        XCTAssertEqual(model.status(for: .claude), .unavailable(.connectionFailed))

        let freshUsage = usage(.claude, refreshedAt: clock.now())
        claude.enqueue(.success(freshUsage))
        await coordinator.handleTimerTick()

        XCTAssertEqual(model.status(for: .claude), .ready(freshUsage))
    }

    func testFailureWithExistingDataBecomesStaleWithoutLosingLastGood() async {
        let clock = TestClock()
        let goodUsage = usage(.claude, refreshedAt: clock.now(), percent: 42)
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.success(goodUsage), .failure(.sessionExpired)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed), .failure(.connectionFailed)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 0)

        await coordinator.handleTimerTick()
        XCTAssertEqual(model.status(for: .claude), .ready(goodUsage))

        await coordinator.handleTimerTick()

        XCTAssertEqual(model.status(for: .claude), .stale(goodUsage, .sessionExpired))
        // The last-good snapshot's own numbers must be untouched.
        XCTAssertEqual(model.status(for: .claude).usage?.sessionFraction, goodUsage.sessionFraction)
    }

    func testFailureWithoutAnyDataBecomesUnavailable() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.notLoggedIn)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock)

        XCTAssertEqual(model.status(for: .claude), .loading)
        await coordinator.handleTimerTick()
        XCTAssertEqual(model.status(for: .claude), .unavailable(.notLoggedIn))
    }

    // MARK: - Cooldown (research doc §9 п.4, п.6)

    func testFixedCooldownAfterFailureBlocksImmediateRepoll() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.connectionFailed)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, _) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 60)

        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 1)

        // Still inside the 60s cooldown: no second network call.
        clock.advance(by: 30)
        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 1)

        // Past the cooldown: polling resumes.
        clock.advance(by: 31)
        claude.enqueue(.failure(.connectionFailed))
        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 2)
    }

    func testRateLimitedCooldownHonorsRetryAfterBeyondFixedFloor() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.rateLimited(retryAfter: 120))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, _) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 60)

        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 1)

        // 90s in: past the fixed 60s floor, but not past the 120s Retry-After.
        clock.advance(by: 90)
        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 1, "rateLimited must extend the cooldown beyond the fixed 60s floor")

        clock.advance(by: 31) // now 121s total
        claude.enqueue(.failure(.connectionFailed))
        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 2)
    }

    func testRateLimitedWithShortRetryAfterStillUsesFixedFloor() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.rateLimited(retryAfter: 5))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, _) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 60)

        await coordinator.handleTimerTick()
        clock.advance(by: 10) // past the 5s Retry-After, still inside the 60s floor
        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 1, "max(retryAfter, fixedCooldown) must still apply the 60s floor")
    }

    func testSuccessClearsCooldown() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.connectionFailed)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 60)

        await coordinator.handleTimerTick()
        clock.advance(by: 61)
        let freshUsage = usage(.claude, refreshedAt: clock.now())
        claude.enqueue(.success(freshUsage))
        await coordinator.handleTimerTick()
        XCTAssertEqual(model.status(for: .claude), .ready(freshUsage))

        // A subsequent failure gets its own fresh 60s cooldown, not a
        // leftover one from the earlier failure.
        claude.enqueue(.failure(.connectionFailed))
        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 3)
        clock.advance(by: 30)
        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 3, "the new failure should still be on cooldown")
    }

    // MARK: - Fetch timeout (a hung provider must never leave .loading forever)

    /// Discovered during the wave-2 live smoke test: a silent Keychain read
    /// can block far longer than any network timeout. `fetchWithTimeout`
    /// bounds every attempt so the service still resolves to an error status
    /// instead of staying `.loading` indefinitely, and — critically — a
    /// hung provider must never delay the other service (ТЗ §11).
    func testHungProviderTimesOutWithoutBlockingTheOtherService() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, hangsForever: true)
        let chatgptUsage = usage(.chatgpt, refreshedAt: clock.now())
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(chatgptUsage)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fetchTimeout: 0.05)

        await coordinator.handleTimerTick()

        XCTAssertEqual(model.status(for: .claude), .unavailable(.connectionFailed))
        XCTAssertEqual(model.status(for: .chatgpt), .ready(chatgptUsage))
    }

    // MARK: - Manual refresh bypasses plain cooldown, not rate-limit cooldown

    func testManualRefreshBypassesPlainFailureCooldown() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.notLoggedIn)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, _) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 60)

        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 1)

        // Still well inside the 60s cooldown, but this is the explicit
        // "Refresh Now" action — it should not have to wait.
        claude.enqueue(.success(usage(.claude, refreshedAt: clock.now())))
        await coordinator.refreshNow()
        XCTAssertEqual(claude.fetchCount, 2)
    }

    func testManualRefreshStillRespectsRateLimitCooldown() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.rateLimited(retryAfter: 120))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, _) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 60)

        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 1)

        clock.advance(by: 30)
        await coordinator.refreshNow()
        XCTAssertEqual(claude.fetchCount, 1, "Refresh Now must not ignore an active rate-limit cooldown")
    }

    // MARK: - Force refresh on panel show (ТЗ §4.3: only if data older than 60s)

    func testForceRefreshSkipsFreshData() async {
        let clock = TestClock()
        let fresh = usage(.claude, refreshedAt: clock.now())
        let claude = FakeUsageProvider(serviceID: .claude, queued: [])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock)
        model.setStatus(.ready(fresh), for: .claude)
        model.setStatus(.ready(usage(.chatgpt, refreshedAt: clock.now())), for: .chatgpt)

        clock.advance(by: 59) // still within the 60s freshness window
        await coordinator.forceRefreshIfStale()

        XCTAssertEqual(claude.fetchCount, 0)
        XCTAssertEqual(chatgpt.fetchCount, 0)
    }

    func testForceRefreshRefetchesDataOlderThanSixtySeconds() async {
        let clock = TestClock()
        let stale = usage(.claude, refreshedAt: clock.now())
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.success(usage(.claude, refreshedAt: clock.now()))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock)
        model.setStatus(.ready(stale), for: .claude)
        model.setStatus(.ready(usage(.chatgpt, refreshedAt: clock.now())), for: .chatgpt)

        clock.advance(by: 61)
        await coordinator.forceRefreshIfStale()

        XCTAssertEqual(claude.fetchCount, 1)
        // ChatGPT's data is also now 61s old, so it gets force-refreshed too
        // — even though it has nothing queued, which surfaces as a
        // .connectionFailed → .stale transition, not silence.
        XCTAssertEqual(chatgpt.fetchCount, 1)
    }

    func testForceRefreshAlwaysFetchesWhenNoDataYet() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.success(usage(.claude, refreshedAt: clock.now()))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock)

        XCTAssertEqual(model.status(for: .claude), .loading)
        await coordinator.forceRefreshIfStale()

        XCTAssertEqual(claude.fetchCount, 1)
        XCTAssertEqual(chatgpt.fetchCount, 1)
    }

    /// A service can be simultaneously "stale enough to force-refresh" (data
    /// older than 60s) and "on cooldown" (its last *attempt* failed under
    /// 60s ago) — the force-refresh path must respect the cooldown and skip
    /// the network call in that case (ТЗ §4.3: "форс-рефреш уважает cooldown").
    func testForceRefreshRespectsCooldown() async {
        let clock = TestClock()
        let goodUsage = usage(.claude, refreshedAt: clock.now())
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.success(goodUsage)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 60)

        await coordinator.handleTimerTick()
        XCTAssertEqual(model.status(for: .claude), .ready(goodUsage))

        // 70s later the data is stale (>60s) — a force-refresh attempt fires
        // and fails, putting Claude on a fresh 60s cooldown from t=70.
        clock.advance(by: 70)
        claude.enqueue(.failure(.connectionFailed))
        await coordinator.forceRefreshIfStale()
        XCTAssertEqual(claude.fetchCount, 2)
        XCTAssertEqual(model.status(for: .claude), .stale(goodUsage, .connectionFailed))

        // Immediately after: data is still stale (last good snapshot is from
        // t=0), but the cooldown from the failure at t=70 is still active —
        // force-refresh must skip the network call.
        await coordinator.forceRefreshIfStale()
        XCTAssertEqual(claude.fetchCount, 2, "an active cooldown must block a force-refresh attempt")

        // Past the cooldown (t=70+61): force-refresh tries again.
        clock.advance(by: 61)
        claude.enqueue(.success(usage(.claude, refreshedAt: clock.now())))
        await coordinator.forceRefreshIfStale()
        XCTAssertEqual(claude.fetchCount, 3)
    }

    // MARK: - Pause / Resume (ТЗ §7)

    func testPauseStopsTimerAndWakePolling() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.success(usage(.claude, refreshedAt: clock.now()))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
        let (coordinator, _) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock)

        coordinator.pause()
        XCTAssertTrue(coordinator.isPaused)

        await coordinator.handleTimerTick()
        await coordinator.handleWake()
        await coordinator.forceRefreshIfStale()

        XCTAssertEqual(claude.fetchCount, 0)
        XCTAssertEqual(chatgpt.fetchCount, 0)
    }

    func testResumeAllowsPollingAgain() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.success(usage(.claude, refreshedAt: clock.now()))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
        let (coordinator, _) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock)

        coordinator.pause()
        coordinator.resume()
        XCTAssertFalse(coordinator.isPaused)

        await coordinator.handleTimerTick()
        XCTAssertEqual(claude.fetchCount, 1)
    }

    func testManualRefreshWorksWhilePaused() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.success(usage(.claude, refreshedAt: clock.now()))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock)

        coordinator.pause()
        await coordinator.refreshNow()

        XCTAssertEqual(claude.fetchCount, 1)
        XCTAssertEqual(model.status(for: .claude).usage, usage(.claude, refreshedAt: clock.now()))
    }
}
