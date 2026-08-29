import XCTest
@testable import Mana

/// Coverage for `AppSettings`' defaults and `UserDefaults` round-trip
/// persistence (ТЗ §6). Every test uses a private `UserDefaults` suite —
/// never `.standard` — so this suite can never read or write this machine's
/// real Mana preferences (`AppSettings.shared` is not touched anywhere
/// here).
@MainActor
final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.manabar.Mana.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults (ТЗ §6)

    func testDefaults() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.serviceOrder, ServiceID.allCases)
        XCTAssertEqual(settings.enabledServiceIDs, Set(ServiceID.allCases))
        XCTAssertEqual(settings.panelEdge, .right)
        XCTAssertEqual(settings.verticalPosition, .center)
        XCTAssertEqual(settings.verticalOffset, 0)
        XCTAssertNil(settings.preferredScreenID)
        XCTAssertEqual(settings.refreshInterval, .twoMinutes)
        XCTAssertEqual(settings.warningThreshold, 0.5)
        XCTAssertEqual(settings.criticalThreshold, 0.8)
        XCTAssertEqual(settings.sessionNotificationThresholds, [0.8, 0.95])
        XCTAssertEqual(settings.weeklyNotificationThresholds, [0.8, 0.95])
        XCTAssertEqual(settings.appearDelayMs, 120)
        XCTAssertEqual(settings.disappearDelayMs, 350)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.showPercentUnderRings)
        XCTAssertFalse(settings.hidePanelOverFullScreen)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertEqual(settings.effectiveServiceOrder, ServiceID.allCases)
    }

    // MARK: - Vertical offset slider bound (ТЗ §6 "свободное смещение")

    func testVerticalOffsetRangeIsSymmetric() {
        XCTAssertEqual(AppSettings.verticalOffsetRange, -400...400)
    }

    // MARK: - Round trip (ТЗ §6: persisted via UserDefaults)

    func testRoundTripPersistsEveryField() {
        let first = AppSettings(defaults: defaults)

        first.serviceOrder = [.chatgpt, .claude]
        first.enabledServiceIDs = [.claude]
        first.panelEdge = .left
        first.verticalPosition = .top
        first.verticalOffset = -137.5
        first.preferredScreenID = 42
        first.refreshInterval = .fiveMinutes
        first.warningThreshold = 0.3
        first.criticalThreshold = 0.6
        first.sessionNotificationThresholds = [0.7, 0.9]
        first.weeklyNotificationThresholds = [0.6, 0.85]
        first.appearDelayMs = 200
        first.disappearDelayMs = 500
        first.showPercentUnderRings = false
        first.hidePanelOverFullScreen = true
        first.hasCompletedOnboarding = true

        // A fresh instance backed by the *same* suite should load exactly
        // what the first instance wrote — this is the actual persistence
        // contract (not just "the property changed in memory").
        let second = AppSettings(defaults: defaults)

        XCTAssertEqual(second.serviceOrder, [.chatgpt, .claude])
        XCTAssertEqual(second.enabledServiceIDs, [.claude])
        XCTAssertEqual(second.panelEdge, .left)
        XCTAssertEqual(second.verticalPosition, .top)
        XCTAssertEqual(second.verticalOffset, -137.5)
        XCTAssertEqual(second.preferredScreenID, 42)
        XCTAssertEqual(second.refreshInterval, .fiveMinutes)
        XCTAssertEqual(second.warningThreshold, 0.3)
        XCTAssertEqual(second.criticalThreshold, 0.6)
        XCTAssertEqual(second.sessionNotificationThresholds, [0.7, 0.9])
        XCTAssertEqual(second.weeklyNotificationThresholds, [0.6, 0.85])
        XCTAssertEqual(second.appearDelayMs, 200)
        XCTAssertEqual(second.disappearDelayMs, 500)
        XCTAssertFalse(second.showPercentUnderRings)
        XCTAssertTrue(second.hidePanelOverFullScreen)
        XCTAssertTrue(second.hasCompletedOnboarding)
        XCTAssertEqual(second.effectiveServiceOrder, [.claude])
    }

    func testLaunchAtLoginRoundTrips() {
        let first = AppSettings(defaults: defaults)
        first.launchAtLogin = true

        let second = AppSettings(defaults: defaults)
        XCTAssertTrue(second.launchAtLogin)
    }

    // MARK: - Service reordering (ТЗ §6 "порядок")

    func testMoveServiceReorders() {
        let settings = AppSettings(defaults: defaults)
        settings.serviceOrder = [.claude, .chatgpt]

        settings.moveService(.chatgpt, by: -1)
        XCTAssertEqual(settings.serviceOrder, [.chatgpt, .claude])

        // Already at the front: moving further up is a no-op, not a crash.
        settings.moveService(.chatgpt, by: -1)
        XCTAssertEqual(settings.serviceOrder, [.chatgpt, .claude])

        settings.moveService(.chatgpt, by: 1)
        XCTAssertEqual(settings.serviceOrder, [.claude, .chatgpt])

        // Already at the back: moving further down is a no-op.
        settings.moveService(.chatgpt, by: 1)
        XCTAssertEqual(settings.serviceOrder, [.claude, .chatgpt])
    }

    // MARK: - effectiveServiceOrder (ТЗ §6: "координатор не опрашивает выключенные")

    func testEffectiveServiceOrderFiltersDisabled() {
        let settings = AppSettings(defaults: defaults)
        settings.serviceOrder = [.chatgpt, .claude]
        settings.enabledServiceIDs = [.claude]

        XCTAssertEqual(settings.effectiveServiceOrder, [.claude])

        settings.enabledServiceIDs = []
        XCTAssertEqual(settings.effectiveServiceOrder, [])
    }

    // MARK: - Independent suites never cross-contaminate

    func testTwoInstancesWithDifferentSuitesAreIndependent() {
        let otherSuiteName = "com.manabar.Mana.tests.\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherSuiteName)
        defer { otherDefaults?.removePersistentDomain(forName: otherSuiteName) }

        let a = AppSettings(defaults: defaults)
        a.criticalThreshold = 0.99

        let b = AppSettings(defaults: otherDefaults!)
        XCTAssertEqual(b.criticalThreshold, 0.8, "a second, differently-suited instance must not see a's writes")
    }
}
