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

    var body: some View {
        ZStack(alignment: .trailing) {
            if let hoveredServiceID = cardHover.displayedServiceID, let index = services.firstIndex(of: hoveredServiceID) {
                DetailCardView(
                    serviceID: hoveredServiceID,
                    status: model.status(for: hoveredServiceID),
                    thresholds: thresholds,
                    onErrorAction: { model.requestManualRefresh() }
                )
                    .offset(
                        x: -(PanelLayoutMetrics.panelWidth + PanelLayoutMetrics.cardGap),
                        y: PanelLayoutMetrics.ringCenterOffset(index: index, count: services.count)
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: -30)),
                        removal: .opacity.combined(with: .offset(x: -30))
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
        // `alignment: .trailing` is load-bearing, not cosmetic: the ZStack
        // only ever measures as wide as its widest child (62pt island alone,
        // 300pt once the card is present — `.offset` doesn't affect layout),
        // so the default `.center` alignment floated the island ~168pt away
        // from the container's trailing edge and, through it, from the screen
        // edge the window is docked to. Pinning trailing is what makes
        // "window right edge == screen.frame.maxX" also mean "island is flush
        // with the screen edge" (ТЗ §3.2).
        .frame(
            width: PanelLayoutMetrics.containerWidth(),
            height: PanelLayoutMetrics.containerHeight(serviceCount: services.count),
            alignment: .trailing
        )
        // design-spec.md §6.3: card fade+slide, 150ms ease-out.
        .animation(.easeOut(duration: 0.15), value: cardHover.displayedServiceID)
    }

    private var island: some View {
        VStack(spacing: PanelLayoutMetrics.ringGap) {
            ForEach(services) { serviceID in
                RingView(serviceID: serviceID, status: model.status(for: serviceID), thresholds: thresholds, showPercent: settings.showPercentUnderRings)
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
            LeftRoundedRectangle(radius: PanelLayoutMetrics.panelCornerRadius)
                .fill(ManaColor.panelBackground)
        )
        // design-spec.md §3.1: box-shadow -18px 0 48px rgba(0,0,0,0.45).
        .shadow(color: ManaColor.panelShadow, radius: 24, x: -10, y: 0)
    }
}

/// Rectangle rounded on its left (leading) corners only, right corners
/// square (design-spec.md §3.1: `border-radius: 22px 0 0 22px`). Stand-in
/// for `UnevenRoundedRectangle` (macOS 14+) since Mana targets 13.0.
private struct LeftRoundedRectangle: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
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
