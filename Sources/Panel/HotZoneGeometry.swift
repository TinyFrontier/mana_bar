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
    ///   - verticalPosition: vertical placement along the edge (ТЗ §6) —
    ///     must match `PanelWindow`'s own placement, or the invisible strip
    ///     and the visible panel drift apart.
    ///   - margin: gap from the screen's top/bottom edge for the
    ///     `.top`/`.bottom` cases; ignored for `.center`.
    ///   - verticalOffset: same user-configured shift `PanelLayoutMetrics
    ///     .dockedOriginY` applies to the visible island
    ///     (`AppSettings.verticalOffset`) — must be threaded through here too
    ///     or the invisible hot-zone strip drifts away from the panel it's
    ///     supposed to sit under. Clamped identically (island/strip never
    ///     slides past the screen's top/bottom edge).
    static func rect(
        screenFrame: CGRect,
        panelHeight: CGFloat,
        width: CGFloat = 3,
        edge: PanelEdge = .right,
        verticalPosition: PanelVerticalPosition = .center,
        margin: CGFloat = PanelLayoutMetrics.verticalEdgeMargin,
        verticalOffset: CGFloat = 0
    ) -> CGRect {
        let x: CGFloat
        switch edge {
        case .right: x = screenFrame.maxX - width
        case .left: x = screenFrame.minX
        }
        let anchorCenterY: CGFloat
        switch verticalPosition {
        case .center: anchorCenterY = screenFrame.midY
        case .top: anchorCenterY = screenFrame.maxY - margin - panelHeight / 2
        case .bottom: anchorCenterY = screenFrame.minY + margin + panelHeight / 2
        }
        let minCenterY = screenFrame.minY + panelHeight / 2
        let maxCenterY = screenFrame.maxY - panelHeight / 2
        let candidate = anchorCenterY + verticalOffset
        let centerY = minCenterY <= maxCenterY ? min(max(candidate, minCenterY), maxCenterY) : candidate
        return CGRect(x: x, y: centerY - panelHeight / 2, width: width, height: panelHeight)
    }

    /// O(1) point-in-rect hit test.
    static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        rect.contains(point)
    }
}
