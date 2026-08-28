import Foundation

/// Turns the `/api/oauth/usage` payload into the frozen `ServiceUsage` contract
/// (ТЗ §4.1, research doc §4.3).
enum ClaudeUsageMapper {
    static let sessionPeriod: TimeInterval = 5 * 3600
    static let weeklyPeriod: TimeInterval = 7 * 86400

    /// - Parameters:
    ///   - body: raw response body. Never logged.
    ///   - credentials: the OAuth blob the request was made with — Claude reports
    ///     the plan on the token, not in the usage body.
    static func map(
        body: Data,
        credentials: ClaudeOAuth,
        now: Date = Date()
    ) throws -> ServiceUsage {
        guard let json = ProviderParse.jsonObject(body) else {
            throw UsageError.decodingFailed("Claude usage response is not a JSON object")
        }
        return map(json: json, credentials: credentials, now: now)
    }

    static func map(
        json: [String: Any],
        credentials: ClaudeOAuth,
        now: Date = Date()
    ) -> ServiceUsage {
        var windows: [UsageWindow] = []

        // A missing window stays missing: never fabricate a 0% reading
        // (research doc §9.2 п.10).
        if let session = window(
            json["five_hour"],
            kind: .session,
            label: "Session",
            percentKey: "utilization",
            period: sessionPeriod
        ) {
            windows.append(session)
        }
        if let weekly = window(
            json["seven_day"],
            kind: .weekly,
            label: "Weekly",
            percentKey: "utilization",
            period: weeklyPeriod
        ) {
            windows.append(weekly)
        }

        // Legacy per-model key. Anthropic now returns `null` here and reports the
        // same limit through `limits[]`, so it is read only as a fallback.
        if let sonnet = window(
            json["seven_day_sonnet"],
            kind: .modelWeekly("Sonnet"),
            label: "Sonnet",
            percentKey: "utilization",
            period: weeklyPeriod
        ) {
            windows.append(sonnet)
        }

        windows.append(contentsOf: scopedWeeklyWindows(
            json["limits"],
            excluding: Set(windows.compactMap(modelName(of:)))
        ))

        return ServiceUsage(
            serviceID: .claude,
            plan: plan(json: json, credentials: credentials),
            windows: windows,
            refreshedAt: now,
            warning: nil
        )
    }

    /// Model-scoped weekly limits from `limits[]`: entries with
    /// `kind == "weekly_scoped"`, named by `scope.model.display_name`, with
    /// `percent` already on a 0–100 scale (research doc §9.3). Reading the old
    /// flat `seven_day_<model>` keys instead is what leaves these rows stuck on
    /// "No data".
    static func scopedWeeklyWindows(
        _ value: Any?,
        excluding names: Set<String> = []
    ) -> [UsageWindow] {
        guard let entries = value as? [Any] else { return [] }
        var seen = names
        var windows: [UsageWindow] = []

        for entry in entries {
            guard let object = entry as? [String: Any],
                  object["kind"] as? String == "weekly_scoped",
                  let scope = object["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let displayName = (model["display_name"] as? String)?.nilIfBlank,
                  !seen.contains(displayName),
                  let used = ProviderParse.number(object["percent"])
            else {
                continue
            }
            seen.insert(displayName)
            windows.append(UsageWindow(
                kind: .modelWeekly(displayName),
                label: displayName,
                usedPercent: used,
                resetsAt: ProviderParse.timestamp(object["resets_at"]),
                periodDuration: weeklyPeriod
            ))
        }
        return windows
    }

    /// `{ utilization, resets_at }`. `resets_at` may be an ISO-8601 string or a
    /// number in seconds or milliseconds; absent means the window has not
    /// started yet, which the UI shows as "Not started" rather than 0%
    /// (research doc §9.2 п.5).
    private static func window(
        _ value: Any?,
        kind: UsageWindow.Kind,
        label: String,
        percentKey: String,
        period: TimeInterval
    ) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let used = ProviderParse.number(object[percentKey])
        else {
            return nil
        }
        return UsageWindow(
            kind: kind,
            label: label,
            usedPercent: used,
            resetsAt: ProviderParse.timestamp(object["resets_at"]),
            periodDuration: period
        )
    }

    private static func modelName(of window: UsageWindow) -> String? {
        if case .modelWeekly(let name) = window.kind { return name }
        return nil
    }

    /// "Max 5x", "Pro", … Built from the token's own `subscriptionType` /
    /// `rateLimitTier`, with the response body preferred when it carries them.
    static func plan(json: [String: Any], credentials: ClaudeOAuth) -> String? {
        let subscription = (json["subscription_type"] as? String)?.nilIfBlank
            ?? credentials.subscriptionType?.nilIfBlank
        let tier = (json["rate_limit_tier"] as? String)?.nilIfBlank
            ?? credentials.rateLimitTier?.nilIfBlank
        return formatPlan(subscriptionType: subscription, rateLimitTier: tier)
    }

    static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.nilIfBlank else { return nil }
        let base = ProviderParse.titleCased(
            raw,
            separator: { $0 == " " || $0 == "_" },
            lowercasingTail: true
        )
        guard let tier = rateLimitTier,
              let match = tier.range(of: #"\d+x"#, options: .regularExpression)
        else {
            return base
        }
        return "\(base) \(tier[match])"
    }
}
