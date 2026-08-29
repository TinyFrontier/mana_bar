import XCTest
@testable import Mana

/// Coverage for `CardHoverCoordinator`, the pure state machine behind the
/// detail-card flyout's hover-driven visibility (bugfix: the card used to
/// vanish the instant the cursor left the small ring hit-area, before it
/// could ever cross the gap to the card itself — making the error-state
/// "Grant access" button unreachable).
///
/// `scheduleHide`/`cancelScheduledHide` are swapped for a deterministic fake
/// (`FakeScheduler`) so every grace-period transition below is driven by
/// explicit calls (`fireIfPending`, `wasCancelled`), never real time — no
/// sleeping, no flakiness.
@MainActor
final class CardHoverCoordinatorTests: XCTestCase {
    /// Captures what `CardHoverCoordinator` schedules/cancels instead of
    /// touching a real timer. Only ever holds at most one pending action at
    /// a time in these tests, mirroring the coordinator's own invariant
    /// (`pendingHideToken == nil` guard in `reconsider()`).
    private final class FakeScheduler {
        private(set) var scheduledDelay: TimeInterval?
        private var pendingAction: (() -> Void)?
        private(set) var cancelCount = 0
        private(set) var scheduleCount = 0

        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> Any {
            scheduleCount += 1
            scheduledDelay = delay
            pendingAction = action
            return "token-\(scheduleCount)" // any distinguishable, non-nil token
        }

        func cancel(_ token: Any) {
            cancelCount += 1
            pendingAction = nil
        }

        /// Simulates the grace timer elapsing — runs the pending action, if
        /// any is still outstanding (i.e. wasn't cancelled).
        func fire() {
            let action = pendingAction
            pendingAction = nil
            action?()
        }

        var hasPendingAction: Bool { pendingAction != nil }
    }

    private func makeSUT() -> (CardHoverCoordinator, FakeScheduler) {
        let scheduler = FakeScheduler()
        let coordinator = CardHoverCoordinator()
        coordinator.hideDelay = 0.25
        coordinator.scheduleHide = { delay, action in scheduler.schedule(delay, action) }
        coordinator.cancelScheduledHide = { token in scheduler.cancel(token) }
        return (coordinator, scheduler)
    }

    // MARK: - ring -> gap -> card: card must NOT disappear

    func testRingToGapToCardKeepsCardVisible() {
        let (sut, scheduler) = makeSUT()

        sut.ringEntered(.claude)
        XCTAssertEqual(sut.displayedServiceID, .claude)

        // Cursor leaves the ring, crossing the gap toward the card — a hide
        // is scheduled but the card must still be showing right now.
        sut.ringExited(.claude)
        XCTAssertEqual(sut.displayedServiceID, .claude, "card must stay up during the grace period")
        XCTAssertEqual(scheduler.scheduleCount, 1)
        XCTAssertEqual(scheduler.scheduledDelay, 0.25)

        // Cursor lands on the card before the grace period elapses.
        sut.card(isHovering: true)
        XCTAssertEqual(scheduler.cancelCount, 1, "entering the card must cancel the pending hide")
        XCTAssertFalse(scheduler.hasPendingAction)

        // Even if the (already-cancelled) timer somehow fired, the card must
        // still be there — nothing left to fire, but assert the end state too.
        XCTAssertEqual(sut.displayedServiceID, .claude)
    }

    // MARK: - ring -> gap -> cursor leaves entirely: card disappears after the delay

    func testRingToGapToAwayHidesAfterGracePeriod() {
        let (sut, scheduler) = makeSUT()

        sut.ringEntered(.claude)
        sut.ringExited(.claude)
        XCTAssertEqual(sut.displayedServiceID, .claude, "still visible immediately after leaving the ring")
        XCTAssertEqual(scheduler.scheduleCount, 1)

        // Cursor never reaches the card and never returns to a ring — the
        // grace timer elapses.
        scheduler.fire()
        XCTAssertNil(sut.displayedServiceID, "card must hide once the grace period actually elapses")
    }

    // MARK: - ring A -> ring B: instant switch, no grace delay

    func testSwitchingDirectlyBetweenRingsIsInstant() {
        let (sut, scheduler) = makeSUT()

        sut.ringEntered(.claude)
        XCTAssertEqual(sut.displayedServiceID, .claude)

        // SwiftUI's onHover ordering: the new ring's `true` can arrive before
        // or after the old ring's `false`. Cover the "before" ordering here —
        // entering ring B while ring A is still nominally hovered.
        sut.ringEntered(.chatgpt)
        XCTAssertEqual(sut.displayedServiceID, .chatgpt, "switches immediately, no grace period")
        XCTAssertEqual(scheduler.scheduleCount, 0, "a straight ring-to-ring switch must never schedule a hide")

        // The stale `false` for ring A arriving afterwards must be a no-op
        // (guarded by ringExited's "is this still the tracked ring" check).
        sut.ringExited(.claude)
        XCTAssertEqual(sut.displayedServiceID, .chatgpt)
        XCTAssertEqual(scheduler.scheduleCount, 0, "a stale exit for the no-longer-hovered ring must not start a hide")
    }

    /// The other event ordering: old ring's `false` arrives, then the new
    /// ring's `true` — still must never dip through "hidden" or schedule a
    /// hide that would otherwise race the immediate re-show.
    func testSwitchingBetweenRingsExitThenEnterIsAlsoInstant() {
        let (sut, scheduler) = makeSUT()

        sut.ringEntered(.claude)
        sut.ringExited(.claude)
        XCTAssertEqual(scheduler.scheduleCount, 1, "momentarily no ring is hovered, so a hide is scheduled...")

        sut.ringEntered(.chatgpt)
        XCTAssertEqual(sut.displayedServiceID, .chatgpt, "...but immediately superseded by the new ring")
        XCTAssertEqual(scheduler.cancelCount, 1, "entering ring B must cancel ring A's pending hide")

        // The stale timer firing after the fact (race with the real
        // DispatchWorkItem/cancel) must not undo the switch.
        scheduler.fire()
        XCTAssertEqual(sut.displayedServiceID, .chatgpt)
    }

    // MARK: - card -> cursor leaves: card disappears after the delay

    func testLeavingTheCardHidesAfterGracePeriod() {
        let (sut, scheduler) = makeSUT()

        sut.ringEntered(.claude)
        sut.ringExited(.claude)
        sut.card(isHovering: true)
        XCTAssertEqual(sut.displayedServiceID, .claude)
        XCTAssertEqual(scheduler.cancelCount, 1)

        sut.card(isHovering: false)
        XCTAssertEqual(sut.displayedServiceID, .claude, "still visible immediately after leaving the card")
        XCTAssertEqual(scheduler.scheduleCount, 2, "leaving the card (with no ring hovered) schedules a new hide")

        scheduler.fire()
        XCTAssertNil(sut.displayedServiceID, "card must hide once the grace period elapses")
    }

    /// Returning to a ring while the card's own grace period is pending
    /// (e.g. cursor doubles back from the card to the ring) must cancel the
    /// pending hide, same as returning to the card would.
    func testReturningToRingDuringCardGracePeriodCancelsHide() {
        let (sut, scheduler) = makeSUT()

        sut.ringEntered(.claude)
        sut.ringExited(.claude) // schedules hide #1
        sut.card(isHovering: true) // cancels it
        sut.card(isHovering: false) // schedules hide #2 (cursor left the card too)
        XCTAssertEqual(scheduler.scheduleCount, 2)
        XCTAssertEqual(scheduler.cancelCount, 1)

        // Cursor doubles back onto the ring before hide #2 fires.
        sut.ringEntered(.claude)
        XCTAssertEqual(scheduler.cancelCount, 2)
        XCTAssertEqual(sut.displayedServiceID, .claude)

        scheduler.fire() // stale — must be a no-op since cursor is back on the ring
        XCTAssertEqual(sut.displayedServiceID, .claude)
    }

    // MARK: - Nothing was ever shown: no spurious scheduling

    func testNoHideScheduledWhenNothingWasDisplayed() {
        let (sut, scheduler) = makeSUT()

        sut.ringExited(.claude) // stray exit for a ring that was never entered
        XCTAssertNil(sut.displayedServiceID)
        XCTAssertEqual(scheduler.scheduleCount, 0)

        sut.card(isHovering: false)
        XCTAssertEqual(scheduler.scheduleCount, 0)
    }
}
