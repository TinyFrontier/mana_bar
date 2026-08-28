import Foundation

/// The authenticated-fetch sequence every OAuth provider here shares, written
/// once (research doc §3.3, §9.2 п.3): attempt → on 401/403 refresh the token →
/// retry **exactly once** → a second 401/403 is a hard auth failure. Anything
/// that is not an auth failure (success, 429, 5xx) is handed back untouched for
/// the caller's status triage, so rate-limit handling stays explicit.
///
/// 401 and 403 mean the same thing here — "the token is bad" — per research doc
/// §9.2 п.2.
enum ProviderAuthRetry {
    /// Statuses that mean "the token went bad" rather than "the request failed".
    static func isAuthFailure(_ response: HTTPResponse) -> Bool {
        response.statusCode == 401 || response.statusCode == 403
    }

    /// - Parameters:
    ///   - token: access token for the first attempt.
    ///   - attempt: performs the request; called at most twice.
    ///   - refreshAccessToken: returns a fresh access token, or throws the
    ///     `UsageError` that explains why it cannot (typically
    ///     `.sessionExpired` when there is no refresh token to use).
    static func fetch(
        token: String,
        attempt: (_ accessToken: String) async throws -> HTTPResponse,
        refreshAccessToken: () async throws -> String
    ) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await attempt(token)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.connectionFailed
        }
        guard isAuthFailure(response) else { return response }

        let refreshed = try await refreshAccessToken()

        let retried: HTTPResponse
        do {
            retried = try await attempt(refreshed)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.connectionFailed
        }
        // A second auth failure is final: the CLI tool must log in again.
        if isAuthFailure(retried) { throw UsageError.sessionExpired }
        return retried
    }

    /// Triage a response that should carry a usable body, mapping HTTP status
    /// onto the frozen `UsageError` contract:
    /// - 2xx → returns
    /// - 401/403 → `.sessionExpired`
    /// - 429 → `.rateLimited(retryAfter:)` with `Retry-After` parsed
    /// - anything else → `.requestFailed(statusCode:)`
    ///
    /// Honouring the cooldown is the store layer's job (ТЗ §4.2); the provider's
    /// duty is only to report `retryAfter` truthfully.
    static func requireSuccess(_ response: HTTPResponse, now: Date = Date()) throws {
        if isAuthFailure(response) { throw UsageError.sessionExpired }
        if response.statusCode == 429 {
            throw UsageError.rateLimited(
                retryAfter: retryAfter(from: response, now: now)
            )
        }
        guard response.isSuccess else {
            throw UsageError.requestFailed(statusCode: response.statusCode)
        }
    }

    /// `Retry-After` as a number of seconds. The header is either a decimal
    /// count of seconds **or** an HTTP-date (research doc §9.2 п.4); an absent
    /// or unparseable header yields `nil`, letting the store apply its own
    /// default cooldown.
    static func retryAfter(from response: HTTPResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = response.header("retry-after")?.nilIfBlank else { return nil }
        return retryAfter(headerValue: raw, now: now)
    }

    static func retryAfter(headerValue: String, now: Date = Date()) -> TimeInterval? {
        let raw = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if let seconds = Double(raw), seconds.isFinite {
            return max(0, seconds)
        }
        if let date = HTTPDate.date(from: raw) {
            return max(0, date.timeIntervalSince(now))
        }
        return nil
    }
}

/// RFC 7231 HTTP-date parsing, for `Retry-After` in its date form.
enum HTTPDate {
    private static let formats = [
        "EEE',' dd MMM yyyy HH':'mm':'ss zzz",      // RFC 1123 (the modern form)
        "EEEE',' dd'-'MMM'-'yy HH':'mm':'ss zzz",   // RFC 850 (obsolete)
        "EEE MMM d HH':'mm':'ss yyyy",              // asctime (obsolete)
    ]

    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
