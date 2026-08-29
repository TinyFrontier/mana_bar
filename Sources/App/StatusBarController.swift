import AppKit

/// Owns the menu-bar (status) item and its dropdown menu.
///
/// Per docs/ТЗ-Mana.md section 7, Mana has no Dock icon; the status bar item
/// is the only always-visible system-integration surface, exposing:
/// Open Settings, Show/Hide Panel, Refresh Now, Pause, Quit. "Show/Hide
/// Panel" is wired to `PanelWindow.show`/`.hide` via the `togglePanel`
/// closure (ТЗ §11: manual fallback when Accessibility permission isn't
/// granted and the hot-zone mouse monitor can't run). "Refresh Now" and
/// "Pause" delegate to `AppDelegate`'s `UsageCoordinator` via their own
/// closures; this type only owns the menu item itself, including flipping
/// its title between "Pause"/"Resume" (ТЗ §7).
final class StatusBarController {
    private let statusItem: NSStatusItem

    /// Opens the Settings window (own `NSWindow`, not the SwiftUI `Settings`
    /// scene — see `SettingsWindowController` for why).
    private let openSettings: () -> Void
    /// Manual show/hide fallback (ТЗ §11): invoked by the "Show/Hide Panel"
    /// menu item, independent of the Accessibility-gated hot-zone monitor.
    private let togglePanel: () -> Void
    /// Interactive refresh of every service (ТЗ §4.3) — the one path allowed
    /// to raise a Keychain "allow access" dialog.
    private let refreshNow: () -> Void
    /// Pause/resume background polling and the hot-zone auto-show (ТЗ §7).
    /// Receives the *new* paused state after the toggle.
    private let togglePause: (Bool) -> Void
    /// Reopens the onboarding screen (ТЗ §7: "открывается также из
    /// меню-бара") — Accessibility status + token-source status, no manual
    /// token entry.
    private let showOnboarding: () -> Void

    private var isPaused = false

    private enum MenuItemTag: Int {
        case openSettings = 1
        case togglePanel = 2
        case refreshNow = 3
        case pause = 4
        case quit = 5
        case onboarding = 6
    }

    init(
        openSettings: @escaping () -> Void = {},
        togglePanel: @escaping () -> Void = {},
        refreshNow: @escaping () -> Void = {},
        togglePause: @escaping (Bool) -> Void = { _ in },
        showOnboarding: @escaping () -> Void = {}
    ) {
        self.openSettings = openSettings
        self.togglePanel = togglePanel
        self.refreshNow = refreshNow
        self.togglePause = togglePause
        self.showOnboarding = showOnboarding
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureButton()
        configureMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // TODO: replace with a custom mana-drop glyph asset.
        button.image = NSImage(
            systemSymbolName: "drop.fill",
            accessibilityDescription: "Mana"
        )
    }

    private func configureMenu() {
        let menu = NSMenu()

        let openSettingsItem = NSMenuItem(
            title: "Open Settings",
            action: #selector(openSettingsAction(_:)),
            keyEquivalent: ","
        )
        openSettingsItem.tag = MenuItemTag.openSettings.rawValue
        openSettingsItem.target = self
        menu.addItem(openSettingsItem)

        // ТЗ §11 fallback: works whether or not Accessibility permission is
        // granted, since it doesn't depend on the hot-zone mouse monitor.
        let showHidePanel = NSMenuItem(
            title: "Show/Hide Panel",
            action: #selector(toggleShowHidePanel(_:)),
            keyEquivalent: "p"
        )
        showHidePanel.tag = MenuItemTag.togglePanel.rawValue
        showHidePanel.target = self
        menu.addItem(showHidePanel)

        let refreshNow = NSMenuItem(
            title: "Refresh Now",
            action: #selector(refreshNowAction(_:)),
            keyEquivalent: "r"
        )
        refreshNow.tag = MenuItemTag.refreshNow.rawValue
        refreshNow.target = self
        menu.addItem(refreshNow)

        let pause = NSMenuItem(
            title: "Pause",
            action: #selector(togglePauseAction(_:)),
            keyEquivalent: ""
        )
        pause.tag = MenuItemTag.pause.rawValue
        pause.target = self
        menu.addItem(pause)

        let onboarding = NSMenuItem(
            title: "Setup & Permissions…",
            action: #selector(showOnboardingAction(_:)),
            keyEquivalent: ""
        )
        onboarding.tag = MenuItemTag.onboarding.rawValue
        onboarding.target = self
        menu.addItem(onboarding)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Mana",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.tag = MenuItemTag.quit.rawValue
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func openSettingsAction(_ sender: Any?) {
        openSettings()
    }

    @objc private func toggleShowHidePanel(_ sender: Any?) {
        togglePanel()
    }

    @objc private func refreshNowAction(_ sender: Any?) {
        refreshNow()
    }

    @objc private func showOnboardingAction(_ sender: Any?) {
        showOnboarding()
    }

    @objc private func togglePauseAction(_ sender: Any?) {
        isPaused.toggle()
        updatePauseMenuItemTitle()
        togglePause(isPaused)
    }

    private func updatePauseMenuItemTitle() {
        guard let item = statusItem.menu?.item(withTag: MenuItemTag.pause.rawValue) else { return }
        item.title = isPaused ? "Resume" : "Pause"
    }
}
