import XCTest
@testable import Mana

/// Setup-phase smoke test: confirms the test target links against the app
/// target and basic model types behave as expected. Real coverage
/// (providers, hot-zone geometry, panel state machine) arrives with the
/// implementation phase.
final class ManaTests: XCTestCase {
    func testServiceUsagePlaceholderIsOK() {
        let placeholder = ServiceUsage.placeholder
        XCTAssertEqual(placeholder.serviceID, .claude)
        XCTAssertEqual(placeholder.state, .ok)
        XCTAssertEqual(placeholder.sessionPercent, 0)
    }

    func testServiceIDDisplayNames() {
        XCTAssertEqual(ServiceID.claude.displayName, "Claude")
        XCTAssertEqual(ServiceID.chatgpt.displayName, "ChatGPT")
    }
}
