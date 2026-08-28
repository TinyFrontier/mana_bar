import CoreGraphics

/// Pure geometry for the invisible hot-zone strip at the screen edge
/// (ТЗ §3.1, §8): a `hotZoneWidth`-wide strip, `panelHeight` tall, centered
/// vertically on the screen, hugging the chosen edge. Kept free of
/// AppKit/NSScreen so it's directly unit-testable; `HotZoneMonitor` supplies
/// the live `NSScreen.frame`.
///
/// `contains` is an O(1) rect hit test (ТЗ §8: no polling loop, O(1) hit
/// test) — used on every `mouseMoved` event.
enum HotZoneGeometry {
    /// Computes the hot-zone rect in screen coordinates.
    /// - Parameters:
    ///   - screenFrame: the target screen's full frame (`NSScreen.frame`).
    ///   - panelHeight: current panel content height (varies with service count).
    ///   - width: hot-zone strip width, 2–4px per ТЗ §3.1 (default 3).
    ///   - edge: which screen edge the panel docks to (ТЗ §6, `PanelEdge`).
    static func rect(screenFrame: CGRect, panelHeight: CGFloat, width: CGFloat = 3, edge: PanelEdge = .right) -> CGRect {
        let x: CGFloat
        switch edge {
        case .right: x = screenFrame.maxX - width
        case .left: x = screenFrame.minX
        }
        let y = screenFrame.midY - panelHeight / 2
        return CGRect(x: x, y: y, width: width, height: panelHeight)
    }

    /// O(1) point-in-rect hit test.
    static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        rect.contains(point)
    }
}
