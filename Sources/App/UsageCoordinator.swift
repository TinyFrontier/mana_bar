import AppKit
import Foundation

/// Drives every `UsageProvider` poll and writes the results into `PanelModel`
/// (ТЗ §4.3, research doc §9 п.1, п.4, п.6, п.7). `PanelModel` itself has no
/// knowledge of `UsageProvider` — this is the one type that bridges them.
///
/// - First fetch happens immediately on `start()` (research doc §9 п.7: a
///   snapshot is never trusted past app-launch, it's re-verified once right
///   away).
/// - Then a periodic timer polls every service again, on the interval from
///   `AppSettings.refreshInterval` (default 2 min). TODO: live-subscribe to
///   `AppSettings.$refreshInterval` instead of capturing it once at init.
/// - `forceRefreshIfStale()` is called by `AppDelegate` right before the
///   panel is shown, and re-fetches any service whose last snapshot is
///   missing or older than 60s (ТЗ §4.3).
/// - `refreshNow()` is the interactive "Refresh Now" menu action — the only
///   path that may raise a Keychain "allow access" dialog (ТЗ §4.2); every
///   other trigger here stays strictly silent.
/// - Every provider is fetched independently: one failing can never delay or
///   affect another (ТЗ §11), enforced by running them as sibling tasks in a
///   `TaskGroup` rather than a sequential loop.
/// - A failed fetch never wipes the last good `ServiceUsage` — it only
///   downgrades `.ready` to `.stale(lastGood, error)`, or produces
///   `.unavailable(error)` when there was no data yet (research doc §9 п.1).
/// - After any failure, that service gets a fixed 60s cooldown before it is
///   polled again — even by the timer. `UsageError.rateLimited(retryAfter:)`
///   extends that to `max(retryAfter, 60s)` (research doc §9 п.4, п.6).
///   **Exception**: a transient failure before this service has ever
///   succeeded in this run gets the launch-phase backoff instead — see
///   `launchRetryDelays`.
/// - Every attempt is bounded by `fetchTimeout` (default 60s): a live smoke
///   test found that a **silent** Keychain read (`allowInteraction: false`)
///   can block far longer than any network timeout on some machines/macOS
///   configurations, instead of failing fast with `.accessDenied` as its own
///   doc comment promises. `UsageProvider`/`ClaudeAuthStore` are frozen/
///   off-limits for this wave, so the mitigation lives here: a timed-out
///   attempt resolves to `.connectionFailed` immediately so the UI is never
///   stuck on `.loading` forever, while the real call is left running
///   unstructured in the background (Swift cannot force-cancel a blocked
///   system call) and its eventual result is discarded.
///
///   This is a *backstop for an unbounded, non-HTTP hang*, not a request
///   budget — the provider layer's own `ProviderTimeouts` are that. It must
///   therefore stay above the longest legitimate provider chain, or it starts
///   cutting off work that is still progressing: usage GET (20s) → 401 →
///   token refresh (15s) → retried GET (20s) = 55s. Hence 60s. (The previous
///   15s value was already below that chain; nothing observed hit it, but it
///   could have turned a real `.sessionExpired` into a bogus
///   `.connectionFailed`.)

/// Timing constants `UsageCoordinator` is tuned by. They live outside the
/// `@MainActor` class so they can be read from nonisolated contexts — notably
/// `init`'s own default arguments, which are evaluated outside the actor.
enum UsageCoordinatorTuning {
    /// Accelerated retry schedule for a service that has **not yet succeeded
    /// once in this run** and just failed transiently.
    ///
    /// Why this exists: the first fetch after launch is the only one that pays
    /// for a cold DNS + TCP + TLS setup, so it is by far the likeliest to fail
    /// on a briefly degraded link — exactly what the reporter hit. With the
    /// flat 60s post-failure cooldown and a 2-minute poll timer, the panel
    /// then sat on gray "no connection" rings for a full two minutes before
    /// anything tried again, even though the network was healthy seconds
    /// later. Retrying at 15s → 30s → 60s recovers within seconds in the
    /// common case and still backs off if the failure is real. After the
    /// third attempt (or after the first success) this service falls back to
    /// the plain `fixedCooldown` + poll-timer rhythm.
    ///
    /// Deliberate divergence from openusage's flat 60s cooldown: openusage has
    /// no equivalent of Mana's "launch → panel is immediately visible on the
    /// screen edge" moment, where a two-minute-old error is the first and only
    /// thing the user sees.
    static let launchRetryDelays: [TimeInterval] = [15, 30, 60]

    /// A `.connectionFailed` that took at least this long is reported as a
    /// timeout ("Сервис не отвечает") rather than "no connection" — an
    /// actually-offline machine fails in milliseconds, while a request that
    /// burned its whole budget means the link or the service is slow, not
    /// absent. `UsageError` is frozen and has one case for both, so the
    /// distinction travels to the UI through `PanelModel.timedOutServiceIDs`.
    static let timeoutClassificationThreshold: TimeInterval = 5
}

@MainActor
final class UsageCoordinator {
    /// Silent vs. interactive `UsageProvider` for one service. Most services
    /// have no such distinction (both sides are the same value); Claude does,
    /// because `ClaudeAuthStore.allowsKeychainInteraction` controls whether a
    /// Keychain read may raise the system "allow access" dialog.
    struct ProviderPair {
        let silent: any UsageProvider
        let interactive: any UsageProvider

        init(silent: any UsageProvider, interactive: any UsageProvider) {
            self.silent = silent
            self.interactive = interactive
        }

        /// A provider with no silent/interactive distinction.
        init(_ provider: any UsageProvider) {
            self.silent = provider
            self.interactive = provider
        }
    }

    private enum PollReason: Equatable {
        case launch
        /// One of the accelerated retries that follow a failed launch-phase
        /// fetch (see `launchRetryDelays`).
        case launchRetry
        case timer
        case wake
        case forcePanelShow
        case manual
    }

    private struct PollState {
        var cooldownUntil: Date? = nil
        var cooldownIsRateLimit: Bool = false
    }

    private let model: PanelModel
    private let providers: [ServiceID: ProviderPair]
    private let forceRefreshStaleness: TimeInterval
    private let fixedCooldown: TimeInterval
    private let observesWake: Bool
    private let fetchTimeout: TimeInterval
    /// This coordinator's launch-phase backoff (see
    /// `UsageCoordinatorTuning.launchRetryDelays`). Injectable, and empty in
    /// the tests that are about the steady-state cooldown rather than the
    /// launch phase.
    private let launchRetryDelays: [TimeInterval]
    private let now: @Sendable () -> Date
    /// Runs `work` after `delay` seconds. Injectable so tests can drive the
    /// launch-retry backoff (`launchRetryDelays`) instantly and assert the
    /// exact delays instead of waiting real minutes.
    private let scheduleAfter: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let onUsageUpdated: (@MainActor (ServiceUsage) -> Void)?
    /// Disk-backed last-good-snapshot store (research doc §9 п.7). `nil` in
    /// most tests, which have no interest in touching disk; `AppDelegate`
    /// wires a real one in production.
    private let snapshotCache: UsageSnapshotCache?

    /// Mutable so `updateRefreshInterval(_:)` (ТЗ §6: refresh interval
    /// setting) can change it and reschedule the pending timer.
    private var pollInterval: TimeInterval

    /// Which services are actually polled — always `model.serviceOrder`,
    /// read fresh on every poll rather than captured once at `init`, so a
    /// service `AppSettings` disables (ТЗ §6 "вкл/выкл") simply stops being
    /// fetched the moment `PanelModel.updateServiceOrder(_:)` drops it,
    /// without the coordinator needing to be rebuilt.
    private var order: [ServiceID] { model.serviceOrder }

    private var pollState: [ServiceID: PollState] = [:]
    private var inFlight: Set<ServiceID> = []
    private var timerWorkItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    /// Services that have completed at least one successful fetch in this
    /// process run — i.e. are past the launch phase (`launchRetryDelays`).
    private var hasSucceededThisRun: Set<ServiceID> = []
    /// How many accelerated launch retries this service has already been
    /// given; indexes `launchRetryDelays`.
    private var launchRetryAttempt: [ServiceID: Int] = [:]
    /// Services with an accelerated retry already pending, so a second
    /// failure (e.g. a panel-show force-refresh landing on top of the timer)
    /// can't stack two of them.
    private var launchRetryPending: Set<ServiceID> = []

    /// Whether background polling (timer, wake, force-refresh-on-show) is
    /// currently suspended (menu-bar "Pause", ТЗ §7). The explicit "Refresh
    /// Now" action still works while paused.
    private(set) var isPaused = false

    init(
        model: PanelModel,
        providers: [ServiceID: ProviderPair],
        pollInterval: TimeInterval? = nil,
        forceRefreshStaleness: TimeInterval = 60,
        fixedCooldown: TimeInterval = 60,
        observesWake: Bool = true,
        fetchTimeout: TimeInterval = 60,
        launchRetryDelays: [TimeInterval] = UsageCoordinatorTuning.launchRetryDelays,
        onUsageUpdated: (@MainActor (ServiceUsage) -> Void)? = nil,
        snapshotCache: UsageSnapshotCache? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        scheduleAfter: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        }
    ) {
        self.model = model
        self.providers = providers
        self.pollInterval = pollInterval ?? TimeInterval(AppSettings.shared.refreshInterval.rawValue)
        self.forceRefreshStaleness = forceRefreshStaleness
        self.fixedCooldown = fixedCooldown
        self.observesWake = observesWake
        self.fetchTimeout = fetchTimeout
        self.launchRetryDelays = launchRetryDelays
        self.onUsageUpdated = onUsageUpdated
        self.snapshotCache = snapshotCache
        self.now = now
        self.scheduleAfter = scheduleAfter
        for id in model.serviceOrder { pollState[id] = PollState() }
    }

    deinit {
        timerWorkItem?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - Lifecycle

    /// Performs the first fetch immediately, then starts the periodic timer
    /// and the sleep/wake observer. Call once, from `AppDelegate`.
    func start() {
        Task { [weak self] in
            await self?.performLaunchPoll()
        }
        scheduleTimer()
        guard observesWake else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleWake()
            }
        }
    }

    /// Seeds `model` from the on-disk cache (research doc §9 п.7), then
    /// performs the immediate launch-time fetch that re-verifies it — a
    /// snapshot from a previous run/app-version is never trusted past
    /// app-launch, only ever shown as an immediately-superseded starting
    /// point. Internal, not private, so tests can drive it deterministically
    /// instead of racing `start()`'s unstructured `Task`.
    func performLaunchPoll() async {
        seedFromDiskCache()
        await pollAll(reason: .launch)
    }

    /// For every service that has no data yet in `model` (first run in this
    /// process) but does have a cached snapshot on disk, shows that snapshot
    /// immediately, marked `refreshingServiceIDs` so the UI can indicate
    /// "this is being re-verified" without discarding it — cleared the
    /// moment the very next poll (success or failure) resolves. Never
    /// overwrites data `model` already has (e.g. a second, redundant call).
    func seedFromDiskCache() {
        guard let snapshotCache else { return }
        let cached = snapshotCache.load()
        for id in order {
            guard let usage = cached[id] else { continue }
            guard model.status(for: id).usage == nil else { continue }
            model.setStatus(.ready(usage), for: id)
            model.setRefreshing(true, for: id)
        }
    }

    /// Stops the timer and wake observer. Call from
    /// `applicationWillTerminate`.
    func stop() {
        timerWorkItem?.cancel()
        timerWorkItem = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - Pause / Resume (menu-bar "Pause", ТЗ §7)

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        timerWorkItem?.cancel()
        timerWorkItem = nil
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        scheduleTimer()
    }

    /// Applies a new poll interval (ТЗ §6 refresh-interval setting) and, if
    /// a timer is currently pending, reschedules it to fire `newInterval`
    /// from now — an in-flight fetch or the next tick's own reschedule is
    /// left alone, only the *pending* wait is shortened/lengthened.
    func updateRefreshInterval(_ newInterval: TimeInterval) {
        guard newInterval != pollInterval else { return }
        pollInterval = newInterval
        guard !isPaused, timerWorkItem != nil else { return }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timerWorkItem?.cancel()
        guard !isPaused else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.handleTimerTick()
            }
        }
        timerWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: work)
    }

    /// Internal, not private, so tests can drive one "tick" deterministically
    /// without waiting on a real `DispatchQueue.main.asyncAfter` delay.
    func handleTimerTick() async {
        guard !isPaused else { return }
        await pollAll(reason: .timer)
        // Reschedule for the *next* tick only after this one's fetches
        // finish, so a slow fetch can't pile up overlapping timers.
        scheduleTimer()
    }

    /// Internal for the same reason as `handleTimerTick()`.
    func handleWake() async {
        guard !isPaused else { return }
        await pollAll(reason: .wake)
    }

    // MARK: - Force refresh on panel show (ТЗ §4.3)

    /// Refreshes any service whose last snapshot is missing or older than
    /// `forceRefreshStaleness` (default 60s). Called by `AppDelegate` right
    /// before the panel is shown; a no-op while paused, since a paused
    /// coordinator also stops the hot-zone auto-show that would call this.
    func forceRefreshIfStale() async {
        guard !isPaused else { return }
        let staleIDs = order.filter(isStale)
        guard !staleIDs.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in staleIDs {
                group.addTask { [weak self] in
                    await self?.pollOneService(id, reason: .forcePanelShow)
                }
            }
        }
    }

    private func isStale(_ id: ServiceID) -> Bool {
        guard let usage = model.status(for: id).usage else { return true }
        return now().timeIntervalSince(usage.refreshedAt) > forceRefreshStaleness
    }

    // MARK: - Manual refresh (menu "Refresh Now")

    /// Interactive refresh of every service — the only trigger that uses the
    /// interactive provider (may raise a Keychain "allow access" dialog once)
    /// and the only one that runs even while paused.
    func refreshNow() async {
        await pollAll(reason: .manual)
    }

    // MARK: - Core polling

    private func pollAll(reason: PollReason) async {
        await withTaskGroup(of: Void.self) { group in
            for id in order {
                group.addTask { [weak self] in
                    await self?.pollOneService(id, reason: reason)
                }
            }
        }
    }

    private func pollOneService(_ id: ServiceID, reason: PollReason) async {
        guard let pair = providers[id] else { return }
        guard !inFlight.contains(id) else { return }
        guard eligible(id, reason: reason) else { return }

        inFlight.insert(id)
        defer { inFlight.remove(id) }
        // Clears whatever `refreshingServiceIDs` marking either this call (see
        // below) or `seedFromDiskCache()` (`.launch`) applied — unconditional
        // and idempotent, since clearing a flag that was never set is a
        // harmless no-op for every other reason.
        defer { model.setRefreshing(false, for: id) }

        // Read before anything below mutates the status.
        let isRetryAfterError = model.status(for: id).error != nil

        // Live-feedback fix: clicking the detail card's Re-login/Retry/Grant-
        // access button used to visibly do nothing until the fetch resolved.
        // A service with no data yet also flips to `.loading` so the ring/
        // card show the spinner instead of sitting on the old error text for
        // the whole round trip; a service that already has last-good data
        // (`.stale`) keeps showing it — only `refreshingServiceIDs` changes —
        // so a manual refresh can never make numbers disappear.
        if reason == .manual {
            model.setRefreshing(true, for: id)
            if model.status(for: id).usage == nil {
                model.setStatus(.loading, for: id)
            }
        } else if isRetryAfterError {
            // Any automatic poll that follows a failure is, from the user's
            // point of view, a retry of something they can see is broken — so
            // it gets the same spinner a manual refresh does. (Silent polls of
            // a *healthy* service stay invisible, as designed.) Without this,
            // the accelerated launch retries below would have been completely
            // undetectable: the panel just sat there looking stuck.
            model.setRefreshing(true, for: id)
        }

        let provider = reason == .manual ? pair.interactive : pair.silent
        let startedAt = now()
        do {
            let usage = try await fetchWithTimeout(provider)
            recordSuccess(id: id, usage: usage)
        } catch let error as UsageError {
            recordFailure(id: id, error: error, elapsed: now().timeIntervalSince(startedAt))
        } catch {
            recordFailure(id: id, error: .connectionFailed, elapsed: now().timeIntervalSince(startedAt))
        }
    }

    /// Races the real fetch against `fetchTimeout`, using two unstructured
    /// `Task`s rather than a `TaskGroup` on purpose: leaving a `TaskGroup`
    /// scope cancels *and awaits* every remaining child, which would make
    /// this function itself block on the very hang it exists to bound. An
    /// unstructured loser is simply abandoned — its result, whenever (if
    /// ever) it arrives, is dropped by `ResumeOnce`.
    private func fetchWithTimeout(_ provider: any UsageProvider) async throws -> ServiceUsage {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task {
                do {
                    once.resume(.success(try await provider.fetchUsage()))
                } catch {
                    once.resume(.failure(error))
                }
            }
            Task { [fetchTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(max(fetchTimeout, 0) * 1_000_000_000))
                once.resume(.failure(UsageError.connectionFailed))
            }
        }
    }

    /// Manual "Refresh Now" bypasses the plain post-failure cooldown — an
    /// explicit user action (e.g. right after logging back into the CLI)
    /// shouldn't have to wait out a timer-hygiene cooldown — but never
    /// bypasses an active rate-limit cooldown: ignoring `Retry-After` risks a
    /// harsher ban from the service (research doc §9 п.4). Every other
    /// trigger (timer/wake/launch/force-refresh-on-show) respects the
    /// cooldown unconditionally.
    private func eligible(_ id: ServiceID, reason: PollReason) -> Bool {
        guard let state = pollState[id], let cooldownUntil = state.cooldownUntil, now() < cooldownUntil else {
            return true
        }
        // `.launchRetry` fires exactly when the cooldown it set expires, so it
        // must not be blocked by scheduling jitter on its own deadline — but,
        // like a manual refresh, it never overrides a rate-limit cooldown.
        return (reason == .manual || reason == .launchRetry) && !state.cooldownIsRateLimit
    }

    private func recordSuccess(id: ServiceID, usage: ServiceUsage) {
        pollState[id] = PollState()
        hasSucceededThisRun.insert(id)
        launchRetryAttempt[id] = 0
        model.setStatus(.ready(usage), for: id)
        model.setTimedOut(false, for: id)
        // A fresh success always clears any rate-limit countdown the UI was
        // showing (ТЗ §4.3 live-feedback fix).
        model.setCooldownUntil(nil, for: id)
        // research doc §9 п.7: every successful fetch becomes the new
        // "last-good" on disk, so the *next* app launch has something to seed
        // from. Never contains tokens/credentials — `ServiceUsage` doesn't
        // carry any.
        snapshotCache?.save(usage)
        // Clean integration point for ТЗ §5 notifications: every successful
        // fetch's fresh snapshot is handed to whoever wants to react to it
        // (`NotificationManager.evaluate`, wired by `AppDelegate`) — the
        // coordinator itself has no notification-specific knowledge.
        onUsageUpdated?(usage)
    }

    private func recordFailure(id: ServiceID, error: UsageError, elapsed: TimeInterval) {
        // A `.connectionFailed` that burned (most of) its budget is a timeout,
        // not an offline machine — see `timeoutClassificationThreshold`.
        var isTimeout = false
        if case .connectionFailed = error, elapsed >= UsageCoordinatorTuning.timeoutClassificationThreshold {
            isTimeout = true
        }
        model.setTimedOut(isTimeout, for: id)

        let isRateLimit: Bool
        var cooldownSeconds: TimeInterval
        if case .rateLimited(let retryAfter) = error {
            isRateLimit = true
            cooldownSeconds = max(retryAfter ?? 0, fixedCooldown)
        } else {
            isRateLimit = false
            cooldownSeconds = fixedCooldown
        }

        // Launch-phase acceleration (see `launchRetryDelays`): shorten the
        // cooldown to the backoff step and actually schedule the retry, rather
        // than leaving recovery to the 2-minute poll timer.
        if let delay = nextLaunchRetryDelay(id: id, error: error) {
            cooldownSeconds = delay
            scheduleLaunchRetry(for: id, in: delay)
        }

        let cooldownDeadline = now().addingTimeInterval(cooldownSeconds)
        pollState[id] = PollState(cooldownUntil: cooldownDeadline, cooldownIsRateLimit: isRateLimit)
        // Only a rate-limit deadline is meaningful to show the user (ТЗ §4.3
        // live-feedback fix: the plain post-failure cooldown is timer hygiene
        // the user never needs to see, and manual refresh bypasses it anyway
        // — see `eligible(_:reason:)`).
        model.setCooldownUntil(isRateLimit ? cooldownDeadline : nil, for: id)

        // Last good snapshot is never wiped (research doc §9 п.1): downgrade
        // .ready/.stale to .stale with the same usage; only go to
        // .unavailable when there was never any data (.loading/.unavailable).
        if let usage = model.status(for: id).usage {
            model.setStatus(.stale(usage, error), for: id)
        } else {
            model.setStatus(.unavailable(error), for: id)
        }
    }

    // MARK: - Launch-phase accelerated retry

    /// The delay for this service's next accelerated retry, or `nil` when the
    /// plain `fixedCooldown` + poll-timer rhythm should take over.
    ///
    /// Restricted to failures that a retry seconds later can plausibly fix —
    /// a cold-start connection failure or a transient server-side error. A
    /// missing login, a dead session, a missing scope or a Keychain grant will
    /// not resolve themselves in 15 seconds, and a rate limit must be waited
    /// out at the interval the service asked for.
    private func nextLaunchRetryDelay(id: ServiceID, error: UsageError) -> TimeInterval? {
        guard !hasSucceededThisRun.contains(id) else { return nil }
        guard !launchRetryPending.contains(id) else { return nil }
        switch error {
        case .connectionFailed, .requestFailed:
            break
        case .notLoggedIn, .keychainAccessDenied, .sessionExpired, .missingScope,
             .rateLimited, .decodingFailed:
            return nil
        }
        let attempt = launchRetryAttempt[id] ?? 0
        guard attempt < launchRetryDelays.count else { return nil }
        launchRetryAttempt[id] = attempt + 1
        return launchRetryDelays[attempt]
    }

    private func scheduleLaunchRetry(for id: ServiceID, in delay: TimeInterval) {
        launchRetryPending.insert(id)
        scheduleAfter(delay) { [weak self] in
            Task { @MainActor in
                await self?.handleLaunchRetry(id)
            }
        }
    }

    /// Internal, not private, for the same reason as `handleTimerTick()`:
    /// tests drive one accelerated retry deterministically. A retry that comes
    /// due while paused is simply dropped — `resume()` restarts the ordinary
    /// timer, which is the right cadence for a session the user paused.
    func handleLaunchRetry(_ id: ServiceID) async {
        launchRetryPending.remove(id)
        guard !isPaused else { return }
        guard !hasSucceededThisRun.contains(id) else { return }
        await pollOneService(id, reason: .launchRetry)
    }
}

/// Resumes a `CheckedContinuation` exactly once, discarding every result
/// after the first — the primitive `fetchWithTimeout` races the real fetch
/// against a timer with, where either side may "win" and the other must be a
/// silent no-op rather than a second (crashing) resume.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
