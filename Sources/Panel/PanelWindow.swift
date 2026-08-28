import AppKit
import SwiftUI

/// The hot-zone panel window itself: a borderless, nonactivating `NSPanel`
/// pinned to the right (or left) screen edge that slides in/out of view.
///
/// Per docs/ТЗ-Mana.md §3.2, this window:
/// - floats at `.statusBar` level, above full-screen apps
///   (`collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`);
/// - never takes keyboard focus or activates the app (`.nonactivatingPanel`);
/// - hosts `PanelView` as its SwiftUI content.
///
/// Show/hide is a literal AppKit frame animation — `show`/`hide` move the
/// window's `frame.origin.x` between an off-screen position (just past the
/// chosen edge) and its docked position, over 230ms with the design spec's
/// `cubic-bezier(0.22, 0.7, 0.3, 1)` curve (design-spec.md §6.1–§6.2) — the
/// window itself is sized once, generously, to fit both the compact island
/// and the widest possible detail-card flyout (`PanelLayoutMetrics`), so
/// resizing is never needed mid-animation.
final class PanelWindow: NSPanel {
    private let model: PanelModel

    /// `true` once `show` has been called and `hide`'s animation hasn't
    /// completed yet — i.e. the window is on (or animating onto) screen.
    private(set) var isShown = false

    private var contentSize: NSSize {
        NSSize(
            width: PanelLayoutMetrics.containerWidth(),
            height: PanelLayoutMetrics.containerHeight(serviceCount: model.serviceOrder.count)
        )
    }

    init(model: PanelModel) {
        self.model = model
        let size = NSSize(
            width: PanelLayoutMetrics.containerWidth(),
            height: PanelLayoutMetrics.containerHeight(serviceCount: model.serviceOrder.count)
        )

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        // The window's own content bounds are much larger than what's
        // visibly drawn (empty space reserved for the card flyout); a
        // native window shadow would draw a big rectangular shadow behind
        // that empty space, so shadows are drawn per-element in SwiftUI
        // instead (island + card each carry their own `.shadow()`).
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false

        contentView = NSHostingView(rootView: PanelView(model: model))

        if let screen = NSScreen.main {
            reposition(on: screen)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Frame math

    private func hiddenFrame(on screen: NSScreen) -> NSRect {
        let size = contentSize
        return NSRect(
            x: screen.frame.maxX,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Docked frame: right-aligned to the edge (ТЗ §3.2 — panel prижата к
    /// краю), vertically centered on the screen (ТЗ §3.1).
    /// TODO: honor `AppSettings.panelEdge` / `.verticalPosition` instead of
    /// always docking right/center.
    private func shownFrame(on screen: NSScreen) -> NSRect {
        let size = contentSize
        return NSRect(
            x: screen.frame.maxX - size.width,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // design-spec.md §6.1/§6.2: 230ms, cubic-bezier(0.22, 0.7, 0.3, 1), both directions.
    private static let slideDuration: TimeInterval = 0.23
    private static let slideTimingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.7, 0.3, 1)

    // MARK: - Show / hide

    /// Slides the panel into view from the screen edge (ТЗ §3.2).
    func show(on screen: NSScreen, animated: Bool = true) {
        isShown = true
        let target = shownFrame(on: screen)

        guard animated else {
            setFrame(target, display: true)
            orderFrontRegardless()
            return
        }
        if !isVisible {
            setFrame(hiddenFrame(on: screen), display: false)
        }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = Self.slideTimingFunction
            animator().setFrame(target, display: true)
        }
    }

    /// Slides the panel back out of view (ТЗ §3.5). The 300–400ms "leave"
    /// debounce itself is owned by `HotZoneMonitor`, not this method — by
    /// the time `hide()` is called the decision to hide has already been
    /// made.
    func hide(animated: Bool = true) {
        isShown = false
        guard let targetScreen = screen ?? NSScreen.main else {
            orderOut(nil)
            return
        }
        let target = hiddenFrame(on: targetScreen)

        guard animated else {
            setFrame(target, display: true)
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.slideDuration
            context.timingFunction = Self.slideTimingFunction
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }
            self.orderOut(nil)
        })
    }

    /// Repositions the panel against the configured screen edge without
    /// animating — call on launch and on screen-configuration changes
    /// (ТЗ §7: re-run on `NSApplication.didChangeScreenParametersNotification`).
    func reposition(on screen: NSScreen) {
        setFrame(isShown ? shownFrame(on: screen) : hiddenFrame(on: screen), display: isVisible)
    }

    // MARK: - Hot-zone integration

    /// Current content bounds in screen coordinates while shown — fed to
    /// `HotZoneMonitor.panelHitTestFrame` so hovering the visible
    /// island/card (not just the hot-zone strip) keeps the panel open.
    var hitTestFrame: CGRect? {
        isShown ? frame : nil
    }
}
