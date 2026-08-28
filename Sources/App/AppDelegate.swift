import AppKit

/// Application lifecycle owner.
///
/// Wires together the pieces that make Mana an accessory app: the status bar
/// item/menu, the hot-zone panel, and (eventually) the Accessibility-permission
/// onboarding flow described in docs/ТЗ-Mana.md section 7. Real wiring
/// (hot-zone monitor start, usage providers, notification manager) is added
/// in the implementation phase — this is the skeleton entry point only.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    // TODO: private var panelWindow: PanelWindow?
    // TODO: private var hotZoneMonitor: HotZoneMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon, no automatic main window.
        NSApp.setActivationPolicy(.accessory)

        statusBarController = StatusBarController()

        // TODO: instantiate PanelWindow + HotZoneMonitor and connect them.
        // TODO: request Accessibility permission / show onboarding if needed.
        // TODO: start UsageProvider polling via a coordinator.
    }

    func applicationWillTerminate(_ notification: Notification) {
        // TODO: tear down timers / monitors cleanly.
    }
}
