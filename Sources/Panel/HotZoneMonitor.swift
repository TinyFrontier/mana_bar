import AppKit
import Foundation

/// Watches global mouse movement for entry into the invisible "hot zone"
/// strip at the screen edge, and drives panel show/hide.
///
/// Per docs/ТЗ-Mana.md section 3.1 and 8, this must use
/// `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` (no polling
/// loop) with an O(1) hit test against the configured hot-zone rect, plus
/// the show/hide debounce delays from section 3.5 (appear delay ~100–150ms,
/// disappear delay ~300–400ms). Requires Accessibility permission (ТЗ §7).
///
/// This is a setup-phase skeleton — no monitor is installed yet.
final class HotZoneMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Called when the cursor enters the hot zone (after the appear delay).
    var onEnterHotZone: (() -> Void)?

    /// Called when the cursor leaves the panel + hot zone (after the leave delay).
    var onLeaveHotZone: (() -> Void)?

    init() {}

    deinit {
        stop()
    }

    /// Installs the global mouse-move monitor.
    /// TODO: implement O(1) hot-zone hit test + debounce timers.
    func start() {
        // Stub: real implementation installs
        // NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { ... }
        // and checks AXIsProcessTrusted() before relying on the global monitor,
        // falling back to menu-bar click toggling per ТЗ §11 if not granted.
    }

    /// Removes the monitor and cancels any pending debounce timers.
    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }
}
