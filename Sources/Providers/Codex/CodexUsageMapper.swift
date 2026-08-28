import Foundation

/// Turns `/backend-api/wham/usage` into the frozen `ServiceUsage` contract
/// (ТЗ §4.1, research doc §5.3).
enum CodexUsageMapper {
    static let sessionPeriod: TimeInterval = 5 * 3600
    static let weeklyPeriod: TimeInterval = 7 * 86400

    static func map(response: HTTPResponse, now: Date = Date()) throws -> ServiceUsage {
        guard let json = ProviderParse.jsonObject(response.body) else {
            throw UsageError.decodingFailed("ChatGPT usage response is not a JSON object")
        }
        return map(
            json: json,
            headerPercents: (
                primary: ProviderParse.number(response.header("x-codex-primary-used-percent")),
                secondary: ProviderParse.number(response.header("x-codex-secondary-used-percent"))
            ),
            now: now
        )
    }

    static func map(
        json: [String: Any],
        headerPercents: (primary: Double?, secondary: Double?) = (nil, nil),
        now: Date = Date()
    ) -> ServiceUsage {
        let rateLimit = json["rate_limit"] as? [String: Any]
        return ServiceUsage(
            serviceID: .chatgpt,
            plan: plan(json["plan_type"]),
            windows: windows(rateLimit: rateLimit, headerPercents: headerPercents, now: now),
            refreshedAt: now,
            warning: nil
        )
    }

    // MARK: - Window classification

    private struct Candidate {
        var window: [String: Any]
        var usedPercent: Double?
        /// Slot the window arrived in, used only when its duration is unknown.
        var slotKind: UsageWindow.Kind
    }

    /// Session vs Weekly is decided by `limit_window_seconds`, **not** by the
    /// primary/secondary slot: OpenAI sometimes drops one window and moves the
    /// remaining (usually weekly) one into the primary slot, and a naive
    /// slot-based mapping would then silently mislabel it (research doc §9.3).
    /// The slot is used only as a compatibility fallback when a window reports
    /// no recognizable duration at all.
    static func windows(
        rateLimit: [String: Any]?,
        headerPercents: (primary: Double?, secondary: Double?) = (nil, nil),
        now: Date = Date()
    ) -> [UsageWindow] {
        let candidates = [
            candidate(
                rateLimit?["primary_window"],
                headerPercent: headerPercents.primary,
                slotKind: .session
            ),
            candidate(
                rateLimit?["secondary_window"],
                headerPercent: headerPercents.secondary,
                slotKind: .weekly
            ),
        ].compactMap { $0 }

        return [
            window(kind: .session, label: "Session", candidates: candidates, now: now),
            window(kind: .weekly, label: "Weekly", candidates: candidates, now: now),
        ].compactMap { $0 }
    }

    private static func candidate(
        _ value: Any?,
        headerPercent: Double?,
        slotKind: UsageWindow.Kind
    ) -> Candidate? {
        // With no window object at all, a header percent still counts as data.
        guard let window = value as? [String: Any] ?? (headerPercent == nil ? nil : [:]) else {
            return nil
        }
        return Candidate(
            window: window,
            usedPercent: ProviderParse.number(window["used_percent"]) ?? headerPercent,
            slotKind: slotKind
        )
    }

    private static func window(
        kind: UsageWindow.Kind,
        label: String,
        candidates: [Candidate],
        now: Date
    ) -> UsageWindow? {
        let byDuration = candidates.first { durationKind(of: $0.window) == kind }
        let bySlot = candidates.first { durationKind(of: $0.window) == nil && $0.slotKind == kind }
        guard let candidate = byDuration ?? bySlot,
              // `used_percent` is carried exactly as reported — never inverted,
              // never clamped here (research doc §9.3).
              let usedPercent = candidate.usedPercent
        else {
            return nil
        }
        let defaultPeriod: TimeInterval = kind == .session ? sessionPeriod : weeklyPeriod
        return UsageWindow(
            kind: kind,
            label: label,
            usedPercent: usedPercent,
            resetsAt: resetDate(candidate.window, now: now),
            periodDuration: period(of: candidate.window) ?? defaultPeriod
        )
    }

    private static func durationKind(of window: [String: Any]) -> UsageWindow.Kind? {
        guard let period = period(of: window) else { return nil }
        switch period {
        case sessionPeriod: return .session
        case weeklyPeriod: return .weekly
        default: return nil
        }
    }

    private static func period(of window: [String: Any]?) -> TimeInterval? {
        guard let window, let seconds = ProviderParse.number(window["limit_window_seconds"]) else {
            return nil
        }
        return seconds
    }

    /// `reset_at` is an absolute timestamp, `reset_after_seconds` a duration.
    /// Neither present means the window has not started — never a made-up date.
    private static func resetDate(_ window: [String: Any]?, now: Date) -> Date? {
        guard let window else { return nil }
        if let resetAt = ProviderParse.timestamp(window["reset_at"]) { return resetAt }
        if let after = ProviderParse.number(window["reset_after_seconds"]) {
            return now.addingTimeInterval(after)
        }
        return nil
    }

    // MARK: - Plan

    static func plan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.nilIfBlank else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        default: return ProviderParse.titleCased(raw, separator: { $0 == "_" })
        }
    }
}
