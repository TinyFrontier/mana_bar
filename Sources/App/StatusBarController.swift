import AppKit

/// Owns the menu-bar (status) item and its dropdown menu.
///
/// Per docs/ТЗ-Mana.md section 7, Mana has no Dock icon; the status bar item
/// is the only always-visible system-integration surface, exposing:
/// Open Settings, Refresh Now, Pause, Quit. This is the one piece of the
/// setup skeleton that is fully wired up (a bare status item is required for
/// the app to be usable at all); the actions themselves are TODO stubs that
/// the implementation phase will connect to the real panel/provider logic.
final class StatusBarController {
    private let statusItem: NSStatusItem

    private enum MenuItemTag: Int {
        case openSettings = 1
        case refreshNow = 2
        case pause = 3
        case quit = 4
    }

    init() {
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

        let refreshNow = NSMenuItem(
            title: "Refresh Now",
            action: #selector(refreshNow(_:)),
            keyEquivalent: "r"
        )
        refreshNow.tag = MenuItemTag.refreshNow.rawValue
        refreshNow.target = self
        menu.addItem(refreshNow)

        let pause = NSMenuItem(
            title: "Pause",
            action: #selector(togglePause(_:)),
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

    @objc private func refreshNow(_ sender: Any?) {
        // TODO: trigger an immediate poll of all enabled UsageProviders.
    }

    @objc private func togglePause(_ sender: Any?) {
        // TODO: pause/resume the hot-zone monitor + polling, flip menu item state.
    }
}
