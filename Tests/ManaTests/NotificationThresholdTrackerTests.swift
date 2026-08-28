import XCTest
@testable import Mana

/// Coverage for `NotificationThresholdTracker` (ТЗ §5): crossing detection
/// ("снизу вверх"), the per-threshold-per-window cooldown, the cooldown
/// reset when a window's `resetsAt` changes, and the optional "Mana
/// restored" event. Pure logic — no `UNUserNotificationCenter`, no
/// `AppSettings`, no `@MainActor`.
final class NotificationThresholdTrackerTests: XCTestCase {
    private let resetA = Date(timeIntervalSince1970: 1_700_000_000)
    private let resetB = Date(timeIntervalSince1970: 1_700_100_000)

    private func usage(
        serviceID: ServiceID = .claude,
        sessionPercent: Double? = nil,
        sessionResetsAt: Date? = nil,
        weeklyPercent: Double? = nil,
        weeklyResetsAt: Date? = nil
    ) -> ServiceUsage {
        var windows: [UsageWindow] = []
        if let sessionPercent {
            windows.append(UsageWindow(kind: .session, label: "Session", usedPercent: sessionPercent, resetsAt: sessionResetsAt, periodDuration: 5 * 3600))
        }
        if let weeklyPercent {
            windows.append(UsageWindow(kind: .weekly, label: "Weekly", usedPercent: weeklyPercent, resetsAt: weeklyResetsAt, periodDuration: 7 * 86_400))
        }
        return ServiceUsage(serviceID: serviceID, plan: nil, windows: windows, refreshedAt: Date(), warning: nil)
    }

    // MARK: - Crossing detection ("снизу вверх")

    func testFiresOnceWhenCrossingUpward() {
        let tracker = NotificationThresholdTracker()

        // Below both thresholds: nothing fires.
        var crossings = tracker.evaluate(
            usage: usage(sessionPercent: 50, sessionResetsAt: resetA),
            sessionThresholds: [0.8, 0.95],
            weeklyThresholds: []
        )
        XCTAssertTrue(crossings.isEmpty)

        // Crosses 80% only.
        crossings = tracker.evaluate(
            usage: usage(sessionPercent: 82, sessionResetsAt: resetA),
            sessionThresholds: [0.8, 0.95],
            weeklyThresholds: []
        )
        XCTAssertEqual(crossings, [ThresholdCrossing(serviceID: .claude, isWeekly: false, kind: .thresholdReached(0.8), percent: 82)])

        // Staying above 80% (but below 95%) again: no repeat notification.
        crossings = tracker.evaluate(
            usage: usage(sessionPercent: 85, sessionResetsAt: resetA),
            sessionThresholds: [0.8, 0.95],
            weeklyThresholds: []
        )
        XCTAssertTrue(crossings.isEmpty)

        // Crosses 95% too.
        crossings = tracker.evaluate(
            usage: usage(sessionPercent: 96, sessionResetsAt: resetA),
            sessionThresholds: [0.8, 0.95],
            weeklyThresholds: []
        )
        XCTAssertEqual(crossings, [ThresholdCrossing(serviceID: .claude, isWeekly: false, kind: .thresholdReached(0.95), percent: 96)])
    }

    func testDoesNotFireBelowThreshold() {
        let tracker = NotificationThresholdTracker()
        let crossings = tracker.evaluate(
            usage: usage(sessionPercent: 79.9, sessionResetsAt: resetA),
            sessionThresholds: [0.8, 0.95],
            weeklyThresholds: []
        )
        XCTAssertTrue(crossings.isEmpty)
    }

    /// A window Mana observes for the first time already above a threshold
    /// (e.g. right after launch, mid-session) still notifies once — silently
    /// sitting above 80% forever without ever alerting would defeat ТЗ §5.
    func testFirstObservationAlreadyAboveThresholdFiresOnce() {
        let tracker = NotificationThresholdTracker()
        let crossings = tracker.evaluate(
            usage: usage(sessionPercent: 90, sessionResetsAt: resetA),
            sessionThresholds: [0.8, 0.95],
            weeklyThresholds: []
        )
        XCTAssertEqual(crossings, [ThresholdCrossing(serviceID: .claude, isWeekly: false, kind: .thresholdReached(0.8), percent: 90)])

        // And it does NOT fire again on the very next poll at the same level.
        let again = tracker.evaluate(
            usage: usage(sessionPercent: 91, sessionResetsAt: resetA),
            sessionThresholds: [0.8, 0.95],
            weeklyThresholds: []
        )
        XCTAssertTrue(again.isEmpty)
    }

    // MARK: - Cooldown: not more than one notification per threshold per window

    func testCooldownSuppressesRepeatFireWithinSameWindow() {
        let tracker = NotificationThresholdTracker()
        _ = tracker.evaluate(usage: usage(sessionPercent: 85, sessionResetsAt: resetA), sessionThresholds: [0.8], weeklyThresholds: [])

        // Many more polls within the same window (same resetsAt), still
        // above threshold — the threshold must not fire again.
        for percent in [86.0, 90.0, 99.0, 100.0] {
            let crossings = tracker.evaluate(usage: usage(sessionPercent: percent, sessionResetsAt: resetA), sessionThresholds: [0.8], weeklyThresholds: [])
            XCTAssertTrue(crossings.isEmpty, "threshold re-fired at \(percent)% within the same window")
        }
    }

    // MARK: - Reset when resetsAt changes (ТЗ §5 cooldown reset)

    func testResetsAtChangeClearsCooldown() {
        let tracker = NotificationThresholdTracker()
        _ = tracker.evaluate(usage: usage(sessionPercent: 85, sessionResetsAt: resetA), sessionThresholds: [0.8], weeklyThresholds: [])

        // New window (different resetsAt), usage starts low again.
        var crossings = tracker.evaluate(usage: usage(sessionPercent: 10, sessionResetsAt: resetB), sessionThresholds: [0.8], weeklyThresholds: [])
        XCTAssertTrue(crossings.isEmpty)

        // Crossing 80% again in the *new* window fires again.
        crossings = tracker.evaluate(usage: usage(sessionPercent: 81, sessionResetsAt: resetB), sessionThresholds: [0.8], weeklyThresholds: [])
        XCTAssertEqual(crossings, [ThresholdCrossing(serviceID: .claude, isWeekly: false, kind: .thresholdReached(0.8), percent: 81)])
    }

    func testNilResetsAtIsStableAcrossCalls() {
        // "Not started" windows (resetsAt == nil) shouldn't be treated as a
        // constantly-changing window (nil == nil), which would wrongly
        // reset the cooldown on every single poll.
        let tracker = NotificationThresholdTracker()
        _ = tracker.evaluate(usage: usage(sessionPercent: 85, sessionResetsAt: nil), sessionThresholds: [0.8], weeklyThresholds: [])
        let crossings = tracker.evaluate(usage: usage(sessionPercent: 90, sessionResetsAt: nil), sessionThresholds: [0.8], weeklyThresholds: [])
        XCTAssertTrue(crossings.isEmpty)
    }

    // MARK: - "Mana restored" (ТЗ §1.1 brand voice, optional per task brief)

    func testWindowResetAfterExhaustionFiresManaRestored() {
        let tracker = NotificationThresholdTracker()
        _ = tracker.evaluate(usage: usage(sessionPercent: 100, sessionResetsAt: resetA), sessionThresholds: [0.8, 0.95], weeklyThresholds: [])

        let crossings = tracker.evaluate(usage: usage(sessionPercent: 0, sessionResetsAt: resetB), sessionThresholds: [0.8, 0.95], weeklyThresholds: [])
        XCTAssertEqual(crossings, [ThresholdCrossing(serviceID: .claude, isWeekly: false, kind: .windowReset, percent: 0)])
    }

    func testWindowResetWithoutExhaustionDoesNotFireManaRestored() {
        let tracker = NotificationThresholdTracker()
        _ = tracker.evaluate(usage: usage(sessionPercent: 40, sessionResetsAt: resetA), sessionThresholds: [0.8, 0.95], weeklyThresholds: [])

        let crossings = tracker.evaluate(usage: usage(sessionPercent: 0, sessionResetsAt: resetB), sessionThresholds: [0.8, 0.95], weeklyThresholds: [])
        XCTAssertTrue(crossings.isEmpty)
    }

    func testFirstEverObservationDoesNotFireManaRestored() {
        // No prior window to have been "exhausted" — must not spuriously
        // fire on app launch just because there's no memory yet.
        let tracker = NotificationThresholdTracker()
        let crossings = tracker.evaluate(usage: usage(sessionPercent: 0, sessionResetsAt: resetA), sessionThresholds: [0.8, 0.95], weeklyThresholds: [])
        XCTAssertTrue(crossings.isEmpty)
    }

    // MARK: - Session and weekly windows are independent

    func testSessionAndWeeklyThresholdsAreIndependent() {
        let tracker = NotificationThresholdTracker()
        let crossings = tracker.evaluate(
            usage: usage(sessionPercent: 85, sessionResetsAt: resetA, weeklyPercent: 30, weeklyResetsAt: resetB),
            sessionThresholds: [0.8],
            weeklyThresholds: [0.8]
        )
        XCTAssertEqual(crossings, [ThresholdCrossing(serviceID: .claude, isWeekly: false, kind: .thresholdReached(0.8), percent: 85)])

        // Now the weekly window crosses too, independently of the session
        // window (which stays quiet, already fired).
        let crossings2 = tracker.evaluate(
            usage: usage(sessionPercent: 86, sessionResetsAt: resetA, weeklyPercent: 82, weeklyResetsAt: resetB),
            sessionThresholds: [0.8],
            weeklyThresholds: [0.8]
        )
        XCTAssertEqual(crossings2, [ThresholdCrossing(serviceID: .claude, isWeekly: true, kind: .thresholdReached(0.8), percent: 82)])
    }

    // MARK: - Missing window is skipped, not treated as 0%

    func testMissingWindowIsSkipped() {
        let tracker = NotificationThresholdTracker()
        let crossings = tracker.evaluate(
            usage: usage(sessionPercent: nil, weeklyPercent: nil),
            sessionThresholds: [0.8],
            weeklyThresholds: [0.8]
        )
        XCTAssertTrue(crossings.isEmpty)
    }

    // MARK: - reset(serviceID:)

    func testResetClearsMemoryForService() {
        let tracker = NotificationThresholdTracker()
        _ = tracker.evaluate(usage: usage(sessionPercent: 85, sessionResetsAt: resetA), sessionThresholds: [0.8], weeklyThresholds: [])

        tracker.reset(serviceID: .claude)

        // Same window, same percent — fires again since memory was cleared.
        let crossings = tracker.evaluate(usage: usage(sessionPercent: 85, sessionResetsAt: resetA), sessionThresholds: [0.8], weeklyThresholds: [])
        XCTAssertEqual(crossings, [ThresholdCrossing(serviceID: .claude, isWeekly: false, kind: .thresholdReached(0.8), percent: 85)])
    }
}
