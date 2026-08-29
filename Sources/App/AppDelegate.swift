import AppKit
import Combine
import SwiftUI

/// Application lifecycle owner.
///
/// Wires together the pieces that make Mana an accessory app: the status bar
/// item/menu, the hot-zone panel, the hot-zone mouse monitor (ТЗ §7), the
/// `UsageCoordinator` that polls the real `UsageProvider`s and feeds results
/// into `panelModel` (ТЗ §4.3), `NotificationManager` (ТЗ §5), and the
/// onboarding window (ТЗ §7). It also keeps every live-tunable `AppSettings`
/// value (ТЗ §6) pushed into whichever component owns the corresponding
/// behavior — `observeSettings()` is the one place that fan-out lives.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var panelWindow: PanelWindow?
    private var hotZoneMonitor: HotZoneMonitor?
    private var usageCoordinator: UsageCoordinator?
    private var onboardingWindow: NSWindow?
    private var settingsSubscriptions: Set<AnyCancellable> = []
    private let accessibilityMonitor = AccessibilityPermissionMonitor.shared

    private let panelModel = PanelModel(serviceOrder: AppSettings.shared.effectiveServiceOrder, statuses: [:])

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon, no automatic main window.
        NSApp.setActivationPolicy(.accessory)

        let panelWindow = PanelWindow(model: panelModel)
        self.panelWindow = panelWindow

        let hotZoneMonitor = HotZoneMonitor()
        hotZoneMonitor.panelHeight = PanelLayoutMetrics.panelHeight(serviceCount: panelModel.serviceOrder.count)
        hotZoneMonitor.edge = AppSettings.shared.panelEdge
        hotZoneMonitor.verticalPosition = AppSettings.shared.verticalPosition
        hotZoneMonitor.verticalOffset = CGFloat(AppSettings.shared.verticalOffset)
        hotZoneMonitor.appearDelay = TimeInterval(AppSettings.shared.appearDelayMs) / 1000
        hotZoneMonitor.disappearDelay = TimeInterval(AppSettings.shared.disappearDelayMs) / 1000
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

        // ТЗ §7/§11: arm hover tracking now, and keep watching the
        // Accessibility grant so a permission granted *while the app is
        // running* re-arms it without a restart (see
        // `observeAccessibilityPermission`). The menu-bar "Show/Hide Panel"
        // item (wired below) stays the fallback either way.
        startHotZoneMonitorIfPossible()
        observeAccessibilityPermission()

        let coordinator = Self.makeUsageCoordinator(model: panelModel)
        usageCoordinator = coordinator
        coordinator.start()

        // Wires the detail card's error-state action button (DetailCardView)
        // to the same interactive "Refresh Now" path as the status-bar menu
        // item, without PanelModel needing any knowledge of the coordinator.
        panelModel.onManualRefreshRequested = { [weak self] in
            Task { await self?.usageCoordinator?.refreshNow() }
        }

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
            },
            showOnboarding: { [weak self] in self?.showOnboardingWindow() }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // ТЗ §5: ask once; UNUserNotificationCenter itself won't re-prompt
        // the user on later launches.
        Task { await NotificationManager.shared.requestAuthorizationIfNeeded() }

        observeSettings()

        // ТЗ §7: first-run onboarding — Accessibility explanation + token-
        // source status. Also reachable any time from the status-bar menu.
        if !AppSettings.shared.hasCompletedOnboarding {
            showOnboardingWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotZoneMonitor?.stop()
        accessibilityMonitor.stopPolling()
        usageCoordinator?.stop()
    }

    /// Coming back from System Settings reactivates Mana — a free, exact
    /// moment to re-read the grant instead of waiting out the poll interval.
    func applicationDidBecomeActive(_ notification: Notification) {
        accessibilityMonitor.recheck()
    }

    // MARK: - Accessibility permission (ТЗ §7, §11)

    /// Installs the hot-zone mouse monitor, and leaves
    /// `AccessibilityPermissionMonitor` polling only while something is still
    /// missing.
    ///
    /// Mouse-move events don't strictly require the Accessibility grant (only
    /// key events do — see `HotZoneMonitor`), so this normally succeeds on the
    /// first try; the poll exists for the case where it doesn't, and to keep
    /// the onboarding's status row live.
    @discardableResult
    private func startHotZoneMonitorIfPossible() -> Bool {
        guard let hotZoneMonitor else { return false }
        let started = hotZoneMonitor.start()
        if started && accessibilityMonitor.isTrusted {
            accessibilityMonitor.stopPolling()
        } else {
            accessibilityMonitor.startPollingIfNeeded()
        }
        return started
    }

    /// macOS posts no notification when the Accessibility switch is flipped,
    /// so `AccessibilityPermissionMonitor` polls for it; this is the other
    /// half — the moment the grant appears, the hot-zone monitor is (re)armed
    /// in place. No restart, no "quit and reopen Mana" instruction.
    private func observeAccessibilityPermission() {
        accessibilityMonitor.$isTrusted
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] trusted in
                guard let self, trusted else { return }
                guard self.hotZoneMonitor?.isRunning != true else {
                    // Already tracking; just refresh the reported status.
                    _ = self.hotZoneMonitor?.start()
                    return
                }
                self.startHotZoneMonitorIfPossible()
            }
            .store(in: &settingsSubscriptions)
    }

    /// Builds the two providers (Claude, ChatGPT), each with a silent
    /// instance for background/automatic polls and an interactive one used
    /// only by the "Refresh Now" menu action (ТЗ §4.2: background polls must
    /// never raise a Keychain dialog). Both `ClaudeAuthStore` and
    /// `CodexAuthStore` support this split via `allowsKeychainInteraction`.
    private static func makeUsageCoordinator(model: PanelModel) -> UsageCoordinator {
        let claudeSilentAuth = ClaudeAuthStore(allowsKeychainInteraction: false)
        let claudeInteractiveAuth = ClaudeAuthStore(allowsKeychainInteraction: true)
        let codexSilentAuth = CodexAuthStore(allowsKeychainInteraction: false)
        let codexInteractiveAuth = CodexAuthStore(allowsKeychainInteraction: true)
        let providers: [ServiceID: UsageCoordinator.ProviderPair] = [
            .claude: UsageCoordinator.ProviderPair(
                silent: ClaudeProvider(authStore: claudeSilentAuth),
                interactive: ClaudeProvider(authStore: claudeInteractiveAuth)
            ),
            .chatgpt: UsageCoordinator.ProviderPair(
                silent: ChatGPTProvider(authStore: codexSilentAuth),
                interactive: ChatGPTProvider(authStore: codexInteractiveAuth)
            ),
        ]
        return UsageCoordinator(
            model: model,
            providers: providers,
            // ТЗ §5: clean integration point — every successful fetch's
            // fresh snapshot is evaluated for threshold crossings.
            onUsageUpdated: { usage in NotificationManager.shared.evaluate(usage) }
        )
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
    /// (ТЗ §6: "по умолчанию — экран с курсором"). TODO: honor
    /// `AppSettings.preferredScreenID` once Settings grows an explicit
    /// monitor picker — simplified to the cursor-screen default for now.
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

    // MARK: - Live settings wiring (ТЗ §6)

    /// Subscribes to every `AppSettings` field that some other component
    /// needs pushed into it explicitly (as opposed to `PanelView`/
    /// `RingView`/`DetailCardView`, which observe `AppSettings.shared`
    /// directly since they're already SwiftUI). Kept in one place so the
    /// fan-out from "a setting changed" to "who needs to know" is easy to
    /// audit.
    private func observeSettings() {
        let settings = AppSettings.shared

        settings.$refreshInterval
            .dropFirst()
            .sink { [weak self] interval in
                self?.usageCoordinator?.updateRefreshInterval(TimeInterval(interval.rawValue))
            }
            .store(in: &settingsSubscriptions)

        settings.$appearDelayMs
            .dropFirst()
            .sink { [weak self] ms in
                self?.hotZoneMonitor?.appearDelay = TimeInterval(ms) / 1000
            }
            .store(in: &settingsSubscriptions)

        settings.$disappearDelayMs
            .dropFirst()
            .sink { [weak self] ms in
                self?.hotZoneMonitor?.disappearDelay = TimeInterval(ms) / 1000
            }
            .store(in: &settingsSubscriptions)

        settings.$panelEdge
            .dropFirst()
            .sink { [weak self] edge in
                self?.hotZoneMonitor?.edge = edge
                self?.repositionPanelOnNextRunLoopTurn()
            }
            .store(in: &settingsSubscriptions)

        settings.$verticalPosition
            .dropFirst()
            .sink { [weak self] verticalPosition in
                self?.hotZoneMonitor?.verticalPosition = verticalPosition
                self?.repositionPanelOnNextRunLoopTurn()
            }
            .store(in: &settingsSubscriptions)

        settings.$verticalOffset
            .dropFirst()
            .sink { [weak self] offset in
                self?.hotZoneMonitor?.verticalOffset = CGFloat(offset)
                self?.repositionPanelOnNextRunLoopTurn()
            }
            .store(in: &settingsSubscriptions)

        Publishers.CombineLatest(settings.$serviceOrder, settings.$enabledServiceIDs)
            .dropFirst()
            .sink { [weak self] order, enabled in
                guard let self else { return }
                let effective = order.filter { enabled.contains($0) }
                self.panelModel.updateServiceOrder(effective)
                self.hotZoneMonitor?.panelHeight = PanelLayoutMetrics.panelHeight(serviceCount: effective.count)
            }
            .store(in: &settingsSubscriptions)
    }

    private func repositionPanel() {
        guard let panelWindow, let screen = currentScreen() else { return }
        panelWindow.reposition(on: screen)
    }

    /// Bugfix (live feedback: dragging the Settings "Vertical offset" slider
    /// didn't visibly move the panel): `@Published`'s projected publisher
    /// (`settings.$verticalOffset` etc.) fires from `willSet` — i.e.
    /// *before* the property's own stored value has actually been updated —
    /// so a `.sink` closure that reacts by calling `repositionPanel()`
    /// synchronously was reading `AppSettings.shared.verticalOffset` (inside
    /// `PanelWindow.shownFrame`/`.hiddenFrame`) one step stale, computing the
    /// frame for whatever the offset *used to be*, not the value that just
    /// got set. Every earlier `.sink` in this file sidesteps the same trap by
    /// using the emitted parameter directly instead of re-reading
    /// `AppSettings.shared`; `repositionPanel()` can't do that (it re-derives
    /// the whole frame from several settings at once, not just the one that
    /// changed), so instead this defers the actual reposition to the next
    /// run-loop turn — by then `AppSettings.shared`'s stored value has
    /// settled to the new one. The one-tick delay is imperceptible (well
    /// under a frame at 60Hz) and keeps every setting driving
    /// `repositionPanel()` correct without duplicating per-property state.
    private func repositionPanelOnNextRunLoopTurn() {
        DispatchQueue.main.async { [weak self] in
            self?.repositionPanel()
        }
    }

    // MARK: - Onboarding (ТЗ §7)

    /// Shows the onboarding window, creating it once and reusing it after
    /// (reachable both on first launch and from the status-bar menu).
    private func showOnboardingWindow() {
        // Whatever the window shows must be current the instant it appears,
        // not whatever was true when the app launched.
        accessibilityMonitor.recheck()
        accessibilityMonitor.startPollingIfNeeded()

        if let onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Mana"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView(onDone: { [weak window] in
            window?.close()
        }))
        onboardingWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
