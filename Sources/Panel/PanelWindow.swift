import AppKit
import SwiftUI

/// The hot-zone panel window itself: a borderless, nonactivating `NSPanel`
/// pinned to the right (or left) screen edge that slides in/out of view.
///
/// Per docs/ТЗ-Mana.md section 3.2, this window must:
/// - float at `.statusBar` level, above full-screen apps
///   (`collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`);
/// - never take keyboard focus or activate the app (`.nonactivatingPanel`);
/// - host `PanelView` as its SwiftUI content.
///
/// This is a setup-phase skeleton: construction wires up panel style/level,
/// but show/hide animation, positioning math, and multi-monitor handling are
/// TODO for the implementation phase.
final class PanelWindow: NSPanel {
    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 320),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false

        contentView = NSHostingView(rootView: PanelView())
    }

    /// Slides the panel into view from the screen edge.
    /// TODO: animate frame origin over 200–250ms ease-out (ТЗ §3.2).
    func show() {
        orderFrontRegardless()
    }

    /// Slides the panel back out of view.
    /// TODO: animate frame origin over 200–250ms ease-in, with the
    /// 300–400ms "leave" debounce owned by HotZoneMonitor (ТЗ §3.5).
    func hide() {
        orderOut(nil)
    }

    /// Repositions the panel against the configured screen edge.
    /// TODO: honor AppSettings edge/vertical-position/monitor selection,
    /// and re-run on screen configuration changes (ТЗ §7).
    func reposition(on screen: NSScreen) {
        // Stub — implementation phase computes the real edge-docked frame.
    }
}
