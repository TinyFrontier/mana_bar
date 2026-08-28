import CoreGraphics
import Foundation

/// Screen edge the panel docks to (ТЗ §6).
enum PanelEdge: String, Codable, CaseIterable {
    case right
    case left
}

/// Vertical placement of the panel along the chosen edge (ТЗ §6).
enum PanelVerticalPosition: String, Codable, CaseIterable {
    case top
    case center
    case bottom
    // TODO: free-offset variant per ТЗ §6 ("свободное смещение").
}

/// Background-poll interval options (ТЗ §4.3).
enum RefreshInterval: Int, Codable, CaseIterable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
}

/// All user-configurable behavior from the Settings window (ТЗ §6), backed
/// by `UserDefaults` (non-secret) — tokens themselves live in
/// `KeychainStore`, never here. Setup-phase stub: properties and defaults
/// only, no persistence wiring or SMAppService login-item call yet.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // Services: enabled state + order. TODO: back with a per-service struct
    // (enabled, sortIndex) once provider wiring lands.
    @Published var enabledServiceIDs: Set<ServiceID> = Set(ServiceID.allCases)

    @Published var panelEdge: PanelEdge = .right
    @Published var verticalPosition: PanelVerticalPosition = .center
    @Published var preferredScreenID: CGDirectDisplayID? // nil = screen with cursor

    @Published var refreshInterval: RefreshInterval = .twoMinutes

    // Ring color thresholds, 0...1 (ТЗ §3.3).
    @Published var warningThreshold: Double = 0.5
    @Published var criticalThreshold: Double = 0.8

    // Notification thresholds, 0...1, separate for session/weekly (ТЗ §5).
    @Published var sessionNotificationThresholds: [Double] = [0.8, 0.95]
    @Published var weeklyNotificationThresholds: [Double] = [0.8, 0.95]

    // Panel show/hide delays, milliseconds (ТЗ §3.2, §3.5).
    @Published var appearDelayMs: Int = 120
    @Published var disappearDelayMs: Int = 350

    @Published var launchAtLogin: Bool = false
    @Published var showPercentUnderRings: Bool = true
    @Published var hidePanelOverFullScreen: Bool = false

    private init() {
        // TODO: load persisted values from UserDefaults.
    }

    /// Persists current settings.
    func save() {
        // TODO: write to UserDefaults.
    }

    /// Applies `launchAtLogin` via SMAppService (ТЗ §6).
    func updateLoginItem() {
        // TODO: SMAppService.mainApp.register() / .unregister()
    }
}
