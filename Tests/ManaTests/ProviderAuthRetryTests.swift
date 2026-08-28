import XCTest
@testable import Mana

/// The shared attempt → refresh → retry-once contract, and the HTTP-status
/// triage that feeds `UsageError` (research doc §9.2 п.2–4).
final class ProviderAuthRetryTests: XCTestCase {

    // MARK: - Retry once

    func testSuccessfulFirstAttemptNeverRefreshes() async throws {
        var refreshes = 0
        var tokensUsed: [String] = []

        let response = try await ProviderAuthRetry.fetch(
            token: "first",
            attempt: { token in
                tokensUsed.append(token)
                return .json(#"{"ok":true}"#)
            },
            refreshAccessToken: {
                refreshes += 1
                return "second"
            }
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(tokensUsed, ["first"])
        XCTAssertEqual(refreshes, 0)
    }

    func testUnauthorizedRefreshesAndRetriesExactlyOnce() async throws {
        var tokensUsed: [String] = []
        var responses: [HTTPResponse] = [.status(401), .json(#"{"ok":true}"#)]

        let response = try await ProviderAuthRetry.fetch(
            token: "stale",
            attempt: { token in
                tokensUsed.append(token)
                return responses.removeFirst()
            },
            refreshAccessToken: { "fresh" }
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(tokensUsed, ["stale", "fresh"])
    }

    func testForbiddenIsTreatedExactlyLikeUnauthorized() async throws {
        var tokensUsed: [String] = []
        var responses: [HTTPResponse] = [.status(403), .json(#"{"ok":true}"#)]

        _ = try await ProviderAuthRetry.fetch(
            token: "stale",
            attempt: { token in
                tokensUsed.append(token)
                return responses.removeFirst()
            },
            refreshAccessToken: { "fresh" }
        )

        XCTAssertEqual(tokensUsed, ["stale", "fresh"])
    }

    func testSecondAuthFailureIsFinal() async {
        var attempts = 0
        await XCTAssertUsageErrorAsync(
            try await ProviderAuthRetry.fetch(
                token: "stale",
                attempt: { _ in
                    attempts += 1
                    return .status(403)
                },
                refreshAccessToken: { "fresh" }
            ),
            .sessionExpired
        )
        // Exactly two attempts: no unbounded retry loop.
        XCTAssertEqual(attempts, 2)
    }

    func testTransportFailureBecomesConnectionFailed() async {
        struct Boom: Error {}
        await XCTAssertUsageErrorAsync(
            try await ProviderAuthRetry.fetch(
                token: "token",
                attempt: { _ in throw Boom() },
                refreshAccessToken: { "fresh" }
            ),
            .connectionFailed
        )
    }

    func testRefreshFailurePropagatesItsOwnError() async {
        await XCTAssertUsageErrorAsync(
            try await ProviderAuthRetry.fetch(
                token: "stale",
                attempt: { _ in .status(401) },
                refreshAccessToken: { throw UsageError.sessionExpired }
            ),
            .sessionExpired
        )
    }

    // MARK: - Status triage

    func testSuccessPassesTriage() throws {
        XCTAssertNoThrow(try ProviderAuthRetry.requireSuccess(.status(204)))
    }

    func testAuthStatusesMapToSessionExpired() {
        XCTAssertUsageError(try ProviderAuthRetry.requireSuccess(.status(401)), .sessionExpired)
        XCTAssertUsageError(try ProviderAuthRetry.requireSuccess(.status(403)), .sessionExpired)
    }

    func testOtherStatusesMapToRequestFailed() {
        XCTAssertUsageError(
            try ProviderAuthRetry.requireSuccess(.status(500)),
            .requestFailed(statusCode: 500)
        )
    }

    // MARK: - Retry-After

    func testRateLimitCarriesRetryAfterInSeconds() {
        XCTAssertUsageError(
            try ProviderAuthRetry.requireSuccess(.status(429, headers: ["Retry-After": "120"])),
            .rateLimited(retryAfter: 120)
        )
    }

    func testRetryAfterAcceptsAnHTTPDate() throws {
        // now == Fri, 28 Aug 2026 06:53:20 GMT; the header is five minutes later.
        let now = Date(timeIntervalSince1970: 1_787_900_000)
        XCTAssertEqual(
            HTTPDate.date(from: "Fri, 28 Aug 2026 06:58:20 GMT"),
            Date(timeIntervalSince1970: 1_787_900_300)
        )

        let parsed = ProviderAuthRetry.retryAfter(
            headerValue: "Fri, 28 Aug 2026 06:58:20 GMT",
            now: now
        )
        XCTAssertEqual(try XCTUnwrap(parsed), 300, accuracy: 1)
    }

    func testRateLimitWithAnHTTPDateHeaderIsRelativeToNow() throws {
        let now = Date(timeIntervalSince1970: 1_787_900_000)
        do {
            try ProviderAuthRetry.requireSuccess(
                .status(429, headers: ["retry-after": "Fri, 28 Aug 2026 06:58:20 GMT"]),
                now: now
            )
            XCTFail("expected a rate-limit error")
        } catch let UsageError.rateLimited(retryAfter) {
            XCTAssertEqual(try XCTUnwrap(retryAfter), 300, accuracy: 1)
        } catch {
            XCTFail("expected .rateLimited, got \(error)")
        }
    }

    func testRetryAfterInThePastClampsToZero() {
        let now = Date(timeIntervalSince1970: 1_787_900_000)
        XCTAssertEqual(
            ProviderAuthRetry.retryAfter(headerValue: "Fri, 28 Aug 2026 06:20:00 GMT", now: now),
            0
        )
    }

    func testMissingOrUnparseableRetryAfterIsNil() {
        XCTAssertUsageError(
            try ProviderAuthRetry.requireSuccess(.status(429)),
            .rateLimited(retryAfter: nil)
        )
        XCTAssertNil(ProviderAuthRetry.retryAfter(headerValue: "soon"))
        XCTAssertNil(ProviderAuthRetry.retryAfter(headerValue: "   "))
    }
}
