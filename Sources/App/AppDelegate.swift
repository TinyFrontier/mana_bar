import AppKit

/// Application lifecycle owner.
///
/// Wires together the pieces that make Mana an accessory app: the status bar
/// item/menu, the hot-zone panel, the hot-zone mouse monitor (ТЗ §7), and the
/// `UsageCoordinator` that polls the real `UsageProvider`s and feeds results
/// into `panelModel` (ТЗ §4.3). `PanelModel.mock` stays available for SwiftUI
/// previews; the running app uses a live model with empty initial statuses
/// (naturally `.loading` per `PanelModel.status(for:)`) until the
/// coordinator's first fetch completes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var panelWindow: PanelWindow?
    private var hotZoneMonitor: HotZoneMonitor?
    private var usageCoordinator: UsageCoordinator?

    private let panelModel = PanelModel(serviceOrder: Array(ServiceID.allCases), statuses: [:])

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon, no automatic main window.
        NSApp.setActivationPolicy(.accessory)

        let panelWindow = PanelWindow(model: panelModel)
        self.panelWindow = panelWindow

        let hotZoneMonitor = HotZoneMonitor()
        hotZoneMonitor.panelHeight = PanelLayoutMetrics.panelHeight(serviceCount: panelModel.serviceOrder.count)
        hotZoneMonitor.panelHitTestFrame = { [weak panelWindow] in panelWindow?.hitTestFrame }
        hotZoneMonitor.onEnterHotZone = { [weak self, weak panelWindow] in
            guard let self, let panelWindow, let screen = self.currentScreen() else { return }
            // Pause (ТЗ §7) also suppresses the hot-zone auto-show; the
            // menu-bar "Show/Hide Panel" fallback still works while paused.
            guard self.usageCoordinator?.isPaused != true else { return }
            self.showPanelAndRefreshIfStale(panelWindow, on: screen)
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

        let coordinator = Self.makeUsageCoordinator(model: panelModel)
        usageCoordinator = coordinator
        coordinator.start()

        statusBarController = StatusBarController(
            togglePanel: { [weak self] in self?.toggleManualPanel() },
            refreshNow: { [weak self] in
                Task { await self?.usageCoordinator?.refreshNow() }
            },
            togglePause: { [weak self] paused in
                guard let self else { return }
                if paused {
                    self.usageCoordinator?.pause()
                } else {
                    self.usageCoordinator?.resume()
                }
            }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // TODO: onboarding screen prompting for the permission (ТЗ §7).
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotZoneMonitor?.stop()
        usageCoordinator?.stop()
    }

    /// Builds the two providers (Claude, ChatGPT), each with a silent
    /// instance for background/automatic polls and an interactive one used
    /// only by the "Refresh Now" menu action (ТЗ §4.2: background polls must
    /// never raise a Keychain dialog). ChatGPT's `CodexAuthStore` has no such
    /// interactive/silent distinction, so both sides share one instance.
    private static func makeUsageCoordinator(model: PanelModel) -> UsageCoordinator {
        let claudeSilentAuth = ClaudeAuthStore(allowsKeychainInteraction: false)
        let claudeInteractiveAuth = ClaudeAuthStore(allowsKeychainInteraction: true)
        let providers: [ServiceID: UsageCoordinator.ProviderPair] = [
            .claude: UsageCoordinator.ProviderPair(
                silent: ClaudeProvider(authStore: claudeSilentAuth),
                interactive: ClaudeProvider(authStore: claudeInteractiveAuth)
            ),
            .chatgpt: UsageCoordinator.ProviderPair(ChatGPTProvider()),
        ]
        return UsageCoordinator(model: model, providers: providers)
    }

    /// Menu-bar fallback toggle (ТЗ §11): works with or without Accessibility
    /// permission, since it doesn't depend on the global mouse monitor.
    private func toggleManualPanel() {
        guard let panelWindow, let screen = currentScreen() else { return }
        if panelWindow.isShown {
            panelWindow.hide()
        } else {
            showPanelAndRefreshIfStale(panelWindow, on: screen)
        }
    }

    /// Shows the panel immediately (never blocked on the network) and, in the
    /// background, force-refreshes any service whose data is stale or
    /// missing (ТЗ §4.3) — the panel's `@Published` statuses update it
    /// reactively once a fetch completes.
    private func showPanelAndRefreshIfStale(_ panelWindow: PanelWindow, on screen: NSScreen) {
        panelWindow.show(on: screen)
        Task { [weak self] in
            await self?.usageCoordinator?.forceRefreshIfStale()
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
