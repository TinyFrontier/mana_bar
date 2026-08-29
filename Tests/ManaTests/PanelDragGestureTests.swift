import XCTest
@testable import Mana

/// Coverage for `PanelDragGesture`, the pure vertical-distance threshold
/// state machine behind the island drag-to-reposition feature (ТЗ §6,
/// "перетаскивание, как у Grammarly"). Guards the two properties the live
/// feedback needs: an ordinary click/hover-intent movement never starts a
/// drag, and once a drag has genuinely started it doesn't stutter back to
/// `.pending` on a small backward wobble mid-gesture.
final class PanelDragGestureTests: XCTestCase {
    func testStaysPendingBelowThreshold() {
        let justUnder = PanelDragGesture.verticalThreshold - 0.5
        XCTAssertEqual(
            PanelDragGesture.phase(afterVerticalDelta: justUnder, previousPhase: .pending),
            .pending
        )
        XCTAssertEqual(
            PanelDragGesture.phase(afterVerticalDelta: -justUnder, previousPhase: .pending),
            .pending,
            "threshold check must be on magnitude, not signed direction"
        )
        XCTAssertEqual(
            PanelDragGesture.phase(afterVerticalDelta: 0, previousPhase: .pending),
            .pending,
            "a plain click (near-zero movement) must never start a drag"
        )
    }

    func testCommitsToDraggingAtOrAboveThreshold() {
        XCTAssertEqual(
            PanelDragGesture.phase(afterVerticalDelta: PanelDragGesture.verticalThreshold, previousPhase: .pending),
            .dragging,
            "exactly at the threshold should commit"
        )
        XCTAssertEqual(
            PanelDragGesture.phase(afterVerticalDelta: PanelDragGesture.verticalThreshold + 20, previousPhase: .pending),
            .dragging
        )
        XCTAssertEqual(
            PanelDragGesture.phase(afterVerticalDelta: -(PanelDragGesture.verticalThreshold + 20), previousPhase: .pending),
            .dragging,
            "a downward drag past the threshold commits just like an upward one"
        )
    }

    func testDraggingIsStickyForTheRestOfTheGesture() {
        // Once committed, even a delta back at (or under) zero must not
        // un-commit — otherwise the window would visibly snap back to
        // .pending mid-drag on every small direction change.
        XCTAssertEqual(
            PanelDragGesture.phase(afterVerticalDelta: 0, previousPhase: .dragging),
            .dragging
        )
        XCTAssertEqual(
            PanelDragGesture.phase(afterVerticalDelta: 1, previousPhase: .dragging),
            .dragging
        )
    }

    /// Simulates a realistic sequence of `onChanged` calls across one
    /// gesture: small jitter first (stays pending), then a real vertical
    /// pull (commits), then a wobble back toward zero (stays committed).
    func testRealisticGestureSequence() {
        var phase: PanelDragPhase = .pending
        let deltas: [CGFloat] = [0, 1, 2, 3, 4, 8, 15, 40, 30, 10, 2]
        let expected: [PanelDragPhase] = [.pending, .pending, .pending, .pending, .pending, .dragging, .dragging, .dragging, .dragging, .dragging, .dragging]

        for (delta, want) in zip(deltas, expected) {
            phase = PanelDragGesture.phase(afterVerticalDelta: delta, previousPhase: phase)
            XCTAssertEqual(phase, want, "after delta \(delta)")
        }
    }
}
