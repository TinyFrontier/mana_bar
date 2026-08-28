import SwiftUI

/// Entry point of Mana.
///
/// Mana is an accessory app (`LSUIElement = true`, see Info.plist): no Dock icon,
/// no main window. All UI lives in the status bar item and the hot-zone panel,
/// both owned by `AppDelegate`. The `Settings` scene below gives the app a
/// standard SwiftUI settings window, opened from the status bar menu.
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
