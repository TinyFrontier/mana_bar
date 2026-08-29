import AppKit
import XCTest
@testable import Mana

/// Coverage for `SettingsWindowController`'s single-instance behavior — the
/// actual bug fixed here (`docs/...`: "Open Settings…" did nothing on newer
/// macOS because the old code opened the SwiftUI `Settings` scene via a
/// private, now-inert selector). The window itself is real AppKit UI and
/// isn't asserted on visually; only the "one instance, reused, survives
/// close" contract is.
@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    /// A second `show()` call must re-front the existing window rather than
    /// allocate a new one — the whole point of owning our own controller
    /// instead of re-deriving an ad-hoc window each time.
    func testShowReusesSameWindowInstance() {
        let controller = SettingsWindowController(makeContentView: { NSView() })
        XCTAssertNil(controller.window, "no window should exist before the first show()")

        controller.show()
        let first = controller.window
        XCTAssertNotNil(first)

        controller.show()
        XCTAssertTrue(controller.window === first, "second show() must reuse the existing window instance")
    }

    /// `isReleasedWhenClosed = false` is what makes this safe: without it,
    /// closing the window deallocates it and the stored reference would
    /// dangle, so a later `show()` would need to notice and rebuild — this
    /// locks in that it doesn't need to, and that reopening after close
    /// doesn't crash or spawn a second window.
    func testWindowSurvivesCloseAndReopenReusesIt() {
        let controller = SettingsWindowController(makeContentView: { NSView() })
        controller.show()
        let first = controller.window
        XCTAssertNotNil(first)

        first?.close()
        XCTAssertNotNil(controller.window, "closing must not release the window (isReleasedWhenClosed = false)")
        XCTAssertTrue(controller.window === first)

        controller.show()
        XCTAssertTrue(controller.window === first, "reopening after close must reuse the same window, not create a second one")
    }

    /// Guards the fix's actual mechanics: the window created by `show()`
    /// must be able to become key (a normal titled/closable window, not a
    /// non-activating panel like `PanelWindow`) and must not release itself
    /// on close.
    func testWindowIsConfiguredToBecomeKeyAndSurviveClose() {
        let controller = SettingsWindowController(makeContentView: { NSView() })
        controller.show()

        guard let window = controller.window else {
            return XCTFail("show() must create a window")
        }
        XCTAssertTrue(window.canBecomeKey, "settings window must be a normal window that can become key")
        XCTAssertFalse(window.isReleasedWhenClosed, "must survive close() so it can be reused")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
    }
}
