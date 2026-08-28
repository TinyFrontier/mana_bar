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
/// - Every attempt is bounded by `fetchTimeout` (default 15s): a live smoke
///   test found that a **silent** Keychain read (`allowInteraction: false`)
///   can block far longer than any network timeout on some machines/macOS
///   configurations, instead of failing fast with `.accessDenied` as its own
///   doc comment promises. `UsageProvider`/`ClaudeAuthStore` are frozen/
///   off-limits for this wave, so the mitigation lives here: a timed-out
///   attempt resolves to `.connectionFailed` immediately so the UI is never
///   stuck on `.loading` forever, while the real call is left running
///   unstructured in the background (Swift cannot force-cancel a blocked
///   system call) and its eventual result is discarded.
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
    private let now: @Sendable () -> Date
    private let onUsageUpdated: (@MainActor (ServiceUsage) -> Void)?

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
        fetchTimeout: TimeInterval = 15,
        onUsageUpdated: (@MainActor (ServiceUsage) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.model = model
        self.providers = providers
        self.pollInterval = pollInterval ?? TimeInterval(AppSettings.shared.refreshInterval.rawValue)
        self.forceRefreshStaleness = forceRefreshStaleness
        self.fixedCooldown = fixedCooldown
        self.observesWake = observesWake
        self.fetchTimeout = fetchTimeout
        self.onUsageUpdated = onUsageUpdated
        self.now = now
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
            await self?.pollAll(reason: .launch)
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

        let provider = reason == .manual ? pair.interactive : pair.silent
        do {
            let usage = try await fetchWithTimeout(provider)
            recordSuccess(id: id, usage: usage)
        } catch let error as UsageError {
            recordFailure(id: id, error: error)
        } catch {
            recordFailure(id: id, error: .connectionFailed)
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
        return reason == .manual && !state.cooldownIsRateLimit
    }

    private func recordSuccess(id: ServiceID, usage: ServiceUsage) {
        pollState[id] = PollState()
        model.setStatus(.ready(usage), for: id)
        // Clean integration point for ТЗ §5 notifications: every successful
        // fetch's fresh snapshot is handed to whoever wants to react to it
        // (`NotificationManager.evaluate`, wired by `AppDelegate`) — the
        // coordinator itself has no notification-specific knowledge.
        onUsageUpdated?(usage)
    }

    private func recordFailure(id: ServiceID, error: UsageError) {
        let isRateLimit: Bool
        let cooldownSeconds: TimeInterval
        if case .rateLimited(let retryAfter) = error {
            isRateLimit = true
            cooldownSeconds = max(retryAfter ?? 0, fixedCooldown)
        } else {
            isRateLimit = false
            cooldownSeconds = fixedCooldown
        }
        pollState[id] = PollState(cooldownUntil: now().addingTimeInterval(cooldownSeconds), cooldownIsRateLimit: isRateLimit)

        // Last good snapshot is never wiped (research doc §9 п.1): downgrade
        // .ready/.stale to .stale with the same usage; only go to
        // .unavailable when there was never any data (.loading/.unavailable).
        if let usage = model.status(for: id).usage {
            model.setStatus(.stale(usage, error), for: id)
        } else {
            model.setStatus(.unavailable(error), for: id)
        }
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
