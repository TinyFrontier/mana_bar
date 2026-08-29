import CoreGraphics

/// Shared layout constants from design-spec.md §3.1, §3.6, §5, used by both
/// `PanelView` (SwiftUI layout) and `PanelWindow` (AppKit window sizing /
/// positioning) so the two stay in sync without duplicating magic numbers.
enum PanelLayoutMetrics {
    static let panelWidth: CGFloat = 62
    static let panelCornerRadius: CGFloat = 22
    static let panelVerticalPadding: CGFloat = 14
    static let ringSize: CGFloat = 38
    static let ringGap: CGFloat = 14

    /// Gap from the screen's top/bottom edge for `PanelVerticalPosition
    /// .top`/`.bottom` (ТЗ §6) — shared by `PanelWindow` and
    /// `HotZoneGeometry` so the visible island and the invisible hot-zone
    /// strip always agree on where "top"/"bottom" actually is.
    static let verticalEdgeMargin: CGFloat = 24

    static let cardWidth: CGFloat = 300
    /// Panel-left-edge-to-card-right-edge gap (74 = 62 panel + 12 arrow gap,
    /// design-spec.md §5.2).
    static let cardGap: CGFloat = 12
    /// Generous upper bound on card height (header + 2 rows + exhausted
    /// message) — sizes the hosting container only, never drawn itself.
    static let cardMaxHeight: CGFloat = 260

    /// Compact-panel content height for a given service count
    /// (design-spec.md §3.1: 2×14 padding + N×38 rings + (N-1)×14 gaps).
    static func panelHeight(serviceCount: Int) -> CGFloat {
        guard serviceCount > 0 else { return panelVerticalPadding * 2 }
        return panelVerticalPadding * 2
            + CGFloat(serviceCount) * ringSize
            + CGFloat(serviceCount - 1) * ringGap
    }

    /// Vertical offset of ring `index` (0-based, top to bottom) from the
    /// panel's own vertical center — aligns the flyout card with the
    /// hovered ring (design-spec.md §5.2: "top: [centerY]; translateY(-50%)").
    static func ringCenterOffset(index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        let step = ringSize + ringGap
        let middle = CGFloat(count - 1) / 2
        return (CGFloat(index) - middle) * step
    }

    /// Width of the container that must host both the island and the card
    /// flyout (panel + gap + card + a little bleed for shadow/arrow).
    static func containerWidth() -> CGFloat {
        panelWidth + cardGap + cardWidth + 24
    }

    /// Height of the container that must host both the island (vertically
    /// centered) and the card flyout wherever a hovered ring places it.
    static func containerHeight(serviceCount: Int) -> CGFloat {
        let panel = panelHeight(serviceCount: serviceCount)
        let maxRingOffset = serviceCount > 0
            ? ringCenterOffset(index: serviceCount - 1, count: serviceCount)
            : 0
        let neededForCard = cardMaxHeight + 2 * maxRingOffset
        return max(panel, neededForCard) + 40
    }

    static func containerSize(serviceCount: Int) -> CGSize {
        CGSize(width: containerWidth(), height: containerHeight(serviceCount: serviceCount))
    }

    // MARK: - Window frame math (pure; used by `PanelWindow`)

    /// Vertical origin of the *container* frame for a given vertical
    /// placement (ТЗ §6).
    ///
    /// The container is much taller than the visible island (extra space is
    /// reserved for the detail-card flyout, see `containerHeight`) and
    /// `PanelView` always centers the island vertically inside it — so
    /// `.top`/`.bottom` describe where the **island** should sit, and the
    /// container origin is backed out from that.
    static func dockedOriginY(
        screenFrame: CGRect,
        serviceCount: Int,
        verticalPosition: PanelVerticalPosition,
        margin: CGFloat = verticalEdgeMargin
    ) -> CGFloat {
        let containerHeight = containerHeight(serviceCount: serviceCount)
        let islandHeight = panelHeight(serviceCount: serviceCount)
        switch verticalPosition {
        case .center:
            return screenFrame.midY - containerHeight / 2
        case .top:
            let islandCenterY = screenFrame.maxY - margin - islandHeight / 2
            return islandCenterY - containerHeight / 2
        case .bottom:
            let islandCenterY = screenFrame.minY + margin + islandHeight / 2
            return islandCenterY - containerHeight / 2
        }
    }

    /// Docked (fully visible) window frame, flush against the chosen screen
    /// edge (ТЗ §3.2 — "панель прижата к краю").
    ///
    /// Deliberately keyed off the screen's **full** `frame`, never
    /// `visibleFrame`: the menu bar / Dock insets that `visibleFrame` carves
    /// out would push the island away from the physical edge and reintroduce
    /// the gap this function exists to prevent.
    ///
    /// `PanelView` pins the island to the container's **trailing** edge, so
    /// with `edge == .right` the island's right edge lands exactly on
    /// `screenFrame.maxX`.
    static func dockedFrame(
        screenFrame: CGRect,
        serviceCount: Int,
        verticalPosition: PanelVerticalPosition,
        edge: PanelEdge = .right,
        margin: CGFloat = verticalEdgeMargin
    ) -> CGRect {
        let size = containerSize(serviceCount: serviceCount)
        let x: CGFloat
        switch edge {
        case .right: x = screenFrame.maxX - size.width
        case .left: x = screenFrame.minX
        }
        return CGRect(
            origin: CGPoint(
                x: x,
                y: dockedOriginY(
                    screenFrame: screenFrame,
                    serviceCount: serviceCount,
                    verticalPosition: verticalPosition,
                    margin: margin
                )
            ),
            size: size
        )
    }

    /// Off-screen frame the panel slides in from / out to: the whole
    /// container parked just past the chosen edge, same vertical placement as
    /// `dockedFrame`.
    static func offscreenFrame(
        screenFrame: CGRect,
        serviceCount: Int,
        verticalPosition: PanelVerticalPosition,
        edge: PanelEdge = .right,
        margin: CGFloat = verticalEdgeMargin
    ) -> CGRect {
        var frame = dockedFrame(
            screenFrame: screenFrame,
            serviceCount: serviceCount,
            verticalPosition: verticalPosition,
            edge: edge,
            margin: margin
        )
        switch edge {
        case .right: frame.origin.x = screenFrame.maxX
        case .left: frame.origin.x = screenFrame.minX - frame.width
        }
        return frame
    }
}
