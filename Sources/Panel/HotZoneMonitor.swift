import AppKit
import ApplicationServices
import Foundation

/// Watches global mouse movement for entry into the invisible "hot zone"
/// strip at the screen edge, and drives panel show/hide.
///
/// Per docs/ТЗ-Mana.md §3.1 and §8, this uses
/// `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` (no polling
/// loop) plus a local monitor (the global monitor never fires for events
/// targeting Mana's own windows), with an O(1) hit test
/// (`HotZoneGeometry.contains`) against the hot-zone rect, and the show/hide
/// debounce delays from §3.5 (appear ~120ms, disappear ~350ms — defaults
/// mirror `AppSettings.appearDelayMs` / `.disappearDelayMs`).
///
/// Accessibility permission (ТЗ §7) and `start()`: mouse-move events are the
/// one class of global event `NSEvent.addGlobalMonitorForEvents` delivers
/// *without* the Accessibility grant (only key events are gated on it), so
/// `start()` installs the monitors unconditionally and reports whether the
/// install actually succeeded. `accessibilityAvailable` is kept as a
/// last-observed status for the onboarding UI, not as a gate — refusing to
/// install without the grant is what left hover-to-show dead even on machines
/// where it would have worked. `start()` is also idempotent and safe to
/// re-call, which is how `AppDelegate` re-arms the monitor the moment
/// `AccessibilityPermissionMonitor` sees a grant, with no app restart
/// (ТЗ §11 keeps the menu-bar "Show/Hide Panel" fallback either way).
final class HotZoneMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var showWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?

    /// Width of the hot-zone strip, 2–4px per ТЗ §3.1.
    var hotZoneWidth: CGFloat = 3
    /// Height of the hot zone == current panel content height; the owner
    /// (AppDelegate) keeps this in sync with `PanelModel.serviceOrder.count`.
    var panelHeight: CGFloat = PanelLayoutMetrics.panelHeight(serviceCount: 2)
    /// Which edge the panel docks to (ТЗ §6). Kept as a plain pushed-in
    /// value rather than reading `AppSettings.shared` directly — this type
    /// isn't `@MainActor` (it's driven by a global `NSEvent` monitor
    /// callback) and stays that way on purpose, so `AppDelegate` copies the
    /// current setting in on launch and again on every change.
    var edge: PanelEdge = .right
    /// Vertical placement along the edge (ТЗ §6), same plain-pushed-in
    /// pattern as `edge` — must track `PanelWindow`'s own placement or the
    /// invisible hot-zone strip and the visible panel drift apart.
    var verticalPosition: PanelVerticalPosition = .center

    var appearDelay: TimeInterval = 0.12
    var disappearDelay: TimeInterval = 0.35

    /// Supplies the panel's current on-screen frame (nil while hidden) so
    /// hovering the visible island/card also counts as "stay open", not
    /// just the hot-zone strip itself.
    var panelHitTestFrame: (() -> CGRect?)?

    /// Fires after `appearDelay` of continuous hot-zone/panel presence.
    var onEnterHotZone: (() -> Void)?
    /// Fires after `disappearDelay` of continuous absence.
    var onLeaveHotZone: (() -> Void)?

    private(set) var isInsideHotZoneOrPanel = false

    /// Accessibility permission state as of the last `start()` — reported for
    /// the onboarding status row only; it does not gate the monitors.
    private(set) var accessibilityAvailable = false

    /// `true` while the global mouse-move monitor is installed.
    var isRunning: Bool { globalMonitor != nil }

    /// Event-monitor installers/remover, injectable so tests can drive
    /// `start()`/`stop()` without touching the real global event stream.
    /// Production defaults call `NSEvent` directly.
    var installGlobalMonitor: (@escaping (NSEvent) -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler)
    }
    var installLocalMonitor: (@escaping (NSEvent) -> Void) -> Any? = { handler in
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            handler(event)
            return event
        }
    }
    var removeMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }

    init() {}

    deinit {
        stop()
    }

    /// Installs the global + local mouse-move monitors.
    ///
    /// Idempotent: a second call while already running is a no-op that still
    /// returns `true`, so `AppDelegate` can retry it freely (e.g. right after
    /// an Accessibility grant) without leaking monitors.
    ///
    /// - Returns: whether the global monitor is installed afterwards. `false`
    ///   means AppKit refused the install and the menu-bar "Show/Hide Panel"
    ///   fallback is the only way in (ТЗ §11).
    @discardableResult
    func start() -> Bool {
        accessibilityAvailable = AXIsProcessTrusted()
        guard globalMonitor == nil else { return true }

        globalMonitor = installGlobalMonitor { [weak self] _ in
            self?.handleMouseMoved()
        }
        localMonitor = installLocalMonitor { [weak self] _ in
            self?.handleMouseMoved()
        }
        return globalMonitor != nil
    }

    /// Removes the monitors and cancels any pending debounce timers.
    func stop() {
        if let globalMonitor {
            removeMonitor(globalMonitor)
        }
        if let localMonitor {
            removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        showWorkItem?.cancel()
        hideWorkItem?.cancel()
        showWorkItem = nil
        hideWorkItem = nil
    }

    // MARK: - Hit testing

    private func handleMouseMoved() {
        let location = NSEvent.mouseLocation
        if isPointInsideHotZoneOrPanel(location) {
            scheduleShow()
        } else {
            scheduleHide()
        }
    }

    /// O(1): one screen lookup + at most two rect containment checks.
    private func isPointInsideHotZoneOrPanel(_ point: CGPoint) -> Bool {
        guard let screen = screenContaining(point) else { return false }
        let hotZone = HotZoneGeometry.rect(
            screenFrame: screen.frame,
            panelHeight: panelHeight,
            width: hotZoneWidth,
            edge: edge,
            verticalPosition: verticalPosition
        )
        if HotZoneGeometry.contains(point, in: hotZone) {
            return true
        }
        if let panelFrame = panelHitTestFrame?(), panelFrame.contains(point) {
            return true
        }
        return false
    }

    private func screenContaining(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    // MARK: - Debounce

    private func scheduleShow() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard !isInsideHotZoneOrPanel, showWorkItem == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isInsideHotZoneOrPanel = true
            self.showWorkItem = nil
            self.onEnterHotZone?()
        }
        showWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + appearDelay, execute: work)
    }

    private func scheduleHide() {
        showWorkItem?.cancel()
        showWorkItem = nil
        guard isInsideHotZoneOrPanel, hideWorkItem == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isInsideHotZoneOrPanel = false
            self.hideWorkItem = nil
            self.onLeaveHotZone?()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + disappearDelay, execute: work)
    }
}
