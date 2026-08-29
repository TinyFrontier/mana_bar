import CoreGraphics

/// Pure state machine deciding whether an in-progress island drag (ТЗ §6:
/// "перетаскивание, как у Grammarly") has moved far enough vertically to
/// commit to actually repositioning the window, as opposed to being an
/// ordinary click or a hover-intent movement. Kept free of AppKit/SwiftUI so
/// it's directly unit-testable (`PanelDragGestureTests`); `PanelWindow` is
/// the only production caller.
enum PanelDragPhase: Equatable {
    /// Below the vertical threshold since the gesture began — the window
    /// hasn't moved yet, so a plain click, a ring hover, or a detail-card
    /// button click still behaves exactly as it did before this feature
    /// existed.
    case pending
    /// The threshold was crossed at least once this gesture — the window is
    /// now tracking the cursor. Sticky for the rest of the gesture: once
    /// dragging, a small backward wobble under the threshold doesn't drop
    /// back to `.pending` (that would make the window visibly stutter).
    case dragging
}

enum PanelDragGesture {
    /// Vertical distance, in points, a drag must travel from its start
    /// before it commits to moving the window. Chosen small enough to feel
    /// immediate but large enough that an ordinary click or a hover-intent
    /// micro-movement (opening the detail card, pressing its "Grant
    /// access"/"Re-login" button) never gets misread as a drag — the live
    /// feedback this exists to satisfy.
    static let verticalThreshold: CGFloat = 5

    /// Advances `previousPhase` given the gesture's cumulative vertical
    /// distance traveled since it began (positive or negative — only the
    /// magnitude matters for the threshold check).
    static func phase(afterVerticalDelta deltaY: CGFloat, previousPhase: PanelDragPhase) -> PanelDragPhase {
        if previousPhase == .dragging { return .dragging }
        return abs(deltaY) >= verticalThreshold ? .dragging : .pending
    }
}
