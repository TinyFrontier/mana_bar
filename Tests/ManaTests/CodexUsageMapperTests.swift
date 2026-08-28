import XCTest
@testable import Mana

/// Mapping `/backend-api/wham/usage`. The window classification test is the
/// important one: it fails loudly if anyone reintroduces the "primary is always
/// the session window" assumption (research doc §9.3).
final class CodexUsageMapperTests: XCTestCase {
    private let refreshedAt = Date(timeIntervalSince1970: 1_787_900_000)

    private func map(
        _ json: String,
        headers: [String: String] = [:]
    ) throws -> ServiceUsage {
        try CodexUsageMapper.map(
            response: .json(json, headers: headers),
            now: refreshedAt
        )
    }

    // MARK: - Classification by limit_window_seconds

    func testWindowsClassifyByDurationInTheUsualLayout() throws {
        let usage = try map(ProviderFixtures.codexUsage)
        XCTAssertEqual(usage.window(.session)?.usedPercent, 17.5)
        XCTAssertEqual(usage.window(.weekly)?.usedPercent, 63)
        XCTAssertEqual(usage.plan, "Pro 20x")
    }

    func testSwappedPrimaryAndSecondaryStillClassifyByDuration() throws {
        let usage = try map(ProviderFixtures.codexUsageSwappedWindows)
        // The weekly window arrived in the *primary* slot; duration decides.
        let session = try XCTUnwrap(usage.window(.session))
        let weekly = try XCTUnwrap(usage.window(.weekly))
        XCTAssertEqual(session.usedPercent, 17.5)
        XCTAssertEqual(session.periodDuration, 18000)
        XCTAssertEqual(weekly.usedPercent, 63)
        XCTAssertEqual(weekly.periodDuration, 604_800)
        XCTAssertEqual(usage.plan, "Pro 5x")
    }

    func testSlotOrderIsOnlyAFallbackWhenDurationsAreMissing() throws {
        let usage = try map(ProviderFixtures.codexUsageWithoutDurations)
        XCTAssertEqual(usage.window(.session)?.usedPercent, 8)
        XCTAssertEqual(usage.window(.weekly)?.usedPercent, 55)
        // No duration reported — the contract's defaults fill in.
        XCTAssertEqual(usage.window(.session)?.periodDuration, 5 * 3600)
        XCTAssertEqual(usage.window(.weekly)?.periodDuration, 7 * 86400)
    }

    func testSoleWeeklyWindowInThePrimarySlotIsNotLabelledSession() throws {
        let usage = try map(ProviderFixtures.codexUsageWeeklyOnly)
        XCTAssertNil(usage.window(.session))
        XCTAssertEqual(usage.window(.weekly)?.usedPercent, 91)
    }

    // MARK: - Percentages and reset times

    func testUsedPercentIsNeverInverted() throws {
        let usage = try map(ProviderFixtures.codexUsage)
        // 17.5% used stays 17.5 — turning it into "82.5 left" here is the bug
        // research doc §9.3 warns about.
        XCTAssertEqual(usage.window(.session)?.usedPercent, 17.5)
        XCTAssertEqual(usage.sessionFraction, 0.175)
    }

    func testResetAfterSecondsBecomesAnAbsoluteDate() throws {
        let usage = try map(ProviderFixtures.codexUsage)
        XCTAssertEqual(
            usage.window(.session)?.resetsAt,
            refreshedAt.addingTimeInterval(3600)
        )
    }

    func testResetAtIsReadAsAnAbsoluteTimestamp() throws {
        let usage = try map(ProviderFixtures.codexUsage)
        XCTAssertEqual(
            usage.window(.weekly)?.resetsAt,
            Date(timeIntervalSince1970: 1_787_948_269)
        )
    }

    func testWindowWithNoResetInformationHasNoDate() throws {
        let usage = try map(ProviderFixtures.codexUsageWithoutDurations)
        XCTAssertNil(usage.window(.session)?.resetsAt)
    }

    // MARK: - Header fallbacks and empties

    func testHeaderPercentsFillInWhenTheBodyOmitsThem() throws {
        let usage = try map(
            #"{ "rate_limit": { "primary_window": { "limit_window_seconds": 18000 } } }"#,
            headers: ["x-codex-primary-used-percent": "23.5"]
        )
        XCTAssertEqual(usage.window(.session)?.usedPercent, 23.5)
    }

    func testMissingRateLimitYieldsNoWindows() throws {
        let usage = try map("{}")
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertNil(usage.sessionFraction)
        XCTAssertEqual(usage.serviceID, .chatgpt)
    }

    func testNonObjectBodyIsADecodingFailure() {
        XCTAssertUsageError(
            try CodexUsageMapper.map(response: .json("not json")),
            .decodingFailed("ChatGPT usage response is not a JSON object")
        )
    }

    func testPlanNamesAreHumanReadable() {
        XCTAssertEqual(CodexUsageMapper.plan("pro"), "Pro 20x")
        XCTAssertEqual(CodexUsageMapper.plan("prolite"), "Pro 5x")
        XCTAssertEqual(CodexUsageMapper.plan("team_business"), "Team Business")
        XCTAssertNil(CodexUsageMapper.plan(nil))
    }
}
