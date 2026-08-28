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
    /// Display order of services in the island (ТЗ §3.3). TODO: source from
    /// `AppSettings` enabled/ordered service list once that's wired up.
    @Published private(set) var serviceOrder: [ServiceID]

    @Published private(set) var statuses: [ServiceID: ServiceStatus]

    init(serviceOrder: [ServiceID], statuses: [ServiceID: ServiceStatus]) {
        self.serviceOrder = serviceOrder
        self.statuses = statuses
    }

    func status(for id: ServiceID) -> ServiceStatus {
        statuses[id] ?? .loading
    }

    func setStatus(_ status: ServiceStatus, for id: ServiceID) {
        statuses[id] = status
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
