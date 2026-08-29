import SwiftUI

/// SwiftUI Settings window content, opened from the status bar menu
/// (ТЗ §6, §7). Covers: service list (enable/order/auth status), panel edge +
/// vertical position, monitor selection (simplified — see below), refresh
/// interval, color/notification thresholds, show/hide delays, launch at
/// login, percent-label toggle, and a link back into onboarding.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showOnboardingAgain = false

    var body: some View {
        Form {
            servicesSection
            panelSection
            updatesSection
            colorThresholdsSection
            notificationThresholdsSection
            delaysSection
            startupSection
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .frame(width: 460, height: 620)
        .sheet(isPresented: $showOnboardingAgain) {
            OnboardingView(onDone: { showOnboardingAgain = false })
        }
    }

    // MARK: - Services (ТЗ §6: "список сервисов: вкл/выкл, порядок, статус источника токена")

    private var servicesSection: some View {
        Section("Services") {
            ForEach(Array(settings.serviceOrder.enumerated()), id: \.element) { index, id in
                ServiceRow(
                    serviceID: id,
                    isEnabled: Binding(
                        get: { settings.enabledServiceIDs.contains(id) },
                        set: { newValue in
                            if newValue {
                                settings.enabledServiceIDs.insert(id)
                            } else {
                                settings.enabledServiceIDs.remove(id)
                            }
                        }
                    ),
                    canMoveUp: index > 0,
                    canMoveDown: index < settings.serviceOrder.count - 1,
                    moveUp: { settings.moveService(id, by: -1) },
                    moveDown: { settings.moveService(id, by: 1) }
                )
            }
        }
    }

    // MARK: - Panel placement (ТЗ §6)

    private var panelSection: some View {
        Section("Panel") {
            // `PanelWindow.dockEdge` and `PanelView`'s layout (island
            // alignment, card offset direction, rounded corners, arrow side)
            // both read `AppSettings.shared.panelEdge` live, so flipping this
            // picker mirrors the whole panel — including while it's
            // currently visible — via the existing `$panelEdge` subscription
            // in `AppDelegate.observeSettings()` (ТЗ §6).
            Picker("Edge", selection: $settings.panelEdge) {
                Text("Right").tag(PanelEdge.right)
                Text("Left").tag(PanelEdge.left)
            }

            Picker("Vertical position", selection: $settings.verticalPosition) {
                Text("Top").tag(PanelVerticalPosition.top)
                Text("Center").tag(PanelVerticalPosition.center)
                Text("Bottom").tag(PanelVerticalPosition.bottom)
            }

            verticalOffsetControl

            LabeledContent("Monitor") {
                Text("Screen with cursor")
                    .foregroundStyle(.secondary)
            }
            // TODO (ТЗ §6): explicit monitor picker for multi-monitor setups.
            // `AppSettings.preferredScreenID` already exists for this; only
            // the UI + `AppDelegate.currentScreen()` wiring are pending —
            // simplified to the spec's own default ("screen with cursor")
            // for this wave.

            Toggle("Show percent under rings", isOn: $settings.showPercentUnderRings)
            Toggle("Hide over full-screen apps", isOn: $settings.hidePanelOverFullScreen)
        }
    }

    /// Free vertical shift on top of the center/top/bottom anchor (ТЗ §6
    /// "свободное смещение") — e.g. "panel higher than dead-center".
    /// `PanelLayoutMetrics` clamps the effective position at the screen
    /// edges, so dragging to an extreme value here is harmless; it just
    /// stops moving the panel once the island reaches the edge.
    private var verticalOffsetControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Vertical offset")
                Spacer()
                Text("\(Int(settings.verticalOffset.rounded())) pt")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Reset") { settings.verticalOffset = 0 }
                    .buttonStyle(.borderless)
                    .disabled(settings.verticalOffset == 0)
            }
            Slider(
                value: $settings.verticalOffset,
                in: AppSettings.verticalOffsetRange,
                step: 5
            )
        }
    }

    // MARK: - Updates (ТЗ §4.3, §6)

    private var updatesSection: some View {
        Section("Updates") {
            Picker("Refresh interval", selection: $settings.refreshInterval) {
                Text("1 min").tag(RefreshInterval.oneMinute)
                Text("2 min").tag(RefreshInterval.twoMinutes)
                Text("5 min").tag(RefreshInterval.fiveMinutes)
            }
        }
    }

    // MARK: - Ring color thresholds (ТЗ §3.3, §6)

    private var colorThresholdsSection: some View {
        Section("Ring colors") {
            Stepper(
                "Warning at \(Int(settings.warningThreshold * 100))%",
                value: $settings.warningThreshold,
                in: 0.05...0.95,
                step: 0.05
            )
            Stepper(
                "Critical at \(Int(settings.criticalThreshold * 100))%",
                value: $settings.criticalThreshold,
                in: 0.05...1.0,
                step: 0.05
            )
        }
    }

    // MARK: - Notification thresholds (ТЗ §5, §6)

    private var notificationThresholdsSection: some View {
        Section("Notifications") {
            Text("Session")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(
                "First alert at \(percentText(sessionThreshold(0)))%",
                value: thresholdBinding(\.sessionNotificationThresholds, index: 0, fallback: 0.8),
                in: 0.05...1.0,
                step: 0.05
            )
            Stepper(
                "Second alert at \(percentText(sessionThreshold(1)))%",
                value: thresholdBinding(\.sessionNotificationThresholds, index: 1, fallback: 0.95),
                in: 0.05...1.0,
                step: 0.05
            )

            Text("Weekly")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(
                "First alert at \(percentText(weeklyThreshold(0)))%",
                value: thresholdBinding(\.weeklyNotificationThresholds, index: 0, fallback: 0.8),
                in: 0.05...1.0,
                step: 0.05
            )
            Stepper(
                "Second alert at \(percentText(weeklyThreshold(1)))%",
                value: thresholdBinding(\.weeklyNotificationThresholds, index: 1, fallback: 0.95),
                in: 0.05...1.0,
                step: 0.05
            )
        }
    }

    private func sessionThreshold(_ index: Int) -> Double {
        settings.sessionNotificationThresholds.indices.contains(index) ? settings.sessionNotificationThresholds[index] : 0
    }

    private func weeklyThreshold(_ index: Int) -> Double {
        settings.weeklyNotificationThresholds.indices.contains(index) ? settings.weeklyNotificationThresholds[index] : 0
    }

    private func percentText(_ fraction: Double) -> String {
        String(Int((fraction * 100).rounded()))
    }

    /// Binds one element of a threshold array on `AppSettings`, growing the
    /// array (padded with `fallback`) if the index isn't populated yet —
    /// keeps the two Steppers per window simple without assuming the array
    /// always has exactly 2 elements.
    private func thresholdBinding(
        _ keyPath: ReferenceWritableKeyPath<AppSettings, [Double]>,
        index: Int,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                let array = settings[keyPath: keyPath]
                return array.indices.contains(index) ? array[index] : fallback
            },
            set: { newValue in
                var array = settings[keyPath: keyPath]
                while array.count <= index { array.append(fallback) }
                array[index] = newValue
                settings[keyPath: keyPath] = array
            }
        )
    }

    // MARK: - Show/hide delays (ТЗ §3.2, §3.5, §6)

    private var delaysSection: some View {
        Section("Delays") {
            Stepper(
                "Appear after \(settings.appearDelayMs) ms",
                value: $settings.appearDelayMs,
                in: 0...1000,
                step: 10
            )
            Stepper(
                "Hide after \(settings.disappearDelayMs) ms",
                value: $settings.disappearDelayMs,
                in: 0...2000,
                step: 10
            )
        }
    }

    // MARK: - Startup (ТЗ §6, §7)

    private var startupSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .onChange(of: settings.launchAtLogin) { _ in
                    settings.updateLoginItem()
                }

            Button("Setup & Permissions…") {
                showOnboardingAgain = true
            }
        }
    }
}

/// One row in the "Services" section: enable toggle, name, up/down reorder
/// buttons, and the token-source status this service currently has
/// (ТЗ §6: "статус источника токена (найден/не найден... кнопка «Обновить»)").
private struct ServiceRow: View {
    let serviceID: ServiceID
    @Binding var isEnabled: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    @State private var finding: CredentialSourceStatus.Finding?

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isEnabled) {
                Text(serviceID.displayName)
            }
            .toggleStyle(.checkbox)

            Spacer()

            statusText

            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Recheck token source")

            VStack(spacing: 2) {
                Button(action: moveUp) { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveUp)
                Button(action: moveDown) { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveDown)
            }
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private var statusText: some View {
        switch finding {
        case .found:
            Text("Found").font(.caption).foregroundStyle(.green)
        case .needsKeychainPermission:
            // ТЗ §7 addendum: distinct from "Found" — the login exists but
            // won't actually work until a one-time Keychain grant happens.
            Text("Needs permission").font(.caption).foregroundStyle(.orange)
        case .notFound:
            Text("Not found").font(.caption).foregroundStyle(.secondary)
        case .none:
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        finding = await CredentialSourceStatus.status(serviceID)
    }
}

#Preview {
    SettingsView()
}
