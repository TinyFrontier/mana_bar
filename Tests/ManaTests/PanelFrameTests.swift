import XCTest
@testable import Mana

/// Coverage for the pure window-frame math behind `PanelWindow`
/// (`PanelLayoutMetrics.dockedFrame` / `.offscreenFrame`, ТЗ §3.2, §6).
///
/// The regression these lock down: the island must sit *flush* against the
/// physical screen edge. Two things have to hold for that — the window's
/// trailing edge lands exactly on `screen.frame.maxX` (here), and `PanelView`
/// pins the island to the container's trailing edge (there). Screens with a
/// non-zero origin and negative-origin screens (a display placed to the left
/// of the main one) are covered explicitly because that's where a
/// `visibleFrame`/`maxX` mix-up shows up.
final class PanelFrameTests: XCTestCase {
    private let serviceCount = 2

    private func frame(
        screen: CGRect,
        position: PanelVerticalPosition = .center,
        edge: PanelEdge = .right
    ) -> CGRect {
        PanelLayoutMetrics.dockedFrame(
            screenFrame: screen,
            serviceCount: serviceCount,
            verticalPosition: position,
            edge: edge
        )
    }

    // MARK: - Horizontal: flush against the edge

    func testDockedFrameRightEdgeMatchesScreenMaxX() {
        let screens: [CGRect] = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),          // built-in, main
            CGRect(x: 1440, y: 0, width: 2560, height: 1440),      // second display, to the right
            CGRect(x: -2560, y: -300, width: 2560, height: 1440),  // second display, to the left
            CGRect(x: 0, y: 0, width: 3456, height: 2234),         // 16" notch-height screen
        ]

        for screen in screens {
            let docked = frame(screen: screen)
            XCTAssertEqual(docked.maxX, screen.maxX, accuracy: 0.001, "right edge must be flush on \(screen)")
            XCTAssertEqual(docked.width, PanelLayoutMetrics.containerWidth(), accuracy: 0.001)
            XCTAssertEqual(
                docked.height,
                PanelLayoutMetrics.containerHeight(serviceCount: serviceCount),
                accuracy: 0.001
            )
            // Fully on-screen horizontally: nothing spills onto a neighbouring display.
            XCTAssertGreaterThanOrEqual(docked.minX, screen.minX)
        }
    }

    func testDockedFrameLeftEdgeMatchesScreenMinX() {
        let screen = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let docked = frame(screen: screen, edge: .left)
        XCTAssertEqual(docked.minX, screen.minX, accuracy: 0.001)
    }

    // MARK: - Vertical: follows `PanelVerticalPosition` via the island, not the container

    /// The container is much taller than the visible island; `.top`/`.bottom`
    /// describe where the *island* lands, so that's what these assert.
    private func islandCenterY(in docked: CGRect) -> CGFloat { docked.midY }

    func testVerticalPositions() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let islandHeight = PanelLayoutMetrics.panelHeight(serviceCount: serviceCount)
        let margin = PanelLayoutMetrics.verticalEdgeMargin

        let centered = frame(screen: screen, position: .center)
        XCTAssertEqual(islandCenterY(in: centered), screen.midY, accuracy: 0.001)

        let top = frame(screen: screen, position: .top)
        XCTAssertEqual(islandCenterY(in: top), screen.maxY - margin - islandHeight / 2, accuracy: 0.001)

        let bottom = frame(screen: screen, position: .bottom)
        XCTAssertEqual(islandCenterY(in: bottom), screen.minY + margin + islandHeight / 2, accuracy: 0.001)

        // Every vertical placement keeps the same flush right edge.
        for docked in [centered, top, bottom] {
            XCTAssertEqual(docked.maxX, screen.maxX, accuracy: 0.001)
        }
    }

    func testVerticalPositionsOnOffsetScreen() {
        // A display whose origin isn't (0,0) — the case that breaks any
        // implementation that quietly assumes screen coordinates start at zero.
        let screen = CGRect(x: 1440, y: 200, width: 2560, height: 1440)
        let islandHeight = PanelLayoutMetrics.panelHeight(serviceCount: serviceCount)
        let margin = PanelLayoutMetrics.verticalEdgeMargin

        XCTAssertEqual(islandCenterY(in: frame(screen: screen, position: .center)), screen.midY, accuracy: 0.001)
        XCTAssertEqual(
            islandCenterY(in: frame(screen: screen, position: .top)),
            screen.maxY - margin - islandHeight / 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            islandCenterY(in: frame(screen: screen, position: .bottom)),
            screen.minY + margin + islandHeight / 2,
            accuracy: 0.001
        )
    }

    // MARK: - Off-screen (slide origin/destination)

    func testOffscreenFrameSitsJustPastTheEdgeAtTheSameHeight() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let docked = frame(screen: screen)
        let hidden = PanelLayoutMetrics.offscreenFrame(
            screenFrame: screen,
            serviceCount: serviceCount,
            verticalPosition: .center
        )

        XCTAssertEqual(hidden.minX, screen.maxX, accuracy: 0.001)
        XCTAssertEqual(hidden.origin.y, docked.origin.y, accuracy: 0.001)
        XCTAssertEqual(hidden.size, docked.size)

        let hiddenLeft = PanelLayoutMetrics.offscreenFrame(
            screenFrame: screen,
            serviceCount: serviceCount,
            verticalPosition: .center,
            edge: .left
        )
        XCTAssertEqual(hiddenLeft.maxX, screen.minX, accuracy: 0.001)
    }

    // MARK: - Agreement with the hot zone (ТЗ §3.1: strip must sit under the island)

    func testHotZoneStripSharesTheDockedEdgeAndVerticalBand() {
        let screen = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let islandHeight = PanelLayoutMetrics.panelHeight(serviceCount: serviceCount)

        for position in PanelVerticalPosition.allCases {
            let docked = frame(screen: screen, position: position)
            let strip = HotZoneGeometry.rect(
                screenFrame: screen,
                panelHeight: islandHeight,
                width: 3,
                edge: .right,
                verticalPosition: position
            )
            XCTAssertEqual(strip.maxX, docked.maxX, accuracy: 0.001, "\(position): strip and panel share the edge")
            XCTAssertEqual(strip.midY, docked.midY, accuracy: 0.001, "\(position): strip sits over the island")
        }
    }
}
