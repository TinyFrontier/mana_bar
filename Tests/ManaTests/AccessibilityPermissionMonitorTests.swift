import XCTest
@testable import Mana

/// Coverage for the live Accessibility-grant watcher (ТЗ §7, §11).
///
/// The bug these lock down: `AXIsProcessTrusted()` was read once at launch,
/// so granting permission while Mana was running changed nothing until a
/// restart — the onboarding kept saying "Not granted" and `HotZoneMonitor`
/// was never re-armed. The contract is now: poll while missing, publish the
/// transition, and *stop polling the moment it's granted* (a permanently
/// running timer would be a real cost in an always-on menu-bar app).
///
/// Every test injects its own probe closure; none of them touch
/// `AccessibilityPermissionMonitor.shared`, which reads this machine's real
/// TCC state.
@MainActor
final class AccessibilityPermissionMonitorTests: XCTestCase {
    /// Flippable stand-in for `AXIsProcessTrusted()`, counting reads so tests
    /// can assert the poll actually stopped rather than just looking idle.
    private final class Probe {
        var trusted = false
        private(set) var readCount = 0

        func read() -> Bool {
            readCount += 1
            return trusted
        }
    }

    func testSeedsFromTheProbeAtInit() {
        let probe = Probe()
        probe.trusted = true
        let monitor = AccessibilityPermissionMonitor(pollInterval: 0.01, probe: probe.read)
        XCTAssertTrue(monitor.isTrusted)
        XCTAssertFalse(monitor.isPolling)
    }

    func testRecheckPublishesTheTransitionAndStopsPolling() {
        let probe = Probe()
        let monitor = AccessibilityPermissionMonitor(pollInterval: 0.01, probe: probe.read)
        XCTAssertFalse(monitor.isTrusted)

        monitor.startPollingIfNeeded()
        XCTAssertTrue(monitor.isPolling, "must keep watching while permission is missing")

        probe.trusted = true
        XCTAssertTrue(monitor.recheck())
        XCTAssertTrue(monitor.isTrusted)
        XCTAssertFalse(monitor.isPolling, "granted: the timer must retire itself")
    }

    func testDoesNotStartPollingWhenAlreadyGranted() {
        let probe = Probe()
        probe.trusted = true
        let monitor = AccessibilityPermissionMonitor(pollInterval: 0.01, probe: probe.read)

        monitor.startPollingIfNeeded()
        XCTAssertFalse(monitor.isPolling, "nothing to wait for — no timer at all")
    }

    func testStartPollingIsIdempotent() {
        let probe = Probe()
        let monitor = AccessibilityPermissionMonitor(pollInterval: 0.01, probe: probe.read)

        monitor.startPollingIfNeeded()
        monitor.startPollingIfNeeded()
        monitor.startPollingIfNeeded()
        XCTAssertTrue(monitor.isPolling)

        monitor.stopPolling()
        XCTAssertFalse(monitor.isPolling, "one stop must clear it — repeated starts can't stack timers")
    }

    /// The timer really runs on the main run loop, notices a grant on its own
    /// (no `recheck()` from the test), and then goes quiet.
    func testPollNoticesAGrantOnItsOwnAndThenStopsReading() {
        let probe = Probe()
        let monitor = AccessibilityPermissionMonitor(pollInterval: 0.02, probe: probe.read)
        monitor.startPollingIfNeeded()

        let granted = expectation(description: "monitor observes the grant")
        probe.trusted = true
        // Poll the observable state from the test side rather than reaching
        // into the timer, so this asserts the published value, not plumbing.
        let watchdog = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            Task { @MainActor in
                if monitor.isTrusted {
                    timer.invalidate()
                    granted.fulfill()
                }
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        wait(for: [granted], timeout: 2)

        XCTAssertFalse(monitor.isPolling)
        let readsAfterGrant = probe.readCount
        // Several poll intervals' worth of run loop with no further reads.
        let idle = expectation(description: "run loop keeps turning")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { idle.fulfill() }
        wait(for: [idle], timeout: 2)
        XCTAssertEqual(probe.readCount, readsAfterGrant, "a granted monitor must do no further work")
    }
}
