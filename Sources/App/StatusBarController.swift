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

    /// Manual show/hide fallback (ТЗ §11): invoked by the "Show/Hide Panel"
    /// menu item, independent of the Accessibility-gated hot-zone monitor.
    private let togglePanel: () -> Void
    /// Interactive refresh of every service (ТЗ §4.3) — the one path allowed
    /// to raise a Keychain "allow access" dialog.
    private let refreshNow: () -> Void
    /// Pause/resume background polling and the hot-zone auto-show (ТЗ §7).
    /// Receives the *new* paused state after the toggle.
    private let togglePause: (Bool) -> Void

    private var isPaused = false

    private enum MenuItemTag: Int {
        case openSettings = 1
        case togglePanel = 2
        case refreshNow = 3
        case pause = 4
        case quit = 5
    }

    init(
        togglePanel: @escaping () -> Void = {},
        refreshNow: @escaping () -> Void = {},
        togglePause: @escaping (Bool) -> Void = { _ in }
    ) {
        self.togglePanel = togglePanel
        self.refreshNow = refreshNow
        self.togglePause = togglePause
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

        let openSettings = NSMenuItem(
            title: "Open Settings",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        openSettings.tag = MenuItemTag.openSettings.rawValue
        openSettings.target = self
        menu.addItem(openSettings)

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

    @objc private func openSettings(_ sender: Any?) {
        // SwiftUI `Settings` scene, opened the AppKit way (no SettingsLink
        // before macOS 14). TODO: swap for SettingsLink once min target allows.
        if #available(macOS 13, *) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    @objc private func toggleShowHidePanel(_ sender: Any?) {
        togglePanel()
    }

    @objc private func refreshNowAction(_ sender: Any?) {
        refreshNow()
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
