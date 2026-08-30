import Foundation

/// Maps Cursor's `GetCurrentPeriodUsage` response into `ServiceUsage`.
///
/// The response is shaped around a billing cycle rather than rolling windows,
/// as observed live:
///
/// ```json
/// {
///   "billingCycleStart": "1785565415253",
///   "billingCycleEnd": "1788243815253",
///   "planUsage": { "totalPercentUsed": 0, "autoPercentUsed": 0, "apiPercentUsed": 0 },
///   "spendLimitUsage": { "limitType": "user", … }
/// }
/// ```
///
/// Cycle bounds arrive as **strings** holding epoch milliseconds, which is why
/// everything numeric goes through `ProviderParse.number`.
enum CursorUsageMapper {
    /// Label for the one window Cursor reports, matching the wording its own
    /// dashboard uses ("You've used N% of your included usage").
    static let includedUsageLabel = "Included usage"
    static let apiUsageLabel = "API usage"

    static func map(
        response: HTTPResponse,
        membershipType: String?,
        now: Date = Date()
    ) throws -> ServiceUsage {
        guard let json = ProviderParse.jsonObject(response.body) else {
            throw UsageError.decodingFailed("Cursor usage response is not a JSON object")
        }

        // `enabled: false` is the only explicit "off"; absent reads as enabled.
        if json["enabled"] as? Bool == false {
            throw UsageError.missingScope
        }

        let planUsage = json["planUsage"] as? [String: Any]
        guard let totalPercent = ProviderParse.number(planUsage?["totalPercentUsed"]) else {
            // No usable figure: report it rather than inventing a 0% window
            // (research doc §9.2 п.10 — a fabricated window reads as "you have
            // used nothing", which is a claim Mana cannot make).
            throw UsageError.decodingFailed("Cursor usage response carries no totalPercentUsed")
        }

        let cycleStart = date(from: json["billingCycleStart"])
        let cycleEnd = date(from: json["billingCycleEnd"])
        let period = cycleStart.flatMap { start in
            cycleEnd.map { $0.timeIntervalSince(start) }
        }

        var windows = [
            UsageWindow(
                kind: .billingPeriod,
                label: includedUsageLabel,
                usedPercent: clamped(totalPercent),
                resetsAt: cycleEnd,
                periodDuration: period.map { max(0, $0) }
            )
        ]

        // Only worth a second row when it says something the total does not.
        if let apiPercent = ProviderParse.number(planUsage?["apiPercentUsed"]),
           apiPercent > 0,
           apiPercent != totalPercent {
            windows.append(UsageWindow(
                kind: .modelWeekly(apiUsageLabel),
                label: apiUsageLabel,
                usedPercent: clamped(apiPercent),
                resetsAt: cycleEnd,
                periodDuration: period.map { max(0, $0) }
            ))
        }

        return ServiceUsage(
            serviceID: .cursor,
            plan: planLabel(membershipType),
            windows: windows,
            refreshedAt: now,
            warning: nil
        )
    }

    /// "free" → "Free". Cursor stores the membership type lowercased in its
    /// own state; the panel shows plan labels capitalized.
    static func planLabel(_ membershipType: String?) -> String? {
        guard let raw = membershipType?.nilIfBlank?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
    }

    private static func date(from value: Any?) -> Date? {
        guard let milliseconds = ProviderParse.number(value), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func clamped(_ percent: Double) -> Double {
        min(max(percent, 0), 100)
    }
}
