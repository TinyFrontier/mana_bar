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

    init(model: PanelModel) {
        self.model = model
        let size = PanelLayoutMetrics.containerSize(serviceCount: model.serviceOrder.count)

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

        contentView = FirstMouseHostingView(rootView: PanelView(model: model))

        // Drag-to-reposition (ТЗ §6, Grammarly-style): `PanelView`'s island
        // calls these through `PanelModel` on every DragGesture
        // change/end — see `handleDragChanged`/`handleDragEnded` below.
        model.onDragChanged = { [weak self] in self?.handleDragChanged() }
        model.onDragEnded = { [weak self] in self?.handleDragEnded() }

        if let screen = NSScreen.main {
            reposition(on: screen)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// AppKit's default implementation keeps a window's title bar on screen,
    /// which for this borderless container means silently nudging the frame
    /// we just computed — the off-screen "hidden" frame sits entirely past the
    /// edge, and the `.top` docked frame intentionally overhangs the screen's
    /// top (the container is much taller than the island it centers). Both are
    /// deliberate, so the computed frame is taken verbatim and
    /// `PanelLayoutMetrics.dockedFrame` stays the single source of truth.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // MARK: - Frame math

    /// Screen edge the window docks to (ТЗ §6) — read live off
    /// `AppSettings.shared.panelEdge` (same pattern as `AppSettings
    /// .verticalPosition`/`.verticalOffset` below) so a Settings change picks
    /// up the instant `reposition(on:)` next runs. `PanelView` mirrors its
    /// own layout (island alignment, card offset, rounded corners) off the
    /// same setting, so the visible window frame and its SwiftUI content
    /// always agree on which side the island lives on.
    private var dockEdge: PanelEdge { AppSettings.shared.panelEdge }

    private func hiddenFrame(on screen: NSScreen) -> NSRect {
        PanelLayoutMetrics.offscreenFrame(
            screenFrame: screen.frame,
            serviceCount: model.serviceOrder.count,
            verticalPosition: AppSettings.shared.verticalPosition,
            edge: dockEdge,
            verticalOffset: CGFloat(AppSettings.shared.verticalOffset)
        )
    }

    /// Docked frame: flush against the screen edge (ТЗ §3.2 — панель прижата
    /// к краю), vertically positioned per `AppSettings.verticalPosition`
    /// plus the free `AppSettings.verticalOffset` shift (ТЗ §6). All of the
    /// math lives in `PanelLayoutMetrics.dockedFrame`, which is pure and
    /// unit-tested (`PanelFrameTests`).
    private func shownFrame(on screen: NSScreen) -> NSRect {
        PanelLayoutMetrics.dockedFrame(
            screenFrame: screen.frame,
            serviceCount: model.serviceOrder.count,
            verticalPosition: AppSettings.shared.verticalPosition,
            edge: dockEdge,
            verticalOffset: CGFloat(AppSettings.shared.verticalOffset)
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

    // MARK: - Drag-to-reposition (ТЗ §6, Grammarly-style island drag)

    /// Window frame's origin Y captured at the start of the current drag
    /// gesture (nil when no drag is in progress) — `updateDrag`/`endDrag`
    /// measure from this fixed reference rather than re-applying incremental
    /// per-event deltas, so nothing drifts over a long drag.
    private var dragStartFrameOriginY: CGFloat?
    private var dragPhase: PanelDragPhase = .pending

    /// Mouse **screen** Y (`NSEvent.mouseLocation`, AppKit's up-positive,
    /// window-independent coordinates) captured at the start of the current
    /// drag — the reference `handleDragChanged`/`handleDragEnded` measure
    /// against to turn a live cursor position into a `deltaY` for
    /// `updateDrag`/`endDrag`.
    private var dragStartMouseY: CGFloat?

    /// Wired to `PanelModel.onDragChanged` (set in `init` above), called by
    /// `PanelView`'s `DragGesture(minimumDistance: 0)` on the island for
    /// every change, including the very first one right after mouse-down.
    ///
    /// Deliberately reads `NSEvent.mouseLocation` (real screen coordinates,
    /// same technique `HotZoneMonitor` already uses) instead of the
    /// gesture's own `value.translation`: `translation` is measured in the
    /// SwiftUI view's *local* coordinate space, and `updateDrag` moves this
    /// very window — and the view along with it — mid-gesture, so a
    /// translation-based delta would be computed against a reference frame
    /// that's itself sliding out from under the cursor, producing runaway
    /// feedback instead of a 1:1 follow. Screen coordinates have no such
    /// problem: they don't move when this window does.
    private func handleDragChanged() {
        let mouseY = NSEvent.mouseLocation.y
        if dragStartMouseY == nil {
            dragStartMouseY = mouseY
        }
        guard let startMouseY = dragStartMouseY else { return }
        updateDrag(deltaY: mouseY - startMouseY)
    }

    /// Wired to `PanelModel.onDragEnded`, called once when the gesture ends
    /// (mouse-up) — see `handleDragChanged` for why this reads
    /// `NSEvent.mouseLocation` rather than `value.translation`.
    private func handleDragEnded() {
        defer { dragStartMouseY = nil }
        let mouseY = NSEvent.mouseLocation.y
        let startMouseY = dragStartMouseY ?? mouseY
        endDrag(deltaY: mouseY - startMouseY)
    }

    /// Moves the window live during a drag, no animation — the window
    /// tracks the cursor directly, same as dragging an island in Grammarly.
    /// `deltaY` is the gesture's cumulative vertical distance since it
    /// began, in AppKit screen points (positive = up, matching
    /// `frame.origin.y`'s own convention).
    ///
    /// Below `PanelDragGesture.verticalThreshold` this is a no-op — an
    /// ordinary click or a hover-intent micro-movement never nudges the
    /// window (`PanelDragGesture.phase` decides; once `.dragging` is
    /// reached it's sticky for the rest of the gesture).
    ///
    /// Exposed (not `private`) so a test can drive the exact code path a
    /// real drag uses — one or more `updateDrag(deltaY:)` calls (the first
    /// one captures the drag's starting frame) followed by
    /// `endDrag(deltaY:)` — without posting synthetic mouse events, which
    /// this sandboxed environment has no permission to do.
    func updateDrag(deltaY: CGFloat) {
        if dragStartFrameOriginY == nil {
            dragStartFrameOriginY = frame.origin.y
            dragPhase = .pending
        }
        guard let startFrameY = dragStartFrameOriginY else { return }
        dragPhase = PanelDragGesture.phase(afterVerticalDelta: deltaY, previousPhase: dragPhase)
        guard dragPhase == .dragging else { return }
        var newFrame = frame
        newFrame.origin.y = startFrameY + deltaY
        setFrame(newFrame, display: true)
    }

    /// Ends the drag begun by the first `updateDrag(deltaY:)` call,
    /// recomputing `AppSettings.verticalOffset` from the window's final
    /// position relative to the current `AppSettings.verticalPosition`
    /// anchor (`PanelLayoutMetrics.verticalOffset(forDockedFrameOriginY:)`).
    /// Assigning `AppSettings.verticalOffset` is exactly what the Settings
    /// slider itself does — the existing `AppDelegate.observeSettings()`
    /// subscription reacts the same way either path got there: it re-clamps
    /// through `PanelLayoutMetrics` on the next `reposition(on:)` and pushes
    /// the same value into `HotZoneMonitor.verticalOffset`, so the invisible
    /// hot-zone strip ends the drag already tracking the island.
    ///
    /// No-op if the drag never crossed the threshold (a plain click) — nothing
    /// is written to `AppSettings` and the frame is left exactly where
    /// `updateDrag` last put it (i.e. untouched, since it was also a no-op).
    ///
    /// Rounds the recovered offset to the nearest whole point: `NSWindow
    /// .setFrame` itself only ever places a window at integral point
    /// coordinates (confirmed live — an odd-height screen, e.g. 1169pt, puts
    /// `screenFrame.midY` at a half-point value that `dockedOriginY` folds
    /// in and AppKit then silently rounds away when the frame is actually
    /// set), so a fractional `.5` in the recovered offset reflects that
    /// rounding, not anything the user actually dragged to — storing it
    /// unrounded would just be carrying AppKit's own noise into a persisted
    /// preference for no benefit (`AppSettings.verticalOffset` is already
    /// displayed rounded to whole points in Settings).
    func endDrag(deltaY: CGFloat) {
        defer {
            dragStartFrameOriginY = nil
            dragPhase = .pending
        }
        guard dragPhase == .dragging,
              let startFrameY = dragStartFrameOriginY,
              let targetScreen = screen ?? NSScreen.main
        else { return }
        let finalOriginY = startFrameY + deltaY
        let rawOffset = PanelLayoutMetrics.verticalOffset(
            forDockedFrameOriginY: finalOriginY,
            screenFrame: targetScreen.frame,
            serviceCount: model.serviceOrder.count,
            verticalPosition: AppSettings.shared.verticalPosition
        )
        AppSettings.shared.verticalOffset = rawOffset.rounded()
    }
}

/// `NSHostingView` subclass that responds to the very first click, instead
/// of AppKit's default "first click on an inactive window merely brings it
/// forward, a second click is needed to actually reach the view" behavior.
///
/// `PanelWindow` is a `.nonactivatingPanel` that never becomes key and whose
/// owning app is `.accessory` (essentially never the frontmost app), so
/// *every* click on it would otherwise be exactly that "first click on an
/// inactive window" case — `acceptsFirstMouse(for:)` is the per-view (not
/// per-window) override that opts out, matching how the system's own
/// floating/utility panels (e.g. the color or font panel) respond
/// immediately without needing to be brought forward first. Load-bearing for
/// both the detail card's "Grant access"/"Re-login" buttons and the new
/// island drag gesture (`PanelWindow.updateDrag`/`.endDrag`) — both are
/// mouse-down-driven, so without this override the very first interaction
/// after the panel appears could silently do nothing.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
