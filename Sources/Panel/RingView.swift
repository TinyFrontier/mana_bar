import SwiftUI

/// One donut-ring progress indicator for a single service: ring + service
/// logo in the center, session-usage percentage printed underneath (ТЗ §3.3).
///
/// Ring color reflects usage level (green <50%, yellow/orange 50–80%,
/// red >80%, thresholds configurable via AppSettings — ТЗ §3.3), and turns
/// gray with a warning glyph on provider error (ТЗ §4.3). Hovering a ring
/// is what triggers `DetailCardView` (ТЗ §3.4) — hover tracking is TODO,
/// owned by the parent `PanelView` in the implementation phase.
struct RingView: View {
    let serviceID: ServiceID
    let status: ServiceStatus

    private var sessionFraction: Double {
        status.usage?.sessionFraction ?? 0
    }

    private var ringColor: Color {
        if status.error != nil { return .gray }
        // TODO: read configurable thresholds from AppSettings instead
        // of the hardcoded 0.5 / 0.8 split below (ТЗ §3.3, §6).
        switch sessionFraction {
        case ..<0.5: return .green
        case ..<0.8: return .yellow
        default: return .red
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: sessionFraction)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                // TODO: replace with the real per-service logo asset.
                Image(systemName: status.error != nil ? "exclamationmark.triangle" : "circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            Text(status.usage == nil ? "—" : "\(Int(sessionFraction * 100))%")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    RingView(serviceID: .claude, status: .ready(.placeholder))
        .padding()
        .background(Color.black)
}
