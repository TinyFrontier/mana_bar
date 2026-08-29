import XCTest
@testable import Mana

/// Coverage for the pure, UI-framework-free logic behind the panel:
/// hot-zone hit-test geometry (`HotZoneGeometry`), threshold-based ring
/// color selection (`UsageLevel`), and the two reset-time string flavors
/// (`ResetFormatter`) used by `DetailCardView` (ТЗ §3.4, §8).
final class PanelLogicTests: XCTestCase {
    // MARK: HotZoneGeometry (ТЗ §3.1, §8: O(1) hit test)

    func testHotZoneGeometryHitTest() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panelHeight: CGFloat = PanelLayoutMetrics.panelHeight(serviceCount: 2)
        let rect = HotZoneGeometry.rect(screenFrame: screenFrame, panelHeight: panelHeight, width: 3, edge: .right)

        // Hugs the right edge, vertically centered, exactly `width` wide.
        XCTAssertEqual(rect.width, 3)
        XCTAssertEqual(rect.maxX, screenFrame.maxX)
        XCTAssertEqual(rect.midY, screenFrame.midY)

        let justInside = CGPoint(x: screenFrame.maxX - 1, y: screenFrame.midY)
        let justOutsideLeft = CGPoint(x: screenFrame.maxX - 10, y: screenFrame.midY)
        let justOutsideVertically = CGPoint(x: screenFrame.maxX - 1, y: screenFrame.midY + panelHeight)

        XCTAssertTrue(HotZoneGeometry.contains(justInside, in: rect))
        XCTAssertFalse(HotZoneGeometry.contains(justOutsideLeft, in: rect))
        XCTAssertFalse(HotZoneGeometry.contains(justOutsideVertically, in: rect))

        let leftEdgeRect = HotZoneGeometry.rect(screenFrame: screenFrame, panelHeight: panelHeight, width: 3, edge: .left)
        XCTAssertEqual(leftEdgeRect.minX, screenFrame.minX)
    }

    // MARK: HotZoneMonitor start/stop (ТЗ §7, §11)

    /// Regression: `start()` used to bail out whenever `AXIsProcessTrusted()`
    /// was false, so hover-to-show stayed dead for the whole run even after
    /// the user granted permission. It now always attempts the install (mouse
    /// -move events aren't gated on the Accessibility grant — only key events
    /// are) and is safe to re-call, which is how `AppDelegate` re-arms it
    /// live.
    func testHotZoneMonitorStartIsIdempotentAndRearmable() {
        final class Installs {
            var global = 0
            var local = 0
            var removals = 0
        }
        let installs = Installs()

        let monitor = HotZoneMonitor()
        monitor.installGlobalMonitor = { _ in
            installs.global += 1
            return NSObject()
        }
        monitor.installLocalMonitor = { _ in
            installs.local += 1
            return NSObject()
        }
        monitor.removeMonitor = { _ in installs.removals += 1 }

        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(monitor.start())
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(installs.global, 1)
        XCTAssertEqual(installs.local, 1)

        // Re-calling while running must not stack monitors.
        XCTAssertTrue(monitor.start())
        XCTAssertEqual(installs.global, 1)
        XCTAssertEqual(installs.local, 1)

        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(installs.removals, 2)

        // Re-armable after a stop (the post-grant path).
        XCTAssertTrue(monitor.start())
        XCTAssertEqual(installs.global, 2)
        monitor.stop()
    }

    /// A failed install is reported honestly, so `AppDelegate` keeps watching
    /// instead of assuming hover tracking is live.
    func testHotZoneMonitorReportsFailedInstall() {
        let monitor = HotZoneMonitor()
        monitor.installGlobalMonitor = { _ in nil }
        monitor.installLocalMonitor = { _ in nil }
        monitor.removeMonitor = { _ in }

        XCTAssertFalse(monitor.start())
        XCTAssertFalse(monitor.isRunning)
    }

    // MARK: UsageLevel (design-spec.md §2.2: ≤50 green, 50–80 yellow, >80 red)

    func testUsageLevelThresholds() {
        XCTAssertEqual(UsageLevel.forPercent(0), .healthy)
        XCTAssertEqual(UsageLevel.forPercent(50), .healthy)
        XCTAssertEqual(UsageLevel.forPercent(50.1), .warning)
        XCTAssertEqual(UsageLevel.forPercent(80), .warning)
        XCTAssertEqual(UsageLevel.forPercent(80.1), .critical)
        XCTAssertEqual(UsageLevel.forPercent(100), .critical)

        // Custom thresholds (mirrors AppSettings.warningThreshold/criticalThreshold).
        let tight = UsageThresholds(warning: 0.2, critical: 0.4)
        XCTAssertEqual(UsageLevel.forPercent(15, thresholds: tight), .healthy)
        XCTAssertEqual(UsageLevel.forPercent(25, thresholds: tight), .warning)
        XCTAssertEqual(UsageLevel.forPercent(45, thresholds: tight), .critical)
    }

    // MARK: ResetFormatter — relative (session window, ТЗ §3.4: "Resets in 51 min")

    func testResetFormatterRelative() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(ResetFormatter.relative(resetsAt: nil, now: now), "Not started")
        XCTAssertEqual(ResetFormatter.relative(resetsAt: now.addingTimeInterval(-60), now: now), "Resets now")
        XCTAssertEqual(ResetFormatter.relative(resetsAt: now.addingTimeInterval(51 * 60), now: now), "Resets in 51 min")
        XCTAssertEqual(
            ResetFormatter.relative(resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60), now: now),
            "Resets in 2 h 14 min"
        )
        XCTAssertEqual(ResetFormatter.relative(resetsAt: now.addingTimeInterval(3 * 3600), now: now), "Resets in 3 h")

        // Exhausted-message flavor drops the "Resets " prefix (design-spec.md §8.1).
        XCTAssertEqual(ResetFormatter.relativeShort(resetsAt: now.addingTimeInterval(51 * 60), now: now), "in 51 min")
        XCTAssertEqual(ResetFormatter.relativeShort(resetsAt: nil, now: now), "soon")
    }

    // MARK: ResetFormatter — absolute (weekly window, ТЗ §3.4: "Resets Thu 12:00 AM")

    func testResetFormatterAbsolute() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 10, minute: 0))!

        // "Next Thursday at midnight" — constructed via weekday matching so
        // the expected weekday text is true by construction, not a
        // hardcoded date coincidence.
        var thursdayMidnight = DateComponents()
        thursdayMidnight.weekday = 5 // 1 = Sunday ... 5 = Thursday
        thursdayMidnight.hour = 0
        thursdayMidnight.minute = 0
        let resetsAt = calendar.nextDate(after: now, matching: thursdayMidnight, matchingPolicy: .nextTime)!

        XCTAssertEqual(ResetFormatter.absolute(resetsAt: resetsAt, now: now, calendar: calendar), "Resets Thu 12:00 AM")
        XCTAssertEqual(ResetFormatter.absolute(resetsAt: nil, now: now, calendar: calendar), "Not started")
    }
}
