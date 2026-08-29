import Foundation

/// Pure, UI-framework-free helpers for turning `ServiceUsage`/`UsageWindow`
/// numbers into what the design spec calls for: threshold-based ring color
/// (design-spec.md §2.2) and the two reset-time string flavors used by
/// `DetailCardView` (ТЗ §3.4: relative for the session window, absolute for
/// the weekly window). Kept free of SwiftUI/AppKit types so they're directly
/// unit-testable.
enum UsageLevel: Equatable {
    case healthy
    case warning
    case critical

    /// design-spec.md §2.2: ≤50% green, 50–80% yellow, >80% red.
    static func forPercent(_ percent: Double, thresholds: UsageThresholds = .default) -> UsageLevel {
        if percent <= thresholds.warning * 100 {
            return .healthy
        } else if percent <= thresholds.critical * 100 {
            return .warning
        } else {
            return .critical
        }
    }
}

/// Ring color thresholds as fractions (0...1), mirroring
/// `AppSettings.warningThreshold` / `.criticalThreshold` (ТЗ §3.3, §6).
struct UsageThresholds: Equatable {
    var warning: Double
    var critical: Double

    static let `default` = UsageThresholds(warning: 0.5, critical: 0.8)
}

/// Formats `UsageWindow.resetsAt` into the two copy styles the design spec
/// shows (§3.7.2, §7): relative ("Resets in 51 min") for the session window,
/// absolute ("Resets Thu 12:00 AM") for the weekly window. A `nil` reset
/// date means the window hasn't started yet (research doc §9.2 п.5) — always
/// renders as "Not started", distinct from a 0%-used window.
enum ResetFormatter {
    /// "Resets in Xh Ym" / "Resets in Y min" / "Resets now" / "Not started".
    static func relative(resetsAt: Date?, now: Date = Date()) -> String {
        guard let resetsAt else { return "Not started" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Resets now" }
        return "Resets " + relativeShort(seconds: seconds)
    }

    /// Same as `relative` but without the "Resets " prefix, for the
    /// exhausted-state copy: "Mana restores in 51 min." (design-spec §8.1).
    static func relativeShort(resetsAt: Date?, now: Date = Date()) -> String {
        guard let resetsAt else { return "soon" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        return relativeShort(seconds: seconds)
    }

    private static func relativeShort(seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "in \(hours) h \(String(format: "%02d", minutes)) min" : "in \(hours) h"
        }
        return "in \(minutes) min"
    }

    /// "Resets Thu 12:00 AM" / "Resets Sep 1" (falls back to a date when the
    /// reset is more than 6 days out) / "Not started". Renders in
    /// `calendar`'s time zone — defaults to the user's local time zone, with
    /// the locale pinned to en_US_POSIX so the copy always reads in English
    /// (design-spec.md copy is English throughout) regardless of system
    /// region. Tests pass an explicit UTC calendar for determinism.
    static func absolute(resetsAt: Date?, now: Date = Date(), calendar: Calendar = .enUSPOSIX) -> String {
        guard let resetsAt else { return "Not started" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone

        let daysAway = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: resetsAt)).day ?? 0
        if daysAway >= 0 && daysAway < 7 {
            formatter.dateFormat = "EEE h:mm a"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return "Resets " + formatter.string(from: resetsAt)
    }
}

extension ResetFormatter {
    /// "через ~N мин" (deadline within the next hour) / "в HH:MM" (further
    /// out) for the `.rateLimited` detail-card copy (ТЗ §4.3 live-feedback
    /// fix: the previous "Re-login via CLI" button was meaningless for a
    /// rate limit — a manual refresh can't bypass this cooldown either, see
    /// `UsageCoordinator.eligible`). `nil` when the coordinator hasn't
    /// recorded a deadline yet, or it has already passed (the next poll is
    /// about to clear it).
    static func rateLimitRetryHint(cooldownUntil: Date?, now: Date = Date()) -> String? {
        guard let cooldownUntil else { return nil }
        let seconds = cooldownUntil.timeIntervalSince(now)
        guard seconds > 0 else { return nil }

        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 60 {
            return "через ~\(max(1, minutes)) мин"
        }

        let formatter = DateFormatter()
        formatter.calendar = .enUSPOSIX
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return "в \(formatter.string(from: cooldownUntil))"
    }
}

/// What one `RingView` should draw for a given `ServiceStatus` — extracted
/// from the view so the decision is unit-testable without rendering SwiftUI
/// (design-spec.md §3.2–§3.5, plus the stale-ring fix below).
///
/// The fix: `.stale` used to be lumped in with `.unavailable` under a single
/// "is there an error?" test, so a service whose last fetch failed dropped to
/// an empty gray ring labelled "—" even though the panel was still holding
/// perfectly good numbers (the detail card showed them the whole time — only
/// the ring pretended there was nothing). `.stale` now keeps its last known
/// fill and percent label, rendered in the muted style, and keeps the yellow
/// "!" badge to say the number is not fresh. `.unavailable` (no data at all)
/// and `.loading` are unchanged.
struct RingPresentation: Equatable {
    /// Colored progress stroke, 0...1. Zero means "draw only the faint base
    /// ring" — there is no number to show.
    var fillFraction: Double
    /// Text under the ring: "73%" / "···" (loading) / "—" (nothing to show).
    var label: String
    /// Ring stroke, glyph and percent label render in the dimmed "this is not
    /// live data" style rather than the full-strength one.
    var isMuted: Bool
    /// Neutral gray instead of a usage-level (green/yellow/red) color, for the
    /// states that have no percentage behind them at all.
    var usesNeutralColor: Bool
    /// Yellow "!" corner badge (any error, stale or not).
    var showsErrorBadge: Bool
    /// Spinning partial arc — `.loading`, or any in-flight refresh the UI
    /// should acknowledge (`PanelModel.refreshingServiceIDs`).
    var showsSpinner: Bool
    /// Percentage the ring color is derived from (0 when there is none).
    var percent: Double

    static func make(status: ServiceStatus, isRefreshing: Bool = false) -> RingPresentation {
        let percent = status.usage?.sessionWindow?.usedPercent ?? 0
        let fraction = min(max(percent / 100, 0), 1)
        let hasError = status.error != nil

        switch status {
        case .loading:
            return RingPresentation(
                fillFraction: 0,
                label: "···",
                isMuted: true,
                usesNeutralColor: true,
                showsErrorBadge: false,
                showsSpinner: true,
                percent: 0
            )
        case .ready:
            return RingPresentation(
                fillFraction: fraction,
                label: "\(Int(percent.rounded()))%",
                isMuted: false,
                usesNeutralColor: false,
                showsErrorBadge: false,
                showsSpinner: isRefreshing,
                percent: percent
            )
        case .stale:
            return RingPresentation(
                fillFraction: fraction,
                label: "\(Int(percent.rounded()))%",
                isMuted: true,
                usesNeutralColor: false,
                showsErrorBadge: true,
                showsSpinner: isRefreshing,
                percent: percent
            )
        case .unavailable:
            return RingPresentation(
                fillFraction: 0,
                label: "—",
                isMuted: true,
                usesNeutralColor: true,
                showsErrorBadge: hasError,
                showsSpinner: isRefreshing,
                percent: 0
            )
        }
    }
}

/// User-facing text for a `UsageError`.
///
/// `UsageError` is a frozen contract (`Sources/Providers/UsageProvider.swift`)
/// and has a single `.connectionFailed` case covering two situations that feel
/// completely different to the user: "this machine is offline" (fails in
/// milliseconds) and "the request was still waiting when the budget ran out"
/// (fails after the full timeout — the service, DNS or the link is slow, but
/// the machine is online). Printing "Нет соединения" for the second one is a
/// lie the user can disprove by loading any web page, so the coordinator
/// reports which of the two it was (`PanelModel.timedOutServiceIDs`, set from
/// the measured fetch duration) and this picks the honest wording.
enum UsageErrorCopy {
    static let timedOutDescription = "Сервис не отвечает"

    static func text(for error: UsageError, timedOut: Bool) -> String {
        if timedOut, case .connectionFailed = error { return timedOutDescription }
        return error.userDescription
    }
}

extension Calendar {
    /// Gregorian calendar with the locale pinned to en_US_POSIX (so weekday/
    /// month names and AM/PM always render in English) and the system's
    /// current time zone, so reset times display as local wall-clock time.
    static var enUSPOSIX: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}
