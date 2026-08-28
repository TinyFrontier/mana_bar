import Foundation

/// Captured response/credential shapes the providers must handle. Kept as
/// string literals rather than bundle resources so the suite has no packaging
/// dependency and every fixture is readable next to the test that uses it.
///
/// All tokens below are obviously fake placeholders — no real credential is ever
/// committed here.
enum ProviderFixtures {

    // MARK: - Claude: /api/oauth/usage

    /// The full shape: an ISO-8601 reset, an epoch-seconds reset, an
    /// epoch-milliseconds reset, a scoped weekly limit that has not started, and
    /// a non-`weekly_scoped` entry that must be ignored.
    static let claudeUsage = """
    {
      "five_hour": { "utilization": 42.5, "resets_at": "2026-08-28T18:00:00Z" },
      "seven_day": { "utilization": 71, "resets_at": 1787948269 },
      "seven_day_sonnet": null,
      "limits": [
        {
          "kind": "weekly_scoped",
          "percent": 13.5,
          "resets_at": 1787948269400,
          "scope": { "model": { "display_name": "Opus" } }
        },
        {
          "kind": "weekly_scoped",
          "percent": 4,
          "resets_at": null,
          "scope": { "model": { "display_name": "Sonnet" } }
        },
        {
          "kind": "monthly_scoped",
          "percent": 99,
          "scope": { "model": { "display_name": "Ignored" } }
        }
      ]
    }
    """

    /// Only the weekly window is reported, and it has no `resets_at`: the
    /// session window must be absent entirely rather than invented at 0%.
    static let claudeUsageMissingSession = """
    { "seven_day": { "utilization": 12 } }
    """

    /// The legacy flat per-model key, still emitted by older accounts.
    static let claudeUsageLegacySonnet = """
    {
      "five_hour": { "utilization": 1, "resets_at": "2026-08-28T18:00:00.500Z" },
      "seven_day_sonnet": { "utilization": 33, "resets_at": "2026-09-01T00:00:00Z" }
    }
    """

    static let claudeUsageEmpty = "{}"

    // MARK: - Claude: credentials

    /// `~/.claude/.credentials.json` as Claude Code writes it.
    static func claudeCredentials(
        accessToken: String = "fake-access-token",
        refreshToken: String? = "fake-refresh-token",
        expiresAt: Double = 4102444800000,
        scopes: [String] = ["user:inference", "user:profile"],
        subscriptionType: String = "max"
    ) -> String {
        let refresh = refreshToken.map { "\"refreshToken\": \"\($0)\"," } ?? ""
        let scopeList = scopes.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            \(refresh)
            "expiresAt": \(expiresAt),
            "scopes": [\(scopeList)],
            "subscriptionType": "\(subscriptionType)",
            "rateLimitTier": "default_claude_max_5x"
          }
        }
        """
    }

    // MARK: - ChatGPT/Codex: /backend-api/wham/usage

    /// The usual layout: five-hour window in the primary slot, weekly in the
    /// secondary slot.
    static let codexUsage = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "used_percent": 17.5,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 3600
        },
        "secondary_window": {
          "used_percent": 63,
          "limit_window_seconds": 604800,
          "reset_at": 1787948269
        }
      }
    }
    """

    /// The pitfall case: OpenAI moved the **weekly** window into the primary
    /// slot and the five-hour window into the secondary one. Classification must
    /// follow `limit_window_seconds`, so Session is still 17.5% and Weekly 63%.
    static let codexUsageSwappedWindows = """
    {
      "plan_type": "prolite",
      "rate_limit": {
        "primary_window": {
          "used_percent": 63,
          "limit_window_seconds": 604800,
          "reset_at": 1787948269
        },
        "secondary_window": {
          "used_percent": 17.5,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 3600
        }
      }
    }
    """

    /// Neither window declares a duration — the primary/secondary slots are the
    /// only remaining signal (compatibility fallback).
    static let codexUsageWithoutDurations = """
    {
      "rate_limit": {
        "primary_window": { "used_percent": 8 },
        "secondary_window": { "used_percent": 55 }
      }
    }
    """

    /// A single weekly window, with no secondary at all.
    static let codexUsageWeeklyOnly = """
    {
      "rate_limit": {
        "primary_window": {
          "used_percent": 91,
          "limit_window_seconds": 604800,
          "reset_at": 1787948269
        }
      }
    }
    """

    // MARK: - Codex: auth.json

    static func codexAuth(
        accessToken: String = "header.payload.signature",
        refreshToken: String = "fake-refresh-token",
        accountID: String? = "acct-123",
        lastRefresh: String = "2026-08-27T10:00:00Z"
    ) -> String {
        let account = accountID.map { "\"account_id\": \"\($0)\"," } ?? ""
        return """
        {
          "tokens": {
            "access_token": "\(accessToken)",
            "refresh_token": "\(refreshToken)",
            \(account)
            "id_token": "fake-id-token"
          },
          "last_refresh": "\(lastRefresh)"
        }
        """
    }

    /// A valid Codex setup that simply cannot read subscription usage.
    static let codexAuthAPIKeyOnly = """
    { "OPENAI_API_KEY": "sk-fake-api-key" }
    """
}
