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
        edge: PanelEdge = .right,
        verticalOffset: CGFloat = 0
    ) -> CGRect {
        PanelLayoutMetrics.dockedFrame(
            screenFrame: screen,
            serviceCount: serviceCount,
            verticalPosition: position,
            edge: edge,
            verticalOffset: verticalOffset
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

    /// Same coverage as `testDockedFrameRightEdgeMatchesScreenMaxX`, mirrored
    /// for `.left` — including a second-display-to-the-left screen with a
    /// negative origin, the case most likely to break a `minX`/`maxX`
    /// mix-up.
    func testDockedFrameLeftEdgeMatchesScreenMinXAcrossScreens() {
        let screens: [CGRect] = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),          // built-in, main
            CGRect(x: 1440, y: 0, width: 2560, height: 1440),      // second display, to the right
            CGRect(x: -2560, y: -300, width: 2560, height: 1440),  // second display, to the left
            CGRect(x: 0, y: 0, width: 3456, height: 2234),         // 16" notch-height screen
        ]

        for screen in screens {
            let docked = frame(screen: screen, edge: .left)
            XCTAssertEqual(docked.minX, screen.minX, accuracy: 0.001, "left edge must be flush on \(screen)")
            XCTAssertEqual(docked.width, PanelLayoutMetrics.containerWidth(), accuracy: 0.001)
            XCTAssertEqual(
                docked.height,
                PanelLayoutMetrics.containerHeight(serviceCount: serviceCount),
                accuracy: 0.001
            )
            // Fully on-screen horizontally: nothing spills onto a neighbouring display.
            XCTAssertLessThanOrEqual(docked.maxX, screen.maxX)
        }
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

    /// `.left` docking must follow the exact same vertical math as `.right`
    /// — only the horizontal edge changes — on a multi-monitor screen with a
    /// negative origin (the case most likely to expose a `minY`/`maxY`
    /// mix-up specific to the left-edge branch).
    func testVerticalPositionsForLeftEdgeOnNegativeOriginScreen() {
        let screen = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
        let islandHeight = PanelLayoutMetrics.panelHeight(serviceCount: serviceCount)
        let margin = PanelLayoutMetrics.verticalEdgeMargin

        let centered = frame(screen: screen, position: .center, edge: .left)
        XCTAssertEqual(islandCenterY(in: centered), screen.midY, accuracy: 0.001)

        let top = frame(screen: screen, position: .top, edge: .left)
        XCTAssertEqual(islandCenterY(in: top), screen.maxY - margin - islandHeight / 2, accuracy: 0.001)

        let bottom = frame(screen: screen, position: .bottom, edge: .left)
        XCTAssertEqual(islandCenterY(in: bottom), screen.minY + margin + islandHeight / 2, accuracy: 0.001)

        // Every vertical placement keeps the same flush left edge.
        for docked in [centered, top, bottom] {
            XCTAssertEqual(docked.minX, screen.minX, accuracy: 0.001)
        }
    }

    // MARK: - Vertical offset (ТЗ §6 "свободное смещение")

    /// A moderate offset just shifts the island by exactly that many points
    /// off whichever anchor (center/top/bottom) is selected — positive moves
    /// it up, matching AppKit's bottom-left-origin screen coordinates.
    func testVerticalOffsetShiftsIslandFromItsAnchor() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let unshifted = frame(screen: screen, position: .center)
        let shiftedUp = frame(screen: screen, position: .center, verticalOffset: 120)
        XCTAssertEqual(islandCenterY(in: shiftedUp), islandCenterY(in: unshifted) + 120, accuracy: 0.001)

        let shiftedDown = frame(screen: screen, position: .center, verticalOffset: -80)
        XCTAssertEqual(islandCenterY(in: shiftedDown), islandCenterY(in: unshifted) - 80, accuracy: 0.001)

        // Composes with .top/.bottom too, not just .center.
        let topUnshifted = frame(screen: screen, position: .top)
        let topShifted = frame(screen: screen, position: .top, verticalOffset: -50)
        XCTAssertEqual(islandCenterY(in: topShifted), islandCenterY(in: topUnshifted) - 50, accuracy: 0.001)

        // The horizontal edge and container size are unaffected.
        XCTAssertEqual(shiftedUp.maxX, screen.maxX, accuracy: 0.001)
        XCTAssertEqual(shiftedUp.size, unshifted.size)
    }

    /// Same shift, mirrored for `.left` — the vertical offset math is
    /// edge-independent, but this locks that down explicitly rather than
    /// relying on `.right` coverage alone.
    func testVerticalOffsetShiftsIslandFromItsAnchorOnLeftEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let unshifted = frame(screen: screen, position: .center, edge: .left)
        let shiftedUp = frame(screen: screen, position: .center, edge: .left, verticalOffset: 120)
        XCTAssertEqual(islandCenterY(in: shiftedUp), islandCenterY(in: unshifted) + 120, accuracy: 0.001)

        let shiftedDown = frame(screen: screen, position: .center, edge: .left, verticalOffset: -80)
        XCTAssertEqual(islandCenterY(in: shiftedDown), islandCenterY(in: unshifted) - 80, accuracy: 0.001)

        // The horizontal edge (now left) and container size are unaffected.
        XCTAssertEqual(shiftedUp.minX, screen.minX, accuracy: 0.001)
        XCTAssertEqual(shiftedUp.size, unshifted.size)
    }

    /// However large the configured offset, the *island* must never slide
    /// past the screen's top/bottom edge — only the (much taller) container,
    /// which already overhangs by design to host the card flyout, is allowed
    /// to extend past the screen.
    func testVerticalOffsetClampsAtScreenEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let islandHeight = PanelLayoutMetrics.panelHeight(serviceCount: serviceCount)
        let minIslandCenterY = screen.minY + islandHeight / 2
        let maxIslandCenterY = screen.maxY - islandHeight / 2

        // Way beyond the slider's own ±400 UI bound (AppSettings
        // .verticalOffsetRange) — the layout math itself must still hold.
        let pushedToTop = frame(screen: screen, position: .center, verticalOffset: 10_000)
        XCTAssertEqual(islandCenterY(in: pushedToTop), maxIslandCenterY, accuracy: 0.001)

        let pushedToBottom = frame(screen: screen, position: .center, verticalOffset: -10_000)
        XCTAssertEqual(islandCenterY(in: pushedToBottom), minIslandCenterY, accuracy: 0.001)

        // Clamping composes with .top/.bottom anchors too: a large enough
        // negative offset from .top still stops at the bottom edge, not
        // beyond it.
        let topPushedToBottom = frame(screen: screen, position: .top, verticalOffset: -10_000)
        XCTAssertEqual(islandCenterY(in: topPushedToBottom), minIslandCenterY, accuracy: 0.001)

        // A moderate offset that's already within bounds is untouched by
        // clamping (regression guard against an over-eager clamp).
        let withinBounds = frame(screen: screen, position: .center, verticalOffset: 50)
        XCTAssertEqual(islandCenterY(in: withinBounds), screen.midY + 50, accuracy: 0.001)
    }

    /// The hot-zone strip must track the offset exactly the same way, or
    /// hovering near the (now-shifted) island stops reaching the invisible
    /// strip that's supposed to be right under it.
    func testHotZoneStripTracksVerticalOffset() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let islandHeight = PanelLayoutMetrics.panelHeight(serviceCount: serviceCount)

        for offset: CGFloat in [-300, 0, 150, 10_000, -10_000] {
            let docked = frame(screen: screen, position: .center, verticalOffset: offset)
            let strip = HotZoneGeometry.rect(
                screenFrame: screen,
                panelHeight: islandHeight,
                width: 3,
                edge: .right,
                verticalPosition: .center,
                verticalOffset: offset
            )
            XCTAssertEqual(strip.midY, docked.midY, accuracy: 0.001, "offset \(offset): strip must sit over the shifted island")
        }
    }

    /// Same tracking, mirrored for `.left`.
    func testHotZoneStripTracksVerticalOffsetOnLeftEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let islandHeight = PanelLayoutMetrics.panelHeight(serviceCount: serviceCount)

        for offset: CGFloat in [-300, 0, 150, 10_000, -10_000] {
            let docked = frame(screen: screen, position: .center, edge: .left, verticalOffset: offset)
            let strip = HotZoneGeometry.rect(
                screenFrame: screen,
                panelHeight: islandHeight,
                width: 3,
                edge: .left,
                verticalPosition: .center,
                verticalOffset: offset
            )
            XCTAssertEqual(strip.minX, docked.minX, accuracy: 0.001, "offset \(offset): strip and panel share the left edge")
            XCTAssertEqual(strip.midY, docked.midY, accuracy: 0.001, "offset \(offset): strip must sit over the shifted island")
        }
    }

    // MARK: - Drag-to-reposition (ТЗ §6, Grammarly-style island drag):
    // `PanelLayoutMetrics.verticalOffset(forDockedFrameOriginY:)`, the pure
    // "window position after a drag → AppSettings.verticalOffset" math
    // `PanelWindow.endDrag` uses.

    /// Round-trips with `dockedOriginY` whenever the recovered offset
    /// wouldn't itself be clamped — i.e. dragging the island to wherever
    /// `dockedFrame(verticalOffset: X)` already puts it must recover exactly
    /// `X` back out. Offsets here are kept well under `verticalEdgeMargin`
    /// (24pt) in magnitude so the `.top`/`.bottom` anchors — which only have
    /// that much unclamped headroom on their edge-facing side — aren't
    /// themselves clamped by `dockedOriginY` first (that clamped case is
    /// covered separately by `testVerticalOffsetForDockedFrameOriginYIsNotClampedItself`).
    func testVerticalOffsetForDockedFrameOriginYRoundTripsWithDockedOriginY() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        for position in PanelVerticalPosition.allCases {
            for offset: CGFloat in [-20, -10, -1, 0, 1, 5, 20] {
                let originY = PanelLayoutMetrics.dockedOriginY(
                    screenFrame: screen,
                    serviceCount: serviceCount,
                    verticalPosition: position,
                    verticalOffset: offset
                )
                let recovered = PanelLayoutMetrics.verticalOffset(
                    forDockedFrameOriginY: originY,
                    screenFrame: screen,
                    serviceCount: serviceCount,
                    verticalPosition: position
                )
                XCTAssertEqual(recovered, offset, accuracy: 0.001, "\(position) offset \(offset)")
            }
        }
    }

    /// Round trip also holds on a non-origin, negative-origin screen — same
    /// "don't assume (0,0)" regression the rest of this file guards against.
    func testVerticalOffsetForDockedFrameOriginYRoundTripsOnOffsetScreen() {
        let screen = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
        let originY = PanelLayoutMetrics.dockedOriginY(
            screenFrame: screen,
            serviceCount: serviceCount,
            verticalPosition: .top,
            verticalOffset: -75
        )
        let recovered = PanelLayoutMetrics.verticalOffset(
            forDockedFrameOriginY: originY,
            screenFrame: screen,
            serviceCount: serviceCount,
            verticalPosition: .top
        )
        XCTAssertEqual(recovered, -75, accuracy: 0.001)
    }

    /// A drag released past where the island could physically reach (screen
    /// edge) recovers a raw offset *beyond* what `dockedOriginY` would ever
    /// produce unclamped — by design (no clamp lives in this function
    /// itself); feeding that raw offset back through the normal
    /// `AppSettings.verticalOffset` → `dockedFrame` path is what snaps the
    /// visible island back on-screen, exactly like a slider value typed past
    /// `AppSettings.verticalOffsetRange` already does.
    func testVerticalOffsetForDockedFrameOriginYIsNotClampedItself() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // A container origin far above the screen — further than the island
        // could ever actually be dragged to and stay visible.
        let wayOffscreenOriginY = screen.maxY + 5_000

        let recovered = PanelLayoutMetrics.verticalOffset(
            forDockedFrameOriginY: wayOffscreenOriginY,
            screenFrame: screen,
            serviceCount: serviceCount,
            verticalPosition: .center
        )
        XCTAssertGreaterThan(recovered, 5_000, "the raw recovered offset must not be pre-clamped")

        // Feeding it back through the normal (clamped) path snaps the
        // island back to the top edge, same guarantee `testVerticalOffsetClampsAtScreenEdges` covers for the slider.
        let islandHeight = PanelLayoutMetrics.panelHeight(serviceCount: serviceCount)
        let maxIslandCenterY = screen.maxY - islandHeight / 2
        let reclamped = frame(screen: screen, position: .center, verticalOffset: recovered)
        XCTAssertEqual(islandCenterY(in: reclamped), maxIslandCenterY, accuracy: 0.001)
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

    /// The slide-in/out animation must not visibly jump vertically once
    /// `verticalOffset` is in play — same regression as the zero-offset case
    /// above, just with a shift applied to both ends.
    func testOffscreenFrameTracksVerticalOffset() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let docked = frame(screen: screen, verticalOffset: 90)
        let hidden = PanelLayoutMetrics.offscreenFrame(
            screenFrame: screen,
            serviceCount: serviceCount,
            verticalPosition: .center,
            verticalOffset: 90
        )
        XCTAssertEqual(hidden.origin.y, docked.origin.y, accuracy: 0.001)
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

    /// Same agreement, mirrored for `.left` — the invisible hot-zone strip
    /// must hug `screen.minX` exactly like the docked panel does, on a
    /// second-display-style screen with a non-zero origin.
    func testHotZoneStripSharesTheDockedEdgeAndVerticalBandOnLeftEdge() {
        let screen = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let islandHeight = PanelLayoutMetrics.panelHeight(serviceCount: serviceCount)

        for position in PanelVerticalPosition.allCases {
            let docked = frame(screen: screen, position: position, edge: .left)
            let strip = HotZoneGeometry.rect(
                screenFrame: screen,
                panelHeight: islandHeight,
                width: 3,
                edge: .left,
                verticalPosition: position
            )
            XCTAssertEqual(strip.minX, docked.minX, accuracy: 0.001, "\(position): strip and panel share the edge")
            XCTAssertEqual(strip.minX, screen.minX, accuracy: 0.001, "\(position): strip hugs the physical screen edge")
            XCTAssertEqual(strip.midY, docked.midY, accuracy: 0.001, "\(position): strip sits over the island")
        }
    }
}
