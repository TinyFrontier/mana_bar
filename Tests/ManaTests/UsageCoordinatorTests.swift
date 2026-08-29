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

/// A provider whose `fetchUsage()` suspends until the test explicitly
/// releases it via `resume(with:)` — unlike `FakeUsageProvider` (which
/// resolves synchronously off a queue), this lets a test observe the
/// coordinator's state *while* a fetch is genuinely in flight, e.g. the
/// manual-refresh loading cue (ТЗ §4.3 live-feedback fix).
final class GatedUsageProvider: UsageProvider, @unchecked Sendable {
    let serviceID: ServiceID

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<ServiceUsage, UsageError>, Never>?
    private var pendingResult: Result<ServiceUsage, UsageError>?

    init(serviceID: ServiceID) {
        self.serviceID = serviceID
    }

    func hasLocalCredentials() async -> Bool { true }

    func fetchUsage() async throws -> ServiceUsage {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<ServiceUsage, UsageError>, Never>) in
            lock.lock()
            if let pendingResult {
                lock.unlock()
                continuation.resume(returning: pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
        return try result.get()
    }

    /// Whether a `fetchUsage()` is currently suspended waiting for
    /// `resume(with:)` — lets a test synchronize on "the coordinator has
    /// genuinely started this fetch" without depending on any UI flag.
    var hasPendingFetch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    /// Releases the pending (or, if called first, the next) `fetchUsage()`.
    func resume(with result: Result<ServiceUsage, UsageError>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}

/// Captures what `UsageCoordinator` asks to be scheduled later (the
/// launch-phase accelerated retries) instead of actually waiting: the test
/// asserts the recorded delays and then drives `handleLaunchRetry(_:)`
/// itself, so a 15s → 30s → 60s backoff is verified in microseconds.
final class RecordingScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void {
        { [self] delay, _ in
            lock.lock()
            recorded.append(delay)
            lock.unlock()
        }
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
        fetchTimeout: TimeInterval = 999_999,
        // Off by default: every pre-existing test here is about the
        // steady-state cooldown, not the launch-phase acceleration, which has
        // its own section below and opts in explicitly.
        launchRetryDelays: [TimeInterval] = [],
        scheduler: RecordingScheduler? = nil,
        snapshotCache: UsageSnapshotCache? = nil
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
            launchRetryDelays: launchRetryDelays,
            snapshotCache: snapshotCache,
            now: clock.now,
            scheduleAfter: scheduler?.schedule ?? { _, _ in }
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

    // MARK: - Manual refresh visible loading feedback (ТЗ §4.3 live-feedback fix)

    /// Waits (via cooperative yielding, not a real sleep — deterministic and
    /// fast) until `predicate()` is true or the budget runs out.
    private func waitUntil(_ predicate: () -> Bool, iterations: Int = 10_000) async {
        for _ in 0..<iterations {
            if predicate() { return }
            await Task.yield()
        }
    }

    func testManualRefreshOfServiceWithNoDataShowsLoadingWhileInFlight() async {
        let clock = TestClock()
        let claude = GatedUsageProvider(serviceID: .claude)
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
        let model = PanelModel(serviceOrder: [.claude, .chatgpt], statuses: [:])
        let coordinator = UsageCoordinator(
            model: model,
            providers: [
                .claude: UsageCoordinator.ProviderPair(claude),
                .chatgpt: UsageCoordinator.ProviderPair(chatgpt),
            ],
            pollInterval: 999_999,
            observesWake: false,
            fetchTimeout: 999_999,
            now: clock.now
        )
        model.setStatus(.unavailable(.notLoggedIn), for: .claude)

        let refreshTask = Task { await coordinator.refreshNow() }
        await waitUntil { model.refreshingServiceIDs.contains(.claude) }

        XCTAssertEqual(model.status(for: .claude), .loading, "a service with no data must flip to .loading for the duration of a manual refresh")
        XCTAssertTrue(model.refreshingServiceIDs.contains(.claude))

        let freshUsage = usage(.claude, refreshedAt: clock.now(), percent: 5)
        claude.resume(with: .success(freshUsage))
        await refreshTask.value

        XCTAssertEqual(model.status(for: .claude), .ready(freshUsage))
        XCTAssertFalse(model.refreshingServiceIDs.contains(.claude), "the loading cue must clear once the fetch resolves")
    }

    /// The other half of the same fix: a `.stale` service (last-good data +
    /// an error) must keep showing that data throughout a manual refresh —
    /// only `refreshingServiceIDs` should change, never `statuses`.
    func testManualRefreshOfStaleServiceKeepsDataVisibleWhileInFlight() async {
        let clock = TestClock()
        let goodUsage = usage(.claude, refreshedAt: clock.now(), percent: 55)
        let claude = GatedUsageProvider(serviceID: .claude)
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
        let model = PanelModel(serviceOrder: [.claude, .chatgpt], statuses: [:])
        let coordinator = UsageCoordinator(
            model: model,
            providers: [
                .claude: UsageCoordinator.ProviderPair(claude),
                .chatgpt: UsageCoordinator.ProviderPair(chatgpt),
            ],
            pollInterval: 999_999,
            observesWake: false,
            fetchTimeout: 999_999,
            now: clock.now
        )
        model.setStatus(.stale(goodUsage, .connectionFailed), for: .claude)

        let refreshTask = Task { await coordinator.refreshNow() }
        await waitUntil { model.refreshingServiceIDs.contains(.claude) }

        XCTAssertEqual(model.status(for: .claude), .stale(goodUsage, .connectionFailed), "manual refresh must never blank out last-good data while in flight")

        let freshUsage = usage(.claude, refreshedAt: clock.now(), percent: 12)
        claude.resume(with: .success(freshUsage))
        await refreshTask.value

        XCTAssertEqual(model.status(for: .claude), .ready(freshUsage))
        XCTAssertFalse(model.refreshingServiceIDs.contains(.claude))
    }

    // MARK: - Rate-limit cooldown deadline surfaced to the UI (ТЗ §4.3 live-feedback fix)

    func testRateLimitedFailureRecordsCooldownDeadlineInModel() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.rateLimited(retryAfter: 90))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 60)

        await coordinator.handleTimerTick()

        XCTAssertEqual(model.cooldownUntil[.claude], clock.now().addingTimeInterval(90))
    }

    func testNonRateLimitFailureDoesNotRecordACooldownDeadline() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.connectionFailed)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 60)

        await coordinator.handleTimerTick()

        XCTAssertNil(model.cooldownUntil[.claude], "only .rateLimited should surface a retry deadline — the plain cooldown is timer hygiene, not user-facing")
    }

    func testSuccessClearsAnyPreviousRateLimitCooldownDeadline() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.rateLimited(retryAfter: 120))])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, fixedCooldown: 60)

        await coordinator.handleTimerTick()
        XCTAssertNotNil(model.cooldownUntil[.claude])

        clock.advance(by: 121)
        claude.enqueue(.success(usage(.claude, refreshedAt: clock.now())))
        await coordinator.handleTimerTick()

        XCTAssertNil(model.cooldownUntil[.claude])
    }

    // MARK: - Disk cache seeding on launch (research doc §9 п.7)

    func testSeedFromDiskCacheShowsCachedDataMarkedRefreshingWithoutFetching() {
        let clock = TestClock()
        let tempDir = TemporaryDirectory(self)
        let cache = UsageSnapshotCache(directory: URL(fileURLWithPath: tempDir.path))
        let cachedUsage = usage(.claude, refreshedAt: clock.now().addingTimeInterval(-6 * 3600), percent: 61)
        cache.save(cachedUsage)

        let claude = FakeUsageProvider(serviceID: .claude, queued: [])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, snapshotCache: cache)

        coordinator.seedFromDiskCache()

        XCTAssertEqual(model.status(for: .claude), .ready(cachedUsage))
        XCTAssertTrue(model.refreshingServiceIDs.contains(.claude))
        XCTAssertEqual(claude.fetchCount, 0, "seeding from the disk cache must never touch the network")
        // ChatGPT has no cached entry: untouched, still the plain launch default.
        XCTAssertEqual(model.status(for: .chatgpt), .loading)
    }

    func testSeedFromDiskCacheNeverOverwritesDataAlreadyInModel() {
        let clock = TestClock()
        let tempDir = TemporaryDirectory(self)
        let cache = UsageSnapshotCache(directory: URL(fileURLWithPath: tempDir.path))
        cache.save(usage(.claude, refreshedAt: clock.now().addingTimeInterval(-3600), percent: 20))

        let claude = FakeUsageProvider(serviceID: .claude, queued: [])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, snapshotCache: cache)
        let alreadyThere = usage(.claude, refreshedAt: clock.now(), percent: 99)
        model.setStatus(.ready(alreadyThere), for: .claude)

        coordinator.seedFromDiskCache()

        XCTAssertEqual(model.status(for: .claude), .ready(alreadyThere))
        XCTAssertFalse(model.refreshingServiceIDs.contains(.claude))
    }

    /// The end-to-end shape of ТЗ's live-run check: the coordinator starts
    /// with a disk-cached snapshot and, once the immediate launch fetch
    /// resolves, replaces it with fresh data — which is in turn written back
    /// to the cache for the *next* launch (research doc §9 п.7: "свежесть
    /// только внутри текущей сессии запуска").
    func testPerformLaunchPollReplacesCachedSnapshotWithFreshDataAndUpdatesTheCache() async {
        let clock = TestClock()
        let tempDir = TemporaryDirectory(self)
        let cache = UsageSnapshotCache(directory: URL(fileURLWithPath: tempDir.path))
        let cachedUsage = usage(.claude, refreshedAt: clock.now().addingTimeInterval(-6 * 3600), percent: 61)
        cache.save(cachedUsage)

        let freshUsage = usage(.claude, refreshedAt: clock.now(), percent: 9)
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.success(freshUsage)])
        let chatgptUsage = usage(.chatgpt, refreshedAt: clock.now())
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(chatgptUsage)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, snapshotCache: cache)

        await coordinator.performLaunchPoll()

        XCTAssertEqual(model.status(for: .claude), .ready(freshUsage))
        XCTAssertFalse(model.refreshingServiceIDs.contains(.claude))
        XCTAssertEqual(claude.fetchCount, 1, "a cached snapshot must always be re-verified by one fetch right after launch, never trusted on its own")
        XCTAssertEqual(cache.load()[.claude], freshUsage, "a fresh success must overwrite the disk cache with the new last-good snapshot")
    }

    /// A failed launch re-check must still clear the "being re-verified" cue
    /// even though it downgrades to `.stale` rather than `.ready`.
    func testPerformLaunchPollOnFailureStillClearsRefreshingAndKeepsCachedDataAsStale() async {
        let clock = TestClock()
        let tempDir = TemporaryDirectory(self)
        let cache = UsageSnapshotCache(directory: URL(fileURLWithPath: tempDir.path))
        let cachedUsage = usage(.claude, refreshedAt: clock.now().addingTimeInterval(-6 * 3600), percent: 61)
        cache.save(cachedUsage)

        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.connectionFailed)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock, snapshotCache: cache)

        await coordinator.performLaunchPoll()

        XCTAssertEqual(model.status(for: .claude), .stale(cachedUsage, .connectionFailed))
        XCTAssertFalse(model.refreshingServiceIDs.contains(.claude))
    }

    // MARK: - Launch-phase accelerated retry
    //
    // Live-feedback bug: on the reporter's first launch both providers failed
    // (a cold TLS setup on a briefly degraded link blew the request budget)
    // and the panel then sat on gray "Нет соединения" rings for a full two
    // minutes — 60s post-failure cooldown, then the 2-minute poll timer —
    // even though the network was healthy seconds later.

    func testProductionLaunchRetryBackoffIsFifteenThirtySixty() {
        XCTAssertEqual(UsageCoordinatorTuning.launchRetryDelays, [15, 30, 60])
    }

    func testTransientLaunchFailureSchedulesBackoffAndStopsAfterThreeAttempts() async {
        let clock = TestClock()
        let scheduler = RecordingScheduler()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.connectionFailed)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
        let (coordinator, _) = makeCoordinator(
            claude: claude,
            chatgpt: chatgpt,
            clock: clock,
            launchRetryDelays: UsageCoordinatorTuning.launchRetryDelays,
            scheduler: scheduler
        )

        await coordinator.performLaunchPoll()
        XCTAssertEqual(scheduler.delays, [15], "the first launch failure must schedule a retry, not wait out the poll timer")

        // Each accelerated retry that fails again backs off one step.
        claude.enqueue(.failure(.connectionFailed))
        clock.advance(by: 15)
        await coordinator.handleLaunchRetry(.claude)
        XCTAssertEqual(claude.fetchCount, 2, "the scheduled retry must actually re-fetch")
        XCTAssertEqual(scheduler.delays, [15, 30])

        claude.enqueue(.failure(.connectionFailed))
        clock.advance(by: 30)
        await coordinator.handleLaunchRetry(.claude)
        XCTAssertEqual(claude.fetchCount, 3)
        XCTAssertEqual(scheduler.delays, [15, 30, 60])

        // Backoff exhausted: this service falls back to the ordinary
        // cooldown + poll-timer rhythm rather than retrying forever.
        claude.enqueue(.failure(.connectionFailed))
        clock.advance(by: 60)
        await coordinator.handleLaunchRetry(.claude)
        XCTAssertEqual(claude.fetchCount, 4)
        XCTAssertEqual(scheduler.delays, [15, 30, 60], "the backoff must stop after three accelerated attempts")

        // The successful service never entered the launch phase at all.
        XCTAssertEqual(chatgpt.fetchCount, 1)
    }

    func testLaunchRetryRecoversAndStopsRetryingAfterSuccess() async {
        let clock = TestClock()
        let scheduler = RecordingScheduler()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.connectionFailed)])
        // Succeeds at launch, so it leaves the launch phase immediately and
        // can never contribute entries to the shared delay recorder.
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
        let (coordinator, model) = makeCoordinator(
            claude: claude,
            chatgpt: chatgpt,
            clock: clock,
            launchRetryDelays: UsageCoordinatorTuning.launchRetryDelays,
            scheduler: scheduler
        )

        await coordinator.performLaunchPoll()
        XCTAssertEqual(model.status(for: .claude), .unavailable(.connectionFailed))
        XCTAssertEqual(scheduler.delays, [15])

        clock.advance(by: 15)
        let recovered = usage(.claude, refreshedAt: clock.now(), percent: 31)
        claude.enqueue(.success(recovered))
        await coordinator.handleLaunchRetry(.claude)

        XCTAssertEqual(model.status(for: .claude), .ready(recovered), "the accelerated retry is what makes the panel recover in seconds")
        XCTAssertEqual(scheduler.delays, [15], "a recovered service must not schedule further accelerated retries")

        // Past the launch phase now: a later failure goes back to the plain
        // 60s cooldown, no acceleration.
        claude.enqueue(.failure(.connectionFailed))
        clock.advance(by: 61)
        await coordinator.handleTimerTick()
        XCTAssertEqual(model.status(for: .claude), .stale(recovered, .connectionFailed))
        XCTAssertEqual(scheduler.delays, [15], "acceleration is a launch-phase-only concession")
    }

    /// Errors a retry seconds later cannot possibly fix must not be
    /// accelerated: no login appears in 15s, and a rate limit must be waited
    /// out at the interval the service asked for (research doc §9 п.4).
    func testNonTransientLaunchFailuresAreNotAccelerated() async {
        for error in [UsageError.notLoggedIn, .keychainAccessDenied, .sessionExpired, .missingScope, .rateLimited(retryAfter: 300), .decodingFailed("x")] {
            let clock = TestClock()
            let scheduler = RecordingScheduler()
            let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(error)])
            let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
            let (coordinator, _) = makeCoordinator(
                claude: claude,
                chatgpt: chatgpt,
                clock: clock,
                launchRetryDelays: UsageCoordinatorTuning.launchRetryDelays,
                scheduler: scheduler
            )

            await coordinator.performLaunchPoll()
            XCTAssertEqual(scheduler.delays, [], "\(error) must not trigger an accelerated retry")
        }
    }

    func testLaunchRetryComingDueWhilePausedIsDropped() async {
        let clock = TestClock()
        let scheduler = RecordingScheduler()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.connectionFailed)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.notLoggedIn)])
        let (coordinator, _) = makeCoordinator(
            claude: claude,
            chatgpt: chatgpt,
            clock: clock,
            launchRetryDelays: UsageCoordinatorTuning.launchRetryDelays,
            scheduler: scheduler
        )

        await coordinator.performLaunchPoll()
        XCTAssertEqual(claude.fetchCount, 1)

        coordinator.pause()
        clock.advance(by: 15)
        await coordinator.handleLaunchRetry(.claude)

        XCTAssertEqual(claude.fetchCount, 1, "a paused coordinator must not poll (ТЗ §7)")
    }

    // MARK: - Timeout vs. offline (`PanelModel.timedOutServiceIDs`)

    /// `UsageError` is frozen and has a single `.connectionFailed` for both
    /// "offline" (fails in milliseconds) and "ran out of time" (burns the
    /// whole budget). The coordinator classifies by measured duration so the
    /// card can say "Сервис не отвечает" instead of the disprovable
    /// "Нет соединения".
    func testSlowConnectionFailureIsReportedAsATimeout() async {
        let clock = TestClock()
        let claude = GatedUsageProvider(serviceID: .claude)
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let model = PanelModel(serviceOrder: [.claude, .chatgpt], statuses: [:])
        let coordinator = UsageCoordinator(
            model: model,
            providers: [
                .claude: UsageCoordinator.ProviderPair(claude),
                .chatgpt: UsageCoordinator.ProviderPair(chatgpt),
            ],
            pollInterval: 999_999,
            observesWake: false,
            fetchTimeout: 999_999,
            launchRetryDelays: [],
            now: clock.now,
            scheduleAfter: { _, _ in }
        )

        let tick = Task { await coordinator.handleTimerTick() }
        await waitUntil { model.refreshingServiceIDs.contains(.claude) || claude.hasPendingFetch }
        // The fetch spent its whole budget before failing.
        clock.advance(by: UsageCoordinatorTuning.timeoutClassificationThreshold)
        claude.resume(with: .failure(.connectionFailed))
        await tick.value

        XCTAssertTrue(model.timedOutServiceIDs.contains(.claude), "a connection failure that burned the budget is a timeout")
        XCTAssertEqual(
            UsageErrorCopy.text(for: .connectionFailed, timedOut: model.timedOutServiceIDs.contains(.claude)),
            "Сервис не отвечает"
        )
    }

    /// The other half: an *instant* connection failure is a genuinely offline
    /// machine and must keep saying "Нет соединения".
    func testInstantConnectionFailureIsNotReportedAsATimeout() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.connectionFailed)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.connectionFailed)])
        let (coordinator, model) = makeCoordinator(claude: claude, chatgpt: chatgpt, clock: clock)

        // The clock never moves, so both fetches took zero time.
        await coordinator.handleTimerTick()

        XCTAssertTrue(model.timedOutServiceIDs.isEmpty)
        XCTAssertEqual(
            UsageErrorCopy.text(for: .connectionFailed, timedOut: model.timedOutServiceIDs.contains(.claude)),
            UsageError.connectionFailed.userDescription
        )
    }

    func testCoordinatorFetchTimeoutIsReportedAsATimeout() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, hangsForever: true)
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.success(usage(.chatgpt, refreshedAt: clock.now()))])
        let (coordinator, model) = makeCoordinator(
            claude: claude,
            chatgpt: chatgpt,
            clock: clock,
            fetchTimeout: 0.2
        )

        // The coordinator's own backstop fires after the (test) clock has been
        // pushed past the classification threshold by the hang.
        let tick = Task { await coordinator.handleTimerTick() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        clock.advance(by: 30)
        await tick.value

        XCTAssertEqual(model.status(for: .claude), .unavailable(.connectionFailed))
        XCTAssertTrue(model.timedOutServiceIDs.contains(.claude), "the fetch-timeout backstop is a timeout by construction")
    }

    func testSuccessClearsTheTimedOutFlag() async {
        let clock = TestClock()
        let claude = GatedUsageProvider(serviceID: .claude)
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.notLoggedIn)])
        let model = PanelModel(serviceOrder: [.claude, .chatgpt], statuses: [:])
        model.setTimedOut(true, for: .claude)
        let coordinator = UsageCoordinator(
            model: model,
            providers: [
                .claude: UsageCoordinator.ProviderPair(claude),
                .chatgpt: UsageCoordinator.ProviderPair(chatgpt),
            ],
            pollInterval: 999_999,
            observesWake: false,
            fetchTimeout: 999_999,
            launchRetryDelays: [],
            now: clock.now,
            scheduleAfter: { _, _ in }
        )

        let fresh = usage(.claude, refreshedAt: clock.now(), percent: 3)
        claude.resume(with: .success(fresh))
        await coordinator.handleTimerTick()

        XCTAssertEqual(model.status(for: .claude), .ready(fresh))
        XCTAssertFalse(model.timedOutServiceIDs.contains(.claude))
    }

    // MARK: - Automatic retries after an error are visible

    /// The accelerated launch retries would otherwise be invisible: the panel
    /// would just sit on a gray ring looking stuck. Any automatic poll that
    /// follows a failure now flags `refreshingServiceIDs`, exactly like a
    /// manual refresh does — while still leaving silent polls of a *healthy*
    /// service invisible.
    func testAutomaticRetryAfterErrorShowsTheRefreshingCue() async {
        let clock = TestClock()
        let claude = FakeUsageProvider(serviceID: .claude, queued: [.failure(.connectionFailed)])
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.notLoggedIn)])
        let (coordinator, model) = makeCoordinator(
            claude: claude,
            chatgpt: chatgpt,
            clock: clock,
            fixedCooldown: 0,
            fetchTimeout: 0.2
        )

        await coordinator.handleTimerTick()
        XCTAssertEqual(model.status(for: .claude), .unavailable(.connectionFailed))
        XCTAssertFalse(model.refreshingServiceIDs.contains(.claude), "the cue must clear once a fetch resolves")

        // Next automatic poll of the now-failed service: the cue is visible
        // for the whole round trip (the hang is bounded by `fetchTimeout`).
        claude.hangsForever = true
        let tick = Task { await coordinator.handleTimerTick() }
        await waitUntil { model.refreshingServiceIDs.contains(.claude) }
        XCTAssertTrue(model.refreshingServiceIDs.contains(.claude))

        await tick.value
        XCTAssertFalse(model.refreshingServiceIDs.contains(.claude), "the cue must clear again once the retry resolves")
    }

    func testSilentPollOfAHealthyServiceStaysInvisible() async {
        let clock = TestClock()
        let claude = GatedUsageProvider(serviceID: .claude)
        let chatgpt = FakeUsageProvider(serviceID: .chatgpt, queued: [.failure(.notLoggedIn)])
        let model = PanelModel(serviceOrder: [.claude, .chatgpt], statuses: [:])
        model.setStatus(.ready(usage(.claude, refreshedAt: clock.now(), percent: 20)), for: .claude)
        let coordinator = UsageCoordinator(
            model: model,
            providers: [
                .claude: UsageCoordinator.ProviderPair(claude),
                .chatgpt: UsageCoordinator.ProviderPair(chatgpt),
            ],
            pollInterval: 999_999,
            observesWake: false,
            fetchTimeout: 999_999,
            launchRetryDelays: [],
            now: clock.now,
            scheduleAfter: { _, _ in }
        )

        let tick = Task { await coordinator.handleTimerTick() }
        await waitUntil { claude.hasPendingFetch }
        XCTAssertFalse(
            model.refreshingServiceIDs.contains(.claude),
            "a background poll of a healthy service must stay invisible (ТЗ §4.3)"
        )

        claude.resume(with: .success(usage(.claude, refreshedAt: clock.now(), percent: 21)))
        await tick.value
    }
}
