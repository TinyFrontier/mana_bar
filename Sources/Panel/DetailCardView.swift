import SwiftUI

/// Flyout detail card shown to the left of the panel island when a ring is
/// hovered (ТЗ §3.4): service name/logo, "Current session" progress row
/// with reset time, and "All models" (weekly) progress row with reset time.
///
/// Setup-phase skeleton: static layout with placeholder rows, no
/// fade+slide animation wiring yet (owned by `PanelView` hover state in the
/// implementation phase).
struct DetailCardView: View {
    let serviceID: ServiceID
    let status: ServiceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                // TODO: real per-service logo asset.
                Image(systemName: "circle.fill")
                Text(serviceID.displayName)
                    .font(.headline)
            }

            detailRow(title: "Current session", window: status.usage?.sessionWindow)
            detailRow(title: "All models", window: status.usage?.weeklyWindow)

            if let error = status.error {
                Text(error.userDescription)
                    .font(.caption)
                    .foregroundStyle(.red)

                // TODO: wire to the "re-login via CLI" hint flow (ТЗ §4.3).
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
    private func detailRow(title: String, window: UsageWindow?) -> some View {
        let fraction = window.map { min(max($0.usedPercent / 100, 0), 1) }
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: fraction ?? 0)
            HStack {
                Text(fraction.map { "\(Int($0 * 100))%" } ?? "—")
                Spacer()
                // TODO: real relative/absolute formatting per ТЗ §3.4
                // ("Resets in 51 min", "Resets Thu 12:00 AM"); nil resetsAt
                // means "Not started", not 0% (research doc §9.2 п.5).
                Text(window?.resetsAt.map { "Resets " + $0.formatted(date: .omitted, time: .shortened) } ?? "Not started")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    DetailCardView(serviceID: .claude, status: .ready(.placeholder))
        .padding()
        .background(Color.gray)
}
