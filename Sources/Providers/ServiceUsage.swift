import Foundation

/// Identifies a supported AI service. New providers extend this enum and
/// conform to `UsageProvider` (ТЗ §4.1: "Архитектура должна позволять
/// добавлять новые провайдеры через общий протокол UsageProvider").
enum ServiceID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case chatgpt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        }
    }
}

/// Error/health state of a service's usage data (ТЗ §4.3): a normal reading,
/// or a network/auth failure that should render the ring gray with a
/// warning glyph and surface `message` + a "Re-login" action in the detail card.
enum UsageState: Equatable, Sendable {
    case ok
    case error(String)
}

/// Snapshot of one service's quota usage, as shown in the panel ring and
/// detail card: session (5h window) and weekly (7-day window) percentages,
/// their reset times, and current error state (ТЗ §3.3, §3.4, §4.1).
struct ServiceUsage: Identifiable, Equatable, Sendable {
    var id: ServiceID { serviceID }

    let serviceID: ServiceID

    /// 0...1 fraction of the current session (5h) window used.
    var sessionPercent: Double
    var sessionResetDate: Date?

    /// 0...1 fraction of the weekly (7-day) window used.
    var weeklyPercent: Double
    var weeklyResetDate: Date?

    var state: UsageState
    var lastUpdated: Date

    var isError: Bool {
        if case .error = state { return true }
        return false
    }

    // TODO: replace with real relative/absolute formatting per ТЗ §3.4
    // examples ("Resets in 51 min", "Resets Thu 12:00 AM").
    var sessionResetDescription: String {
        Self.describe(resetDate: sessionResetDate)
    }

    var weeklyResetDescription: String {
        Self.describe(resetDate: weeklyResetDate)
    }

    private static func describe(resetDate: Date?) -> String {
        guard let resetDate else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Resets " + formatter.localizedString(for: resetDate, relativeTo: Date())
    }

    static let placeholder = ServiceUsage(
        serviceID: .claude,
        sessionPercent: 0,
        sessionResetDate: nil,
        weeklyPercent: 0,
        weeklyResetDate: nil,
        state: .ok,
        lastUpdated: .distantPast
    )
}
