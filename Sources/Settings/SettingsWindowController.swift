import AppKit
import SwiftUI

/// Owns the Settings window as a plain `NSWindow`, not the SwiftUI `Settings`
/// scene declared in `ManaApp`.
///
/// The previous implementation opened the SwiftUI scene the AppKit way —
/// `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`
/// — since `SettingsLink` needs macOS 14+ and this app targets 13.0. That
/// selector is resolved by `NSApplication`'s own internal SwiftUI-scene
/// plumbing, and on newer macOS (observed on Darwin 25.x / macOS 15+) it
/// silently finds no responder for an accessory (`LSUIElement`) app that
/// never activates into the foreground the normal way — the send is a no-op,
/// so "Open Settings…" did nothing at all, with no error anywhere.
///
/// This mirrors the onboarding window's own pattern
/// (`AppDelegate.showOnboardingWindow`): one lazily-created `NSWindow`,
/// `isReleasedWhenClosed = false` so the reference stays valid after the
/// user closes it, and an explicit `NSApp.activate` + `makeKeyAndOrderFront`
/// on every `show()` since an accessory app never activates on its own. A
/// second `show()` call reuses the existing window (re-fronts it) instead of
/// creating another one — see `SettingsWindowControllerTests`.
@MainActor
final class SettingsWindowController {
    /// `private(set)` rather than `private`: `@testable import Mana` reads
    /// this to verify a repeated `show()` reuses the same instance, without
    /// otherwise exposing it — nothing outside this file ever *sets* it.
    private(set) var window: NSWindow?

    /// Injectable so tests can verify the single-instance/reuse behavior
    /// without constructing the real `SettingsView` (and, through it,
    /// `AppSettings.shared`).
    private let makeContentView: () -> NSView

    init(makeContentView: @escaping () -> NSView = { NSHostingView(rootView: SettingsView()) }) {
        self.makeContentView = makeContentView
    }

    /// Shows the settings window, creating it once and reusing it after —
    /// reachable both from the status-bar menu's "Open Settings…" item and,
    /// were it ever needed, anywhere else in the app.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Mana Settings"
        // Keep the instance alive across close/reopen instead of the default
        // dealloc-on-close — the whole point is a single reused window
        // (matches `AppDelegate`'s onboarding window).
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.contentView = makeContentView()
        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }
}
