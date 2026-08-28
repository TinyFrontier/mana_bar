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
/// Requires Accessibility permission (ТЗ §7): `start()` checks
/// `AXIsProcessTrusted()` first and refuses to install the monitor if it's
/// not granted, exposing `accessibilityAvailable` so the caller can fall
/// back to the menu-bar "Show/Hide Panel" toggle (ТЗ §11).
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
    /// Which edge the panel docks to (ТЗ §6). TODO: read from AppSettings.
    var edge: PanelEdge = .right

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

    /// Whether Accessibility permission is currently granted. `start()`
    /// refuses to install monitors when this is `false` (ТЗ §11 fallback).
    private(set) var accessibilityAvailable = false

    init() {}

    deinit {
        stop()
    }

    /// Installs the global + local mouse-move monitors. Returns `false`
    /// (and installs nothing) if Accessibility permission isn't granted.
    @discardableResult
    func start() -> Bool {
        accessibilityAvailable = AXIsProcessTrusted()
        guard accessibilityAvailable else { return false }
        guard globalMonitor == nil else { return true }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved()
            return event
        }
        return true
    }

    /// Removes the monitors and cancels any pending debounce timers.
    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
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
            edge: edge
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
