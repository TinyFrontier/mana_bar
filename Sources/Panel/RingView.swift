import SwiftUI

/// One donut-ring progress indicator for a single service: ring + service
/// logo in the center, session-usage percentage printed underneath
/// (ТЗ §3.3; design-spec.md §3.2–§3.5).
///
/// Geometry mirrors the HTML prototype 1:1: 38×38 frame, r=16.6/stroke 2.8
/// progress ring around a r=13.5 `#2c2c2e` center disc. Ring color reflects
/// usage level (green/yellow/red via `UsageLevel`, gray on error/loading);
/// error state additionally shows the yellow "!" badge, loading shows a
/// spinning partial arc instead of the progress fill. Hover tracking that
/// drives `DetailCardView` is owned by the parent `PanelView`.
struct RingView: View {
    let serviceID: ServiceID
    let status: ServiceStatus
    var thresholds: UsageThresholds = .default
    /// ТЗ §6 "показывать проценты под кольцами" — when `false`, the percent
    /// label under the ring is omitted entirely (not just dimmed).
    var showPercent: Bool = true

    /// design-spec.md §3.2: SVG viewBox 0 0 38 38, ring r=16.6.
    private let frameSize: CGFloat = 38
    private let ringDiameter: CGFloat = 16.6 * 2
    private let centerDiameter: CGFloat = 13.5 * 2
    private let ringLineWidth: CGFloat = 2.8

    @State private var spinnerRotation = false

    private var isLoading: Bool {
        if case .loading = status { return true }
        return false
    }

    private var isError: Bool { status.error != nil }

    private var sessionPercent: Double {
        status.usage?.sessionWindow?.usedPercent ?? 0
    }

    /// design-spec.md §6.4: dash offset collapses to 0 fill on error/loading
    /// (the colored stroke is fully hidden, leaving only the faint base ring).
    private var fraction: Double {
        guard !isError, !isLoading else { return 0 }
        return min(max(sessionPercent / 100, 0), 1)
    }

    private var ringColor: Color {
        if isError || isLoading { return ManaColor.unavailable }
        return UsageLevel.forPercent(sessionPercent, thresholds: thresholds).color
    }

    private var glyphColor: Color {
        (isError || isLoading) ? ManaColor.glyphDimmed : ManaColor.textPrimary
    }

    private var percentColor: Color {
        (isError || isLoading) ? ManaColor.percentDimmed : ManaColor.textPrimary
    }

    /// design-spec.md §3.4: "21%" / "···" (loading) / "—" (error).
    private var percentLabel: String {
        if isError { return "—" }
        if isLoading { return "···" }
        return "\(Int(sessionPercent.rounded()))%"
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(ManaColor.ringCenter)
                    .frame(width: centerDiameter, height: centerDiameter)

                Circle()
                    .stroke(ManaColor.ringBase, lineWidth: ringLineWidth)
                    .frame(width: ringDiameter, height: ringDiameter)

                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                    .frame(width: ringDiameter, height: ringDiameter)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.32), value: fraction)
                    .animation(.easeInOut(duration: 0.2), value: ringColor)

                if isLoading {
                    // design-spec.md §6.5: dasharray "24 81" ≈ 22.9% of the
                    // circumference visible, spinning 360° every 0.9s linear.
                    Circle()
                        .trim(from: 0, to: 24.0 / (24.0 + 81.0))
                        .stroke(ManaColor.spinnerStroke, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                        .frame(width: ringDiameter, height: ringDiameter)
                        .rotationEffect(.degrees(spinnerRotation ? 360 : 0))
                        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinnerRotation)
                        .onAppear { spinnerRotation = true }
                }

                // design-spec.md §3.3: 17×17 glyph container, scale 0.62.
                Image(systemName: serviceID.glyphSystemName)
                    .font(.system(size: 17 * 0.62, weight: .semibold))
                    .foregroundStyle(glyphColor)
                    .frame(width: 17, height: 17)
            }
            .frame(width: frameSize, height: frameSize)
            .overlay(alignment: .bottomTrailing) {
                if isError {
                    ErrorBadge().offset(x: 2, y: 2)
                }
            }

            if showPercent {
                Text(percentLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(-0.1)
                    .monospacedDigit()
                    .foregroundStyle(percentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(serviceID.displayName) \(isError ? status.error?.userDescription ?? "error" : isLoading ? "loading" : "\(Int(sessionPercent.rounded()))% used")")
    }
}

/// design-spec.md §3.5: 13×13 yellow badge, 1.5px black border, "!" glyph —
/// shown at the ring's bottom-trailing corner on error.
private struct ErrorBadge: View {
    private let size: CGFloat = 13

    var body: some View {
        ZStack {
            Circle().fill(ManaColor.errorBadgeBackground)
            Circle().strokeBorder(Color.black, lineWidth: 1.5)
            Text("!")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.black)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    HStack(spacing: 20) {
        RingView(serviceID: .claude, status: .ready(.placeholder))
        RingView(serviceID: .claude, status: .loading)
        RingView(serviceID: .claude, status: .unavailable(.connectionFailed))
    }
    .padding()
    .background(Color.black)
}
