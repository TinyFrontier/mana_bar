import XCTest
@testable import Mana

/// Smoke test: confirms the test target links against the app target and the
/// frozen data contract behaves as expected. Real coverage (providers,
/// hot-zone geometry, panel state machine) arrives with the implementation
/// phase.
final class ManaTests: XCTestCase {
    func testServiceUsagePlaceholderHasBothWindows() {
        let placeholder = ServiceUsage.placeholder
        XCTAssertEqual(placeholder.serviceID, .claude)
        XCTAssertEqual(placeholder.sessionFraction, 0)
        XCTAssertEqual(placeholder.weeklyFraction, 0)
        XCTAssertNil(placeholder.warning)
    }

    func testServiceStatusExposesUsageAndError() {
        XCTAssertNil(ServiceStatus.loading.usage)
        XCTAssertNil(ServiceStatus.loading.error)
        XCTAssertEqual(ServiceStatus.ready(.placeholder).usage, .placeholder)
        XCTAssertEqual(
            ServiceStatus.stale(.placeholder, .connectionFailed).error,
            .connectionFailed
        )
        XCTAssertNil(ServiceStatus.unavailable(.notLoggedIn).usage)
    }

    func testServiceIDDisplayNames() {
        XCTAssertEqual(ServiceID.claude.displayName, "Claude")
        XCTAssertEqual(ServiceID.chatgpt.displayName, "ChatGPT")
    }
}
