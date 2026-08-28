import XCTest
@testable import Mana

/// Mapping `/api/oauth/usage` onto the frozen contract — the pitfalls called out
/// in research doc §9.3.
final class ClaudeUsageMapperTests: XCTestCase {
    private let refreshedAt = Date(timeIntervalSince1970: 1_787_900_000)

    private func map(_ json: String, credentials: ClaudeOAuth = ClaudeOAuth()) throws -> ServiceUsage {
        try ClaudeUsageMapper.map(
            body: Data(json.utf8),
            credentials: credentials,
            now: refreshedAt
        )
    }

    // MARK: - resets_at in all three shapes

    func testResetsAtParsesISO8601String() throws {
        let usage = try map(ProviderFixtures.claudeUsage)
        let session = try XCTUnwrap(usage.window(.session))
        XCTAssertEqual(session.usedPercent, 42.5)
        XCTAssertEqual(
            session.resetsAt,
            ISO8601.date(from: "2026-08-28T18:00:00Z")
        )
        XCTAssertEqual(session.periodDuration, 5 * 3600)
        XCTAssertEqual(session.label, "Session")
    }

    func testResetsAtParsesEpochSeconds() throws {
        let usage = try map(ProviderFixtures.claudeUsage)
        let weekly = try XCTUnwrap(usage.window(.weekly))
        XCTAssertEqual(weekly.usedPercent, 71)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_787_948_269))
        XCTAssertEqual(weekly.periodDuration, 7 * 86400)
    }

    func testResetsAtParsesEpochMilliseconds() throws {
        let usage = try map(ProviderFixtures.claudeUsage)
        let opus = try XCTUnwrap(usage.window(.modelWeekly("Opus")))
        XCTAssertEqual(opus.usedPercent, 13.5)
        XCTAssertEqual(opus.resetsAt, Date(timeIntervalSince1970: 1_787_948_269.4))
    }

    func testMillisecondHeuristicKeepsSecondsAndMillisecondsApart() {
        // 1e10 is the switchover: below it the value is seconds, above it ms.
        XCTAssertEqual(
            ProviderParse.timestamp(1_787_948_269),
            Date(timeIntervalSince1970: 1_787_948_269)
        )
        XCTAssertEqual(
            ProviderParse.timestamp(1_787_948_269_400),
            Date(timeIntervalSince1970: 1_787_948_269.4)
        )
    }

    // MARK: - weekly_scoped array

    func testScopedWeeklyLimitsComeFromTheLimitsArray() throws {
        let usage = try map(ProviderFixtures.claudeUsage)
        let modelWindows = usage.windows.filter {
            if case .modelWeekly = $0.kind { return true }
            return false
        }
        XCTAssertEqual(modelWindows.map(\.label), ["Opus", "Sonnet"])
        XCTAssertEqual(modelWindows.map(\.periodDuration), [7 * 86400, 7 * 86400])
    }

    func testScopedEntryWithoutResetsAtHasNoDate() throws {
        let usage = try map(ProviderFixtures.claudeUsage)
        let sonnet = try XCTUnwrap(usage.window(.modelWeekly("Sonnet")))
        XCTAssertEqual(sonnet.usedPercent, 4)
        // Window not started — must stay nil, never a substituted date.
        XCTAssertNil(sonnet.resetsAt)
    }

    func testNonWeeklyScopedLimitsAreIgnored() throws {
        let usage = try map(ProviderFixtures.claudeUsage)
        XCTAssertFalse(usage.windows.contains { $0.label == "Ignored" })
    }

    func testLegacyFlatSonnetKeyStillMaps() throws {
        let usage = try map(ProviderFixtures.claudeUsageLegacySonnet)
        let sonnet = try XCTUnwrap(usage.window(.modelWeekly("Sonnet")))
        XCTAssertEqual(sonnet.usedPercent, 33)
        XCTAssertNotNil(usage.window(.session)?.resetsAt)
    }

    func testScopedLimitDoesNotDuplicateTheLegacyKey() {
        let legacy = UsageWindow(
            kind: .modelWeekly("Sonnet"),
            label: "Sonnet",
            usedPercent: 33,
            resetsAt: nil,
            periodDuration: nil
        )
        let limits: [Any] = [[
            "kind": "weekly_scoped",
            "percent": 44,
            "scope": ["model": ["display_name": "Sonnet"]],
        ]]
        let scoped = ClaudeUsageMapper.scopedWeeklyWindows(
            limits,
            excluding: [legacy.label]
        )
        XCTAssertTrue(scoped.isEmpty)
    }

    // MARK: - Missing windows

    func testMissingSessionWindowIsAbsentNotZero() throws {
        let usage = try map(ProviderFixtures.claudeUsageMissingSession)
        XCTAssertNil(usage.window(.session))
        XCTAssertNil(usage.sessionFraction)
        let weekly = try XCTUnwrap(usage.window(.weekly))
        XCTAssertEqual(weekly.usedPercent, 12)
        XCTAssertNil(weekly.resetsAt)
    }

    func testEmptyPayloadYieldsNoWindows() throws {
        let usage = try map(ProviderFixtures.claudeUsageEmpty)
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertNil(usage.plan)
        XCTAssertEqual(usage.serviceID, .claude)
        XCTAssertEqual(usage.refreshedAt, refreshedAt)
    }

    func testNonObjectBodyIsADecodingFailure() {
        XCTAssertUsageError(
            try ClaudeUsageMapper.map(body: Data("[]".utf8), credentials: ClaudeOAuth()),
            .decodingFailed("Claude usage response is not a JSON object")
        )
    }

    // MARK: - Plan

    func testPlanComesFromTheTokenMetadata() throws {
        let credentials = ClaudeOAuth(
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_5x"
        )
        let usage = try map(ProviderFixtures.claudeUsage, credentials: credentials)
        XCTAssertEqual(usage.plan, "Max 5x")
    }

    func testPlanWithoutTierKeepsJustTheSubscriptionName() {
        XCTAssertEqual(
            ClaudeUsageMapper.formatPlan(subscriptionType: "pro", rateLimitTier: nil),
            "Pro"
        )
        XCTAssertNil(ClaudeUsageMapper.formatPlan(subscriptionType: nil, rateLimitTier: "5x"))
    }
}
