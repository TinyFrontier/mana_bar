import AppKit

/// Application lifecycle owner.
///
/// Wires together the pieces that make Mana an accessory app: the status bar
/// item/menu, the hot-zone panel, and the hot-zone mouse monitor (ТЗ §7).
/// `PanelModel.mock` stands in for the real provider-polling coordinator
/// until the next wave wires up `UsageProvider` fetches — everything below
/// only depends on the frozen `ServiceStatus`/`ServiceUsage` contract, so
/// swapping the mock for live data later is additive here.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var panelWindow: PanelWindow?
    private var hotZoneMonitor: HotZoneMonitor?

    private let panelModel = PanelModel.mock

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon, no automatic main window.
        NSApp.setActivationPolicy(.accessory)

        let panelWindow = PanelWindow(model: panelModel)
        self.panelWindow = panelWindow

        let hotZoneMonitor = HotZoneMonitor()
        hotZoneMonitor.panelHeight = PanelLayoutMetrics.panelHeight(serviceCount: panelModel.serviceOrder.count)
        hotZoneMonitor.panelHitTestFrame = { [weak panelWindow] in panelWindow?.hitTestFrame }
        hotZoneMonitor.onEnterHotZone = { [weak self, weak panelWindow] in
            guard let panelWindow, let screen = self?.currentScreen() else { return }
            panelWindow.show(on: screen)
        }
        hotZoneMonitor.onLeaveHotZone = { [weak panelWindow] in
            panelWindow?.hide()
        }
        self.hotZoneMonitor = hotZoneMonitor

        // ТЗ §11 risk / §7 fallback: if Accessibility permission isn't
        // granted, `start()` installs nothing and returns false — global
        // hover tracking simply won't fire, and the menu-bar "Show/Hide
        // Panel" item (wired below) is the only way to reveal the panel.
        // TODO: onboarding screen prompting for the permission (ТЗ §7).
        _ = hotZoneMonitor.start()

        statusBarController = StatusBarController(togglePanel: { [weak self] in
            self?.toggleManualPanel()
        })

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // TODO: start UsageProvider polling via a coordinator and feed
        // results into `panelModel.setStatus(_:for:)` (ТЗ §4.3).
        // TODO: sleep/wake handling beyond screen-parameter changes (ТЗ §7)
        // — NSWorkspace.didWakeNotification to re-run reposition/timers.
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotZoneMonitor?.stop()
    }

    /// Menu-bar fallback toggle (ТЗ §11): works with or without Accessibility
    /// permission, since it doesn't depend on the global mouse monitor.
    private func toggleManualPanel() {
        guard let panelWindow, let screen = currentScreen() else { return }
        if panelWindow.isShown {
            panelWindow.hide()
        } else {
            panelWindow.show(on: screen)
        }
    }

    /// Screen containing the cursor, falling back to the main screen
    /// (ТЗ §6: "по умолчанию — экран с курсором").
    private func currentScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    /// ТЗ §7: re-run positioning when monitors are connected/disconnected or
    /// resolution changes. Multi-monitor/Spaces edge cases beyond "reposition
    /// on the screen with the cursor" are out of scope for this wave.
    @objc private func screenParametersDidChange() {
        guard let screen = currentScreen() else { return }
        panelWindow?.reposition(on: screen)
    }
}
