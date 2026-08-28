import SwiftUI

/// SwiftUI Settings window content, opened from the status bar menu
/// (ТЗ §6, §7). Covers: service list (enable/order/auth), panel edge +
/// vertical position, monitor selection, refresh interval, color/notification
/// thresholds, show/hide delays, launch at login, percent-label toggle.
///
/// Setup-phase skeleton: a minimal `Form` binding straight to `AppSettings`
/// so the window is functional; per-service auth UI, monitor picker, and
/// full-screen toggle are TODO for the implementation phase.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Panel") {
                Picker("Edge", selection: $settings.panelEdge) {
                    ForEach(PanelEdge.allCases, id: \.self) { edge in
                        Text(edge.rawValue.capitalized).tag(edge)
                    }
                }
                Picker("Vertical position", selection: $settings.verticalPosition) {
                    ForEach(PanelVerticalPosition.allCases, id: \.self) { position in
                        Text(position.rawValue.capitalized).tag(position)
                    }
                }
                // TODO: monitor picker (ТЗ §6 "выбор монитора").
                Toggle("Show percent under rings", isOn: $settings.showPercentUnderRings)
                Toggle("Hide over full screen apps", isOn: $settings.hidePanelOverFullScreen)
            }

            Section("Updates") {
                Picker("Refresh interval", selection: $settings.refreshInterval) {
                    Text("1 min").tag(RefreshInterval.oneMinute)
                    Text("2 min").tag(RefreshInterval.twoMinutes)
                    Text("5 min").tag(RefreshInterval.fiveMinutes)
                }
            }

            Section("Thresholds") {
                // TODO: real slider/stepper controls once thresholds drive live UI.
                Stepper(
                    "Warning ring at \(Int(settings.warningThreshold * 100))%",
                    value: $settings.warningThreshold,
                    in: 0...1,
                    step: 0.05
                )
                Stepper(
                    "Critical ring at \(Int(settings.criticalThreshold * 100))%",
                    value: $settings.criticalThreshold,
                    in: 0...1,
                    step: 0.05
                )
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _ in
                        settings.updateLoginItem()
                    }
            }

            // TODO: per-service enable/order/auth list (ТЗ §6, §4.2).
        }
        .padding(20)
        .frame(width: 420)
    }
}

#Preview {
    SettingsView()
}
