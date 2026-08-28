import Foundation

// FROZEN CONTRACT (2026-08-28): this file is the shared boundary between the
// provider layer and the UI layer. Change it only via the orchestrator session,
// never from a single-sided implementation task.

/// Identifies a supported AI service. New providers extend this enum and
/// conform to `UsageProvider` (ТЗ §4.1).
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

/// One rate-limit window as reported by the service (research doc §9.2).
struct UsageWindow: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Rolling session window (Claude: 5h, Codex: primary/short window).
        case session
        /// All-models weekly window (Claude: 7d, Codex: secondary/long window).
        case weekly
        /// Model-scoped weekly limit (Claude `limits[].kind == "weekly_scoped"`),
        /// e.g. "Sonnet". Associated value is the display name of the model.
        case modelWeekly(String)
    }

    let kind: Kind

    /// UI label: "Session", "Weekly", or the model name.
    var label: String

    /// 0...100, exactly as the API reports it — never inverted, never clamped
    /// into 0...1 here (research doc §9.3: Codex `used_percent` pitfalls).
    var usedPercent: Double

    /// When the window resets. `nil` means the window has NOT started yet
    /// ("Not started") — distinct from 0% usage (research doc §9.2 п.5).
    var resetsAt: Date?

    /// Window length (5h / 7d), when the API reports it — lets the UI derive
    /// "Resets in Nm" even without `resetsAt`.
    var periodDuration: TimeInterval?
}

/// Snapshot of one service's quota usage (ТЗ §3.3, §3.4, §4.1).
struct ServiceUsage: Identifiable, Equatable, Sendable {
    var id: ServiceID { serviceID }

    let serviceID: ServiceID

    /// Plan label when the API reports it (e.g. "Pro", "Max 20x").
    var plan: String?

    /// All windows the service reported. Missing resource stays absent —
    /// never fabricate a window with 0% (research doc §9.2 п.10).
    var windows: [UsageWindow]

    /// When this snapshot was fetched.
    var refreshedAt: Date

    /// Soft warning on a partially successful fetch (data still usable).
    var warning: String?

    var sessionWindow: UsageWindow? {
        windows.first { $0.kind == .session }
    }

    var weeklyWindow: UsageWindow? {
        windows.first { $0.kind == .weekly }
    }

    /// Convenience 0...1 fractions for progress rings/bars. `nil` when the
    /// window is absent (render as "no data", not as an empty ring).
    var sessionFraction: Double? {
        sessionWindow.map { min(max($0.usedPercent / 100, 0), 1) }
    }

    var weeklyFraction: Double? {
        weeklyWindow.map { min(max($0.usedPercent / 100, 0), 1) }
    }

    static let placeholder = ServiceUsage(
        serviceID: .claude,
        plan: nil,
        windows: [
            UsageWindow(kind: .session, label: "Session", usedPercent: 0, resetsAt: nil, periodDuration: 5 * 3600),
            UsageWindow(kind: .weekly, label: "Weekly", usedPercent: 0, resetsAt: nil, periodDuration: 7 * 86400),
        ],
        refreshedAt: .distantPast,
        warning: nil
    )
}

/// What the UI knows about one service right now. The store layer owns the
/// "keep last good snapshot on failure" rule (research doc §9.2 п.1):
/// a fetch error downgrades `.ready` to `.stale`, never wipes data.
enum ServiceStatus: Equatable, Sendable {
    /// No fetch has completed yet in this app run.
    case loading
    /// Fresh data.
    case ready(ServiceUsage)
    /// Last good data plus the error that made it stale (gray ring + message,
    /// but numbers stay visible — ТЗ §4.3).
    case stale(ServiceUsage, UsageError)
    /// No data at all (e.g. never logged in). Gray ring + hint.
    case unavailable(UsageError)

    var usage: ServiceUsage? {
        switch self {
        case .ready(let usage), .stale(let usage, _): return usage
        case .loading, .unavailable: return nil
        }
    }

    var error: UsageError? {
        switch self {
        case .stale(_, let error), .unavailable(let error): return error
        case .loading, .ready: return nil
        }
    }
}
