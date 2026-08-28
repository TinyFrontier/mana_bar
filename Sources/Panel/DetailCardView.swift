import SwiftUI

/// Flyout detail card shown to the left of the panel island when a ring is
/// hovered (ТЗ §3.4): service name/logo, "Current session" progress row
/// with reset time, and "All models" (weekly) progress row with reset time.
///
/// Setup-phase skeleton: static layout with placeholder rows, no
/// fade+slide animation wiring yet (owned by `PanelView` hover state in the
/// implementation phase).
struct DetailCardView: View {
    let usage: ServiceUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                // TODO: real per-service logo asset.
                Image(systemName: "circle.fill")
                Text(usage.serviceID.displayName)
                    .font(.headline)
            }

            detailRow(
                title: "Current session",
                percent: usage.sessionPercent,
                resetText: usage.sessionResetDescription
            )

            detailRow(
                title: "All models",
                percent: usage.weeklyPercent,
                resetText: usage.weeklyResetDescription
            )

            if case .error(let message) = usage.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)

                // TODO: wire to the provider's re-auth flow.
                Button("Re-login") {}
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 220, alignment: .leading)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func detailRow(title: String, percent: Double, resetText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: percent)
            HStack {
                Text("\(Int(percent * 100))%")
                Spacer()
                Text(resetText)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    DetailCardView(usage: .placeholder)
        .padding()
        .background(Color.gray)
}
