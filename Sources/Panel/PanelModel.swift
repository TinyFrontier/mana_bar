import Foundation

/// Observable store the panel UI reads from: an ordered list of enabled
/// services plus the current `ServiceStatus` for each (ТЗ §3.3). Populated
/// from mock data during this setup-phase wave; the next wave swaps
/// `PanelModel.mock` for a coordinator that polls the real `UsageProvider`s
/// and calls `setStatus` on each fetch (ТЗ §4.3) — this type has no
/// knowledge of `UsageProvider` itself, only of the frozen `ServiceStatus`
/// contract, so that wiring is additive.
@MainActor
final class PanelModel: ObservableObject {
    /// Display order of enabled services in the island (ТЗ §3.3), sourced
    /// from `AppSettings.effectiveServiceOrder` (order ∩ enabled) and kept
    /// live by `AppDelegate` via `updateServiceOrder(_:)`.
    @Published private(set) var serviceOrder: [ServiceID]

    @Published private(set) var statuses: [ServiceID: ServiceStatus]

    /// Services `UsageCoordinator` currently has an in-flight fetch open for
    /// on a trigger the UI should visibly react to: an interactive manual
    /// refresh (Re-login/Retry/Grant-access button, ТЗ §4.3 live-feedback
    /// fix — those buttons used to appear to do nothing), or the very first
    /// re-verification of a disk-cache-seeded snapshot right after launch
    /// (research doc §9 п.7), or **any automatic poll that follows a failure**
    /// — a retry of something the user can already see is broken should look
    /// like it is happening, especially the accelerated launch retries
    /// (`UsageCoordinatorTuning.launchRetryDelays`). Deliberately still NOT set for
    /// silent background polls of a *healthy* service, which stay invisible by
    /// design. `RingView`/`DetailCardView` read this via
    /// `PanelView` to show a loading cue without discarding `statuses`' last
    /// -good data — set/cleared exclusively by `UsageCoordinator`.
    @Published private(set) var refreshingServiceIDs: Set<ServiceID> = []

    /// Services whose most recent `.connectionFailed` was specifically a
    /// **timeout** (the request was still waiting when its budget ran out)
    /// rather than "this machine has no network" (which fails in
    /// milliseconds). `UsageError` is a frozen contract with one case for
    /// both, so the coordinator — the only writer — classifies by measured
    /// fetch duration and records the answer here; `UsageErrorCopy` turns it
    /// into the honest wording ("Сервис не отвечает" vs "Нет соединения").
    /// Cleared on any success or any other kind of failure.
    @Published private(set) var timedOutServiceIDs: Set<ServiceID> = []

    /// Wall-clock deadline of an active `.rateLimited` cooldown, when known —
    /// `UsageCoordinator` is the only writer (`recordFailure`/`recordSuccess`).
    /// `DetailCardView`'s rate-limited copy uses this to show "через ~N мин"/
    /// "в HH:MM" instead of a re-login button that would be misleading for a
    /// rate limit (manual refresh doesn't bypass this cooldown either way).
    @Published private(set) var cooldownUntil: [ServiceID: Date] = [:]

    /// Triggers an interactive manual refresh (ТЗ §4.2) — the same path the
    /// status-bar "Refresh Now" menu item uses. Set by `AppDelegate` to call
    /// `UsageCoordinator.refreshNow()`; `DetailCardView`'s error-state action
    /// button calls it via `requestManualRefresh()` rather than reaching for
    /// the coordinator itself, so this type keeps no knowledge of the
    /// provider/coordinator layer. `nil` in mock/preview contexts, where the
    /// button is a harmless no-op.
    var onManualRefreshRequested: (() -> Void)?

    /// Vertical island drag (ТЗ §6, "как у Grammarly"): fired by `PanelView`
    /// island's `DragGesture(minimumDistance: 0)` on every change/end. Set by
    /// `PanelWindow` in its own init to its own `handleDragChanged`/
    /// `handleDragEnded` — same pass-through pattern as
    /// `onManualRefreshRequested`, `PanelModel` has no drag logic of its own.
    /// `minimumDistance: 0` means these fire even for a plain click with
    /// near-zero movement; the actual "did this cross the drag threshold"
    /// decision lives in `PanelDragGesture`, not here.
    var onDragChanged: (() -> Void)?
    var onDragEnded: (() -> Void)?

    init(serviceOrder: [ServiceID], statuses: [ServiceID: ServiceStatus]) {
        self.serviceOrder = serviceOrder
        self.statuses = statuses
    }

    func status(for id: ServiceID) -> ServiceStatus {
        statuses[id] ?? .loading
    }

    /// Requests an interactive refresh of every service (ТЗ §4.3, §4.2) —
    /// called by the detail card's error-state action button (grant access /
    /// re-login) for both `.claude` and `.chatgpt`, since there is exactly
    /// one interactive-refresh path.
    func requestManualRefresh() {
        onManualRefreshRequested?()
    }

    func setStatus(_ status: ServiceStatus, for id: ServiceID) {
        statuses[id] = status
    }

    /// Marks/unmarks `id` as having a visible in-flight fetch (see
    /// `refreshingServiceIDs` doc). Idempotent either way.
    func setRefreshing(_ isRefreshing: Bool, for id: ServiceID) {
        if isRefreshing {
            refreshingServiceIDs.insert(id)
        } else {
            refreshingServiceIDs.remove(id)
        }
    }

    /// Marks/unmarks `id`'s current `.connectionFailed` as a timeout rather
    /// than an offline machine (see `timedOutServiceIDs` doc). Idempotent.
    func setTimedOut(_ timedOut: Bool, for id: ServiceID) {
        if timedOut {
            timedOutServiceIDs.insert(id)
        } else {
            timedOutServiceIDs.remove(id)
        }
    }

    /// Records (or clears, with `nil`) the active rate-limit cooldown
    /// deadline for `id` (see `cooldownUntil` doc).
    func setCooldownUntil(_ date: Date?, for id: ServiceID) {
        cooldownUntil[id] = date
    }

    /// Applies a new enabled/ordered service list (ТЗ §6 "список сервисов:
    /// вкл/выкл, порядок") — called by `AppDelegate` whenever
    /// `AppSettings.serviceOrder`/`.enabledServiceIDs` change.
    /// `UsageCoordinator` reads `serviceOrder` fresh on every poll, so a
    /// service dropped here simply stops being fetched.
    func updateServiceOrder(_ newOrder: [ServiceID]) {
        guard newOrder != serviceOrder else { return }
        serviceOrder = newOrder
    }
}

// MARK: - Mock data (ТЗ §3.3, §3.4; design-spec.md §7 screenshot reference)

extension PanelModel {
    /// Claude `ready` (session ~73%, week ~7%) + ChatGPT `stale` with
    /// `.connectionFailed` — the two states the compact-panel + detail-card
    /// screenshots in design-spec.md §7 are built from. Used as the app's
    /// data source until the provider-polling coordinator lands.
    static var mock: PanelModel {
        let now = Date()

        let claudeUsage = ServiceUsage(
            serviceID: .claude,
            plan: "Max 20x",
            windows: [
                UsageWindow(
                    kind: .session,
                    label: "Current session",
                    usedPercent: 73,
                    resetsAt: now.addingTimeInterval(51 * 60),
                    periodDuration: 5 * 3600
                ),
                UsageWindow(
                    kind: .weekly,
                    label: "All models",
                    usedPercent: 7,
                    resetsAt: nextOccurrence(of: .thursday, hour: 0, minute: 0, after: now),
                    periodDuration: 7 * 86_400
                ),
            ],
            refreshedAt: now,
            warning: nil
        )

        let chatgptUsage = ServiceUsage(
            serviceID: .chatgpt,
            plan: "Plus",
            windows: [
                UsageWindow(
                    kind: .session,
                    label: "Current session",
                    usedPercent: 21,
                    resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60),
                    periodDuration: 5 * 3600
                ),
                UsageWindow(
                    kind: .weekly,
                    label: "All models",
                    usedPercent: 12,
                    resetsAt: nextOccurrence(of: .monday, hour: 0, minute: 0, after: now),
                    periodDuration: 7 * 86_400
                ),
            ],
            refreshedAt: now.addingTimeInterval(-10 * 60),
            warning: nil
        )

        return PanelModel(
            serviceOrder: [.claude, .chatgpt],
            statuses: [
                .claude: .ready(claudeUsage),
                .chatgpt: .stale(chatgptUsage, .connectionFailed),
            ]
        )
    }

    /// Both services still `.loading` — first-run state before any fetch has
    /// completed (design-spec.md §1.3 / §8.3).
    static var mockLoading: PanelModel {
        PanelModel(
            serviceOrder: [.claude, .chatgpt],
            statuses: [.claude: .loading, .chatgpt: .loading]
        )
    }

    /// Claude at 100% (exhausted) + ChatGPT `.unavailable` (never logged in)
    /// — exercises the two states not covered by `.mock` (design-spec.md
    /// §1.5, §8.2).
    static var mockExhaustedAndUnavailable: PanelModel {
        let now = Date()
        let claudeUsage = ServiceUsage(
            serviceID: .claude,
            plan: "Max 20x",
            windows: [
                UsageWindow(kind: .session, label: "Current session", usedPercent: 100, resetsAt: now.addingTimeInterval(51 * 60), periodDuration: 5 * 3600),
                UsageWindow(kind: .weekly, label: "All models", usedPercent: 88, resetsAt: nextOccurrence(of: .thursday, hour: 0, minute: 0, after: now), periodDuration: 7 * 86_400),
            ],
            refreshedAt: now,
            warning: nil
        )
        return PanelModel(
            serviceOrder: [.claude, .chatgpt],
            statuses: [
                .claude: .ready(claudeUsage),
                .chatgpt: .unavailable(.notLoggedIn),
            ]
        )
    }

    /// Next date/time a given weekday occurs at `hour:minute`, strictly after
    /// `date` (used to synthesize plausible weekly `resetsAt` mock values).
    fileprivate static func nextOccurrence(of weekday: Weekday, hour: Int, minute: Int, after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let currentWeekday = components.weekday ?? 1
        // Calendar weekday: 1 = Sunday ... 7 = Saturday.
        var daysToAdd = (weekday.rawValue - currentWeekday + 7) % 7
        components.hour = hour
        components.minute = minute
        components.second = 0
        var candidate = calendar.date(byAdding: .day, value: daysToAdd, to: calendar.startOfDay(for: date)) ?? date
        candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: candidate) ?? candidate
        if candidate <= date {
            daysToAdd += 7
            candidate = calendar.date(byAdding: .day, value: 7, to: candidate) ?? candidate
        }
        return candidate
    }

    fileprivate enum Weekday: Int {
        case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
    }
}
