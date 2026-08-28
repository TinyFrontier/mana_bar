import CoreGraphics
import Foundation
import ServiceManagement

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
/// `KeychainStore`, never here.
///
/// Every property auto-persists on change via a `didSet` → `saveIfNeeded()`
/// (suppressed while `load()` is populating initial values, so restoring a
/// saved value doesn't immediately re-write the exact same value back).
/// Tests must never touch `.shared` (which is backed by `UserDefaults
/// .standard`, i.e. this machine's real Mana preferences) — construct a
/// throwaway instance with a private `UserDefaults(suiteName:)` instead.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    /// Suppresses `saveIfNeeded()` while `load()` is assigning stored values
    /// back onto `@Published` properties, so restoring state doesn't cause a
    /// redundant (if harmless) write-back on every launch.
    private var isLoading = false

    // MARK: - Services: enabled state + display/poll order (ТЗ §6)

    /// Every known service, in display/poll order. Reordered by the Settings
    /// "move up/down" controls; `PanelModel.serviceOrder` and
    /// `UsageCoordinator` both ultimately follow `effectiveServiceOrder`
    /// (order ∩ enabled), pushed in by `AppDelegate`.
    @Published var serviceOrder: [ServiceID] { didSet { saveIfNeeded() } }
    @Published var enabledServiceIDs: Set<ServiceID> { didSet { saveIfNeeded() } }

    // MARK: - Panel placement (ТЗ §6)

    @Published var panelEdge: PanelEdge = .right { didSet { saveIfNeeded() } }
    @Published var verticalPosition: PanelVerticalPosition = .center { didSet { saveIfNeeded() } }
    /// nil = screen with cursor (ТЗ §6 default). TODO: explicit monitor
    /// picker for multi-monitor setups — simplified to the cursor-screen
    /// default for this wave; `AppDelegate.currentScreen()` doesn't consult
    /// this yet.
    @Published var preferredScreenID: CGDirectDisplayID? { didSet { saveIfNeeded() } }

    // MARK: - Updates (ТЗ §4.3, §6)

    @Published var refreshInterval: RefreshInterval = .twoMinutes { didSet { saveIfNeeded() } }

    // MARK: - Ring color thresholds, 0...1 (ТЗ §3.3, §6)

    @Published var warningThreshold: Double = 0.5 { didSet { saveIfNeeded() } }
    @Published var criticalThreshold: Double = 0.8 { didSet { saveIfNeeded() } }

    // MARK: - Notification thresholds, 0...1, separate for session/weekly (ТЗ §5, §6)

    @Published var sessionNotificationThresholds: [Double] = [0.8, 0.95] { didSet { saveIfNeeded() } }
    @Published var weeklyNotificationThresholds: [Double] = [0.8, 0.95] { didSet { saveIfNeeded() } }

    // MARK: - Panel show/hide delays, milliseconds (ТЗ §3.2, §3.5, §6)

    @Published var appearDelayMs: Int = 120 { didSet { saveIfNeeded() } }
    @Published var disappearDelayMs: Int = 350 { didSet { saveIfNeeded() } }

    // MARK: - Misc (ТЗ §6, §7)

    @Published var launchAtLogin: Bool = false { didSet { saveIfNeeded() } }
    @Published var showPercentUnderRings: Bool = true { didSet { saveIfNeeded() } }
    @Published var hidePanelOverFullScreen: Bool = false { didSet { saveIfNeeded() } }

    /// First-launch onboarding flag (ТЗ §7). `AppDelegate` shows the
    /// onboarding window automatically while this is `false`.
    @Published var hasCompletedOnboarding: Bool = false { didSet { saveIfNeeded() } }

    /// - Parameter defaults: the `UserDefaults` suite to persist into.
    ///   Defaults to `.standard` for real app use; tests must pass a private
    ///   suite (see type doc comment) so they never read/write this
    ///   machine's actual Mana preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serviceOrder = Array(ServiceID.allCases)
        self.enabledServiceIDs = Set(ServiceID.allCases)
        isLoading = true
        load()
        isLoading = false
    }

    private func saveIfNeeded() {
        guard !isLoading else { return }
        save()
    }

    /// Persists current settings.
    func save() {
        defaults.set(serviceOrder.map(\.rawValue), forKey: Keys.serviceOrder)
        defaults.set(enabledServiceIDs.map(\.rawValue), forKey: Keys.enabledServiceIDs)
        defaults.set(panelEdge.rawValue, forKey: Keys.panelEdge)
        defaults.set(verticalPosition.rawValue, forKey: Keys.verticalPosition)
        if let preferredScreenID {
            defaults.set(Int(preferredScreenID), forKey: Keys.preferredScreenID)
        } else {
            defaults.removeObject(forKey: Keys.preferredScreenID)
        }
        defaults.set(refreshInterval.rawValue, forKey: Keys.refreshInterval)
        defaults.set(warningThreshold, forKey: Keys.warningThreshold)
        defaults.set(criticalThreshold, forKey: Keys.criticalThreshold)
        defaults.set(sessionNotificationThresholds, forKey: Keys.sessionNotificationThresholds)
        defaults.set(weeklyNotificationThresholds, forKey: Keys.weeklyNotificationThresholds)
        defaults.set(appearDelayMs, forKey: Keys.appearDelayMs)
        defaults.set(disappearDelayMs, forKey: Keys.disappearDelayMs)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(showPercentUnderRings, forKey: Keys.showPercentUnderRings)
        defaults.set(hidePanelOverFullScreen, forKey: Keys.hidePanelOverFullScreen)
        defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding)
    }

    private func load() {
        if let raw = defaults.array(forKey: Keys.serviceOrder) as? [String] {
            let known = raw.compactMap(ServiceID.init(rawValue:))
            // A service this build doesn't know about (from an older/newer
            // list) is dropped; a known service missing from a stored
            // (older) list is appended so a newly added provider still shows.
            let missing = ServiceID.allCases.filter { !known.contains($0) }
            serviceOrder = known + missing
        }
        if let raw = defaults.array(forKey: Keys.enabledServiceIDs) as? [String] {
            enabledServiceIDs = Set(raw.compactMap(ServiceID.init(rawValue:)))
        }
        if let raw = defaults.string(forKey: Keys.panelEdge), let value = PanelEdge(rawValue: raw) {
            panelEdge = value
        }
        if let raw = defaults.string(forKey: Keys.verticalPosition), let value = PanelVerticalPosition(rawValue: raw) {
            verticalPosition = value
        }
        if defaults.object(forKey: Keys.preferredScreenID) != nil {
            preferredScreenID = CGDirectDisplayID(defaults.integer(forKey: Keys.preferredScreenID))
        }
        if defaults.object(forKey: Keys.refreshInterval) != nil {
            let raw = defaults.integer(forKey: Keys.refreshInterval)
            if let value = RefreshInterval(rawValue: raw) { refreshInterval = value }
        }
        if defaults.object(forKey: Keys.warningThreshold) != nil {
            warningThreshold = defaults.double(forKey: Keys.warningThreshold)
        }
        if defaults.object(forKey: Keys.criticalThreshold) != nil {
            criticalThreshold = defaults.double(forKey: Keys.criticalThreshold)
        }
        if let raw = defaults.array(forKey: Keys.sessionNotificationThresholds) as? [Double] {
            sessionNotificationThresholds = raw
        }
        if let raw = defaults.array(forKey: Keys.weeklyNotificationThresholds) as? [Double] {
            weeklyNotificationThresholds = raw
        }
        if defaults.object(forKey: Keys.appearDelayMs) != nil {
            appearDelayMs = defaults.integer(forKey: Keys.appearDelayMs)
        }
        if defaults.object(forKey: Keys.disappearDelayMs) != nil {
            disappearDelayMs = defaults.integer(forKey: Keys.disappearDelayMs)
        }
        if defaults.object(forKey: Keys.launchAtLogin) != nil {
            launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        }
        if defaults.object(forKey: Keys.showPercentUnderRings) != nil {
            showPercentUnderRings = defaults.bool(forKey: Keys.showPercentUnderRings)
        }
        if defaults.object(forKey: Keys.hidePanelOverFullScreen) != nil {
            hidePanelOverFullScreen = defaults.bool(forKey: Keys.hidePanelOverFullScreen)
        }
        if defaults.object(forKey: Keys.hasCompletedOnboarding) != nil {
            hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        }
    }

    private enum Keys {
        static let serviceOrder = "mana.settings.serviceOrder"
        static let enabledServiceIDs = "mana.settings.enabledServiceIDs"
        static let panelEdge = "mana.settings.panelEdge"
        static let verticalPosition = "mana.settings.verticalPosition"
        static let preferredScreenID = "mana.settings.preferredScreenID"
        static let refreshInterval = "mana.settings.refreshInterval"
        static let warningThreshold = "mana.settings.warningThreshold"
        static let criticalThreshold = "mana.settings.criticalThreshold"
        static let sessionNotificationThresholds = "mana.settings.sessionNotificationThresholds"
        static let weeklyNotificationThresholds = "mana.settings.weeklyNotificationThresholds"
        static let appearDelayMs = "mana.settings.appearDelayMs"
        static let disappearDelayMs = "mana.settings.disappearDelayMs"
        static let launchAtLogin = "mana.settings.launchAtLogin"
        static let showPercentUnderRings = "mana.settings.showPercentUnderRings"
        static let hidePanelOverFullScreen = "mana.settings.hidePanelOverFullScreen"
        static let hasCompletedOnboarding = "mana.settings.hasCompletedOnboarding"
    }

    // MARK: - Derived

    /// `serviceOrder` filtered down to only the enabled services — what
    /// `PanelModel`/`UsageCoordinator` should actually show/poll (ТЗ §6:
    /// "координатор не опрашивает выключенные").
    var effectiveServiceOrder: [ServiceID] {
        serviceOrder.filter { enabledServiceIDs.contains($0) }
    }

    /// Moves `id` `offset` places within `serviceOrder` (±1 for the
    /// Settings "move up"/"move down" buttons). No-op if the move would land
    /// outside the array.
    func moveService(_ id: ServiceID, by offset: Int) {
        guard let index = serviceOrder.firstIndex(of: id) else { return }
        let newIndex = index + offset
        guard serviceOrder.indices.contains(newIndex) else { return }
        serviceOrder.swapAt(index, newIndex)
    }

    /// Applies `launchAtLogin` via SMAppService (ТЗ §6). Errors are logged
    /// and otherwise swallowed: a login-item registration failure (sandbox
    /// quirks, running from a rejected location, etc.) must never crash the
    /// app or block the rest of Settings from working.
    func updateLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            #if DEBUG
            print("AppSettings.updateLoginItem failed: \(error)")
            #endif
        }
    }
}
