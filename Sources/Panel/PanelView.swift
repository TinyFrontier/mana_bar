import SwiftUI

/// Root SwiftUI content of the hot-zone panel: the black rounded "island"
/// with one `RingView` per enabled service (ТЗ §3.3), plus the
/// `DetailCardView` flyout for whichever ring is currently hovered (ТЗ §3.4).
///
/// Setup-phase skeleton: static placeholder layout only, no live data,
/// hover-tracking, or provider wiring yet.
struct PanelView: View {
    // TODO: @StateObject / @EnvironmentObject usage state (list of ServiceUsage).
    // TODO: @State hoveredServiceID for DetailCardView flyout.

    var body: some View {
        VStack(spacing: 16) {
            // TODO: ForEach over enabled services with live ServiceStatus.
            RingView(serviceID: .claude, status: .ready(.placeholder))
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
        .frame(width: 96)
        .background(
            LeftRoundedRectangle(radius: 26)
                .fill(Color.black)
        )
    }
}

/// Rectangle rounded on its left (leading) corners only, right corners square.
/// Stand-in for `UnevenRoundedRectangle` (macOS 14+) since Mana targets 13.0.
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
    PanelView()
}
