import SwiftUI

/// One donut-ring progress indicator for a single service: ring + service
/// logo in the center, session-usage percentage printed underneath
/// (ТЗ §3.3; design-spec.md §3.2–§3.5).
///
/// Geometry mirrors the HTML prototype 1:1: 38×38 frame, r=16.6/stroke 2.8
/// progress ring around a r=13.5 `#2c2c2e` center disc. Ring color reflects
/// usage level (green/yellow/red via `UsageLevel`, gray when there is no
/// number to show); an error additionally shows the yellow "!" badge, loading
/// shows a spinning partial arc instead of the progress fill. A `.stale` ring
/// keeps its last known fill and percent, dimmed — see `RingPresentation`,
/// which owns every one of those decisions. Hover tracking that drives
/// `DetailCardView` is owned by the parent `PanelView`.
struct RingView: View {
    let serviceID: ServiceID
    let status: ServiceStatus
    var thresholds: UsageThresholds = .default
    /// `PanelModel.timedOutServiceIDs.contains(serviceID)` — only affects the
    /// accessibility label's wording (see `UsageErrorCopy`).
    var timedOut: Bool = false
    /// ТЗ §6 "показывать проценты под кольцами" — when `false`, the percent
    /// label under the ring is omitted entirely (not just dimmed).
    var showPercent: Bool = true
    /// `PanelModel.refreshingServiceIDs.contains(serviceID)`, threaded in by
    /// `PanelView` — plays the same spinning-arc cue as `.loading`, layered
    /// on top of whatever the ring is already showing (including a `.stale`
    /// ring's last-good percent/color), so a manual refresh or the launch-
    /// time re-check of a disk-cache-seeded snapshot is visibly happening
    /// without ever hiding data (ТЗ §4.3 live-feedback fix).
    var isRefreshing: Bool = false

    /// design-spec.md §3.2: SVG viewBox 0 0 38 38, ring r=16.6.
    private let frameSize: CGFloat = 38
    private let ringDiameter: CGFloat = 16.6 * 2
    private let centerDiameter: CGFloat = 13.5 * 2
    private let ringLineWidth: CGFloat = 2.8

    @State private var spinnerRotation = false

    /// Every "what should this ring show" decision lives in the pure,
    /// unit-tested `RingPresentation`; this view only turns it into pixels.
    private var presentation: RingPresentation {
        RingPresentation.make(status: status, isRefreshing: isRefreshing)
    }

    /// design-spec.md §6.4: the colored stroke collapses to 0 fill when there
    /// is no number behind it (loading / no data at all), leaving only the
    /// faint base ring. A `.stale` ring keeps its last known fill.
    private var fraction: Double { presentation.fillFraction }

    private var ringColor: Color {
        let presentation = presentation
        if presentation.usesNeutralColor { return ManaColor.unavailable }
        let base = UsageLevel.forPercent(presentation.percent, thresholds: thresholds).color
        // `.stale`: same level color, dimmed — the number is real but no
        // longer live, and flattening it to gray threw away information the
        // panel actually had (the detail card kept showing it).
        return presentation.isMuted ? base.opacity(ManaColor.staleFillOpacity) : base
    }

    private var glyphColor: Color {
        presentation.isMuted ? ManaColor.glyphDimmed : ManaColor.textPrimary
    }

    private var percentColor: Color {
        presentation.isMuted ? ManaColor.percentDimmed : ManaColor.textPrimary
    }

    /// design-spec.md §3.4: "21%" / "···" (loading) / "—" (no data).
    private var percentLabel: String { presentation.label }

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

                if presentation.showsSpinner {
                    // design-spec.md §6.5: dasharray "24 81" ≈ 22.9% of the
                    // circumference visible, spinning 360° every 0.9s linear.
                    // Also played (unlike the dash-offset collapse above,
                    // which stays gated on "is there a number at all") while
                    // `isRefreshing` — over a `.stale` ring's real percent/
                    // color, not just the plain `.loading` gray one.
                    Circle()
                        .trim(from: 0, to: 24.0 / (24.0 + 81.0))
                        .stroke(ManaColor.spinnerStroke, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                        .frame(width: ringDiameter, height: ringDiameter)
                        .rotationEffect(.degrees(spinnerRotation ? 360 : 0))
                        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinnerRotation)
                        .onAppear { spinnerRotation = true }
                }

                // design-spec.md §3.3: 17×17 glyph container, scale 0.62.
                ServiceLogo(serviceID: serviceID, size: 17)
                    .foregroundStyle(glyphColor)
            }
            .frame(width: frameSize, height: frameSize)
            .overlay(alignment: .bottomTrailing) {
                if presentation.showsErrorBadge {
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
        .accessibilityLabel(accessibilityLabel)
    }

    /// `.stale` announces both halves ("73% used, <error>") now that the ring
    /// visibly shows both; `.unavailable` announces only the error, `.loading`
    /// only "loading".
    private var accessibilityLabel: String {
        var parts = [serviceID.displayName]
        if case .loading = status {
            parts.append("loading")
        } else {
            if status.usage != nil {
                parts.append("\(Int(presentation.percent.rounded()))% used")
            }
            if let error = status.error {
                parts.append(UsageErrorCopy.text(for: error, timedOut: timedOut))
            }
        }
        return parts.joined(separator: " ")
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
        RingView(serviceID: .chatgpt, status: .stale(.placeholder, .connectionFailed), isRefreshing: true)
    }
    .padding()
    .background(Color.black)
}
