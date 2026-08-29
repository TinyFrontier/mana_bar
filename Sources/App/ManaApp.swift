import SwiftUI

/// Entry point of Mana.
///
/// Mana is an accessory app (`LSUIElement = true`, see Info.plist): no Dock icon,
/// no main window. All UI lives in the status bar item and the hot-zone panel,
/// both owned by `AppDelegate`.
///
/// The `Settings` scene below is *not* how the status-bar menu's "Open
/// Settings…" opens the settings UI — that goes through
/// `AppDelegate.settingsWindowController` (`SettingsWindowController`), a
/// plain `NSWindow`. Opening this scene the AppKit way
/// (`NSApp.sendAction(Selector(("showSettingsWindow:")), ...)`) is a
/// pre-`SettingsLink` (macOS 14+) trick that silently no-ops for an
/// accessory app on newer macOS — see `SettingsWindowController`'s doc
/// comment for the full story. The scene stays declared here only because
/// `App.body` requires *some* `Scene`, and it's a free (if currently
/// unreachable) ⌘, fallback should the app ever gain an app menu.
///
/// See docs/ТЗ-Mana.md section 7 "Системная интеграция" for the accessory-app
/// requirements this shell fulfils.
@main
struct ManaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
