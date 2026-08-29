import AppKit
import XCTest
@testable import Mana

/// Coverage for the menu-bar glyph wiring (logo-kit.html "Меню-бар macOS":
/// "Только монохром: macOS перекрашивает template-иконку сам"). The named
/// asset itself (`ManaMarkTemplate`) only resolves from `Bundle.main` when
/// the test host is the real Mana.app bundle, which this plain XCTest bundle
/// isn't — so this locks in the invariant that must hold either way
/// (non-nil, template-rendered image on the status item's button), while the
/// "does ManaMarkTemplate actually load from the built app" fact is checked
/// separately against the real .app bundle, not here.
@MainActor
final class StatusBarControllerTests: XCTestCase {
    func testStatusItemButtonGetsATemplateImage() {
        let controller = StatusBarController()

        XCTAssertNotNil(controller.statusItemImage, "configureButton() must assign an image")
        XCTAssertTrue(
            controller.statusItemImage?.isTemplate ?? false,
            "menu-bar image must be template-rendered so AppKit tints it for light/dark menu bars"
        )
        XCTAssertEqual(controller.statusItemImage?.accessibilityDescription, "Mana")
    }
}
