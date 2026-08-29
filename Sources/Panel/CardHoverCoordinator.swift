import Combine
import Foundation

/// Pure state machine governing whether `PanelView`'s detail-card flyout
/// should be visible, kept free of SwiftUI view code so it's unit-testable
/// in isolation (`CardHoverCoordinatorTests`).
///
/// Bug this fixes: the card used to disappear the instant the cursor left a
/// ring's small hit-test bounds, before it could ever reach the card itself
/// — there's a real gap to cross (`PanelLayoutMetrics.cardGap` + the card's
/// own offset) between the ring and the card, and the card carries
/// interactive content (the error-state "Grant access" button) that was
/// consequently unreachable.
///
/// Two independent hover sources feed this type: whichever ring currently
/// has the cursor (`ringEntered`/`ringExited`) and whether the cursor is
/// over the card itself (`card(isHovering:)`). Losing hover from *both*
/// sources doesn't hide immediately — it starts a short, cancellable grace
/// timer (`hideDelay`, ~250ms) so a cursor mid-crossing the ring→card gap
/// has time to land on the card before it's judged "gone". Gaining hover on
/// a *different* ring, by contrast, switches `displayedServiceID`
/// immediately with no grace delay — there's no gap to cross there, and a
/// delay would just make the card feel laggy when skimming between rings.
final class CardHoverCoordinator: ObservableObject {
    /// The service whose card should currently be shown, or nil when no
    /// card should be visible. `PanelView` observes this directly.
    @Published private(set) var displayedServiceID: ServiceID?

    /// Grace period between losing all hover and the card actually hiding
    /// (design-spec.md §6.3 pairs with the 150ms fade `PanelView` already
    /// animates `displayedServiceID` changes with).
    var hideDelay: TimeInterval = 0.25

    /// Schedules `action` after `hideDelay` and returns an opaque token
    /// `cancelScheduledHide` can use to abort it. Defaults to a real
    /// main-queue timer; tests substitute a synchronous fake (capturing the
    /// action instead of running it) so grace-period transitions can be
    /// driven deterministically without sleeping — see
    /// `CardHoverCoordinatorTests`.
    var scheduleHide: (TimeInterval, @escaping () -> Void) -> Any = { delay, action in
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }
    /// Cancels a token previously returned by `scheduleHide`.
    var cancelScheduledHide: (Any) -> Void = { token in
        (token as? DispatchWorkItem)?.cancel()
    }

    private var hoveredRingID: ServiceID?
    private var isCardHovered = false
    private var pendingHideToken: Any?

    init() {}

    /// The cursor entered ring `id`. Shows its card immediately — including
    /// when a *different* service's card was already showing or was
    /// grace-pending a hide — with no delay either way.
    func ringEntered(_ id: ServiceID) {
        hoveredRingID = id
        cancelPendingHide()
        setDisplayed(id)
    }

    /// The cursor left ring `id`. Ignored if `id` isn't the ring currently
    /// tracked as hovered — guards against a stale/out-of-order event, e.g.
    /// ring A's `onHover(false)` arriving after ring B's `onHover(true)`
    /// already moved focus on.
    func ringExited(_ id: ServiceID) {
        guard hoveredRingID == id else { return }
        hoveredRingID = nil
        reconsider()
    }

    /// The cursor entered/left the detail card itself.
    func card(isHovering: Bool) {
        isCardHovered = isHovering
        if isHovering {
            cancelPendingHide()
        } else {
            reconsider()
        }
    }

    // MARK: - Private

    /// Called whenever a hover source might have dropped to zero. Only
    /// starts the grace-period hide when *both* sources currently agree
    /// nothing is hovered, there's something displayed to hide, and a hide
    /// isn't already pending.
    private func reconsider() {
        guard hoveredRingID == nil, !isCardHovered else { return }
        guard displayedServiceID != nil, pendingHideToken == nil else { return }

        pendingHideToken = scheduleHide(hideDelay) { [weak self] in
            guard let self else { return }
            self.pendingHideToken = nil
            // Re-check at fire time, not just at schedule time: hover may
            // have returned to either source in the interim.
            guard self.hoveredRingID == nil, !self.isCardHovered else { return }
            self.setDisplayed(nil)
        }
    }

    private func cancelPendingHide() {
        if let pendingHideToken {
            cancelScheduledHide(pendingHideToken)
        }
        pendingHideToken = nil
    }

    private func setDisplayed(_ id: ServiceID?) {
        guard displayedServiceID != id else { return }
        displayedServiceID = id
    }
}
