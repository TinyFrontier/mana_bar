import SwiftUI

/// Root SwiftUI content of the hot-zone panel: the black rounded "island"
/// with one `RingView` per enabled service (ТЗ §3.3), plus the
/// `DetailCardView` flyout for whichever ring is currently hovered
/// (ТЗ §3.4; design-spec.md §1.1–§1.2, §5.2).
///
/// The whole assembly (island + optional card) is laid out inside one fixed
/// container sized by `PanelLayoutMetrics`, right-aligned so the island
/// stays pinned to the container's trailing edge regardless of whether the
/// card is showing — `PanelWindow` then only has to slide this container's
/// window frame in/out of the screen edge (ТЗ §3.2, §3.5), it never needs to
/// know about card geometry itself.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    /// Live-observed so a Settings change (thresholds, percent-label
    /// toggle) is reflected the moment the panel is next shown, with no
    /// extra wiring beyond this (ТЗ §6).
    @ObservedObject private var settings = AppSettings.shared
    /// Owns which ring's `DetailCardView` (if any) should be visible —
    /// including the ring→gap→card grace period that keeps the card open
    /// long enough to actually reach it (see type doc comment).
    @StateObject private var cardHover = CardHoverCoordinator()

    /// - Parameter initiallyHovered: seeds the hover state so a specific
    ///   ring's `DetailCardView` starts open — useful for Previews/snapshots;
    ///   real usage (`PanelWindow`) always starts with no ring hovered.
    init(model: PanelModel, initiallyHovered: ServiceID? = nil) {
        self.model = model
        let coordinator = CardHoverCoordinator()
        if let initiallyHovered {
            coordinator.ringEntered(initiallyHovered)
        }
        _cardHover = StateObject(wrappedValue: coordinator)
    }

    private var services: [ServiceID] { model.serviceOrder }

    private var thresholds: UsageThresholds {
        UsageThresholds(warning: settings.warningThreshold, critical: settings.criticalThreshold)
    }

    /// Which screen edge the panel currently docks to (ТЗ §6) — read live off
    /// `AppSettings.shared` (already `@ObservedObject` above) so flipping the
    /// Settings picker mirrors this whole view the moment the panel is next
    /// shown, same as the threshold/percent-label settings already do.
    private var edge: PanelEdge { settings.panelEdge }

    /// The ZStack only ever measures as wide as its widest child (island
    /// alone vs. island+card), so which edge it's pinned to is what makes
    /// "window edge == screen edge" also mean "island is flush with the
    /// screen edge" (ТЗ §3.2) — see the `.frame` comment below. `.right`
    /// docks the island to the container's trailing edge (card grows
    /// leading/left of it); `.left` mirrors that (island leading, card
    /// grows trailing/right of it).
    private var containerAlignment: Alignment { edge == .right ? .trailing : .leading }

    /// Card offset from the island: negative (left) for a right-edge dock,
    /// positive (right) for a left-edge dock — always on the side away from
    /// the physical screen edge, where there's room to draw it.
    private var cardOffsetX: CGFloat {
        let magnitude = PanelLayoutMetrics.panelWidth + PanelLayoutMetrics.cardGap
        return edge == .right ? -magnitude : magnitude
    }

    /// Card slide-transition distance — mirrors `cardOffsetX`'s sign so the
    /// card slides in/out from further away on whichever side it actually
    /// lives on.
    private var cardTransitionOffsetX: CGFloat { edge == .right ? -30 : 30 }

    /// Island drop-shadow horizontal offset (design-spec.md §3.1) — cast
    /// away from the physical screen edge, same side the card lives on.
    private var islandShadowOffsetX: CGFloat { edge == .right ? -6 : 6 }

    /// Which side of the island gets rounded corners (design-spec.md §3.1):
    /// always the side facing *into* the visible screen — the side flush
    /// against the physical edge stays square, matching a shape that visibly
    /// continues off-screen.
    private var islandRoundedSide: HorizontalEdge { edge == .right ? .leading : .trailing }

    var body: some View {
        ZStack(alignment: containerAlignment) {
            if let hoveredServiceID = cardHover.displayedServiceID, let index = services.firstIndex(of: hoveredServiceID) {
                DetailCardView(
                    serviceID: hoveredServiceID,
                    status: model.status(for: hoveredServiceID),
                    thresholds: thresholds,
                    edge: edge,
                    onErrorAction: { model.requestManualRefresh() },
                    isRefreshing: model.refreshingServiceIDs.contains(hoveredServiceID),
                    cooldownUntil: model.cooldownUntil[hoveredServiceID]
                )
                    .offset(
                        x: cardOffsetX,
                        y: PanelLayoutMetrics.ringCenterOffset(index: index, count: services.count)
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: cardTransitionOffsetX)),
                        removal: .opacity.combined(with: .offset(x: cardTransitionOffsetX))
                    ))
                    .id(hoveredServiceID)
                    // Load-bearing for the bugfix: without this, the card
                    // itself never registers as a hover source, so the
                    // coordinator's grace period would immediately expire the
                    // moment the cursor left the ring, even mid-crossing.
                    .onHover { isHovering in cardHover.card(isHovering: isHovering) }
            }

            island
        }
        // `alignment: containerAlignment` is load-bearing, not cosmetic: the
        // ZStack only ever measures as wide as its widest child (62pt island
        // alone, 300pt once the card is present — `.offset` doesn't affect
        // layout), so the default `.center` alignment floated the island
        // ~168pt away from the container's pinned edge and, through it, from
        // the screen edge the window is docked to. Pinning to the same edge
        // as `PanelWindow`'s dock is what makes "window edge == screen edge"
        // also mean "island is flush with the screen edge" (ТЗ §3.2), for
        // either `PanelEdge`.
        .frame(
            width: PanelLayoutMetrics.containerWidth(),
            height: PanelLayoutMetrics.containerHeight(serviceCount: services.count),
            alignment: containerAlignment
        )
        // design-spec.md §6.3: card fade+slide, 150ms ease-out.
        .animation(.easeOut(duration: 0.15), value: cardHover.displayedServiceID)
    }

    private var island: some View {
        VStack(spacing: PanelLayoutMetrics.ringGap) {
            ForEach(services) { serviceID in
                RingView(
                    serviceID: serviceID,
                    status: model.status(for: serviceID),
                    thresholds: thresholds,
                    showPercent: settings.showPercentUnderRings,
                    isRefreshing: model.refreshingServiceIDs.contains(serviceID)
                )
                    .onHover { isHovering in
                        if isHovering {
                            cardHover.ringEntered(serviceID)
                        } else {
                            cardHover.ringExited(serviceID)
                        }
                    }
            }
        }
        .padding(.vertical, PanelLayoutMetrics.panelVerticalPadding)
        .frame(width: PanelLayoutMetrics.panelWidth)
        .background(
            EdgeRoundedRectangle(radius: PanelLayoutMetrics.panelCornerRadius, roundedSide: islandRoundedSide)
                .fill(ManaColor.panelBackground)
        )
        // design-spec.md §3.1: box-shadow, tuned down from the design
        // spec's dark-background value — see ColorPalette.swift. Mirrored
        // per-edge via `islandShadowOffsetX` (ТЗ §6).
        .shadow(color: ManaColor.panelShadow, radius: 14, x: islandShadowOffsetX, y: 0)
        // ТЗ §6: drag the island vertically to reposition the panel
        // (Grammarly-style), same free offset the Settings slider controls.
        // `minimumDistance: 0` so every micro-movement from mouse-down
        // reaches `PanelWindow` (via `PanelModel.onDragChanged`) — the
        // window itself decides, in `PanelDragGesture`, whether enough
        // *vertical* distance has accumulated to actually start moving;
        // below that threshold this is a no-op and hovering a ring / a
        // detail-card button click behave exactly as before. Scoped to the
        // island only (not the whole ZStack), so the detail card's own
        // buttons are never in this gesture's hit-test region.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in model.onDragChanged?() }
                .onEnded { _ in model.onDragEnded?() }
        )
    }
}

/// Rectangle rounded on one horizontal side only, the other side square
/// (design-spec.md §3.1: `border-radius: 22px 0 0 22px`, mirrored for the
/// left-edge dock). Stand-in for `UnevenRoundedRectangle` (macOS 14+) since
/// Mana targets 13.0.
///
/// `roundedSide` is always the side facing *into* the visible screen — the
/// side flush against the physical screen edge stays square, as if the
/// island's shape continues off past the edge (ТЗ §6: mirrored for `.left`).
private struct EdgeRoundedRectangle: Shape {
    var radius: CGFloat
    var roundedSide: HorizontalEdge

    func path(in rect: CGRect) -> Path {
        let leftRounded = leftRoundedPath(in: rect)
        switch roundedSide {
        case .leading:
            return leftRounded
        case .trailing:
            // Mirrors the leading-rounded path across the rect's vertical
            // center line (x -> rect.minX + rect.maxX - x, y unchanged) —
            // avoids hand-deriving separate arc angles for the mirrored
            // corners, which is easy to get subtly wrong.
            let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0)
            return leftRounded.applying(transform)
        }
    }

    private func leftRoundedPath(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    PanelView(model: .mock, initiallyHovered: .claude)
        .background(Color(white: 0.2))
}
