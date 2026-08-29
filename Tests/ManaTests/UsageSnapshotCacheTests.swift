import XCTest
@testable import Mana

/// Coverage for the disk-cache DTO layer (research doc §9 п.7): the
/// `ServiceUsageDTO`/`UsageWindowDTO` round-trip, and `UsageSnapshotCache`
/// itself reading back exactly what it wrote, in a throwaway temp directory —
/// never the real `~/Library/Application Support/Mana/`.
final class UsageSnapshotCacheTests: XCTestCase {
    private func makeUsage(
        serviceID: ServiceID = .claude,
        plan: String? = "Max 20x",
        warning: String? = nil
    ) -> ServiceUsage {
        ServiceUsage(
            serviceID: serviceID,
            plan: plan,
            windows: [
                UsageWindow(
                    kind: .session,
                    label: "Current session",
                    usedPercent: 73,
                    resetsAt: Date(timeIntervalSince1970: 1_800_003_000),
                    periodDuration: 5 * 3600
                ),
                UsageWindow(
                    kind: .weekly,
                    label: "All models",
                    usedPercent: 7,
                    resetsAt: Date(timeIntervalSince1970: 1_800_400_000),
                    periodDuration: 7 * 86_400
                ),
                UsageWindow(
                    kind: .modelWeekly("Sonnet"),
                    label: "Sonnet",
                    usedPercent: 42,
                    resetsAt: nil, // "Not started" (research doc §9.2 п.5) must round-trip too.
                    periodDuration: nil
                ),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000),
            warning: warning
        )
    }

    // MARK: - DTO round-trip (pure, no disk)

    func testServiceUsageDTORoundTripsThroughJSON() throws {
        let original = makeUsage()
        let dto = ServiceUsageDTO(original)

        let data = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(ServiceUsageDTO.self, from: data)

        XCTAssertEqual(decoded, dto)
        XCTAssertEqual(decoded.asServiceUsage, original)
    }

    func testServiceUsageDTORoundTripPreservesEveryWindowKindAndOptionalFields() {
        let usage = makeUsage(warning: "partial fetch")
        let roundTripped = ServiceUsageDTO(usage).asServiceUsage

        XCTAssertEqual(roundTripped.serviceID, .claude)
        XCTAssertEqual(roundTripped.plan, "Max 20x")
        XCTAssertEqual(roundTripped.warning, "partial fetch")
        XCTAssertEqual(roundTripped.windows.count, 3)
        XCTAssertEqual(roundTripped.window(.session)?.usedPercent, 73)
        XCTAssertEqual(roundTripped.window(.weekly)?.usedPercent, 7)
        let sonnet = roundTripped.windows.first { if case .modelWeekly("Sonnet") = $0.kind { return true }; return false }
        XCTAssertEqual(sonnet?.usedPercent, 42)
        XCTAssertNil(sonnet?.resetsAt, "nil resetsAt (\"Not started\") must round-trip as nil, not as some default date")
    }

    func testServiceUsageDTORoundTripsNilPlanAndWarning() {
        let usage = makeUsage(plan: nil, warning: nil)
        let roundTripped = ServiceUsageDTO(usage).asServiceUsage
        XCTAssertNil(roundTripped.plan)
        XCTAssertNil(roundTripped.warning)
    }

    // MARK: - UsageSnapshotCache (real disk I/O, temp directory)

    func testCacheSaveThenLoadReturnsEquivalentUsage() {
        let tempDir = TemporaryDirectory(self)
        let cache = UsageSnapshotCache(directory: URL(fileURLWithPath: tempDir.path))
        let usage = makeUsage()

        cache.save(usage)
        let loaded = cache.load()

        XCTAssertEqual(loaded[.claude], usage)
    }

    func testCacheLoadOnMissingFileReturnsEmptyNotAnError() {
        let tempDir = TemporaryDirectory(self)
        let cache = UsageSnapshotCache(directory: URL(fileURLWithPath: tempDir.path).appendingPathComponent("does-not-exist"))
        XCTAssertEqual(cache.load(), [:])
    }

    func testCacheLoadOnCorruptFileReturnsEmptyNotAnError() {
        let tempDir = TemporaryDirectory(self)
        let directoryURL = URL(fileURLWithPath: tempDir.path)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: directoryURL.appendingPathComponent("usage-cache.json"))

        let cache = UsageSnapshotCache(directory: directoryURL)
        XCTAssertEqual(cache.load(), [:])
    }

    /// Saving one provider's snapshot must not disturb another's already on
    /// disk — `AppDelegate` wires one shared cache instance across both
    /// providers, each fetching and saving independently (ТЗ §11).
    func testCacheSavingOneServiceLeavesTheOtherIntact() {
        let tempDir = TemporaryDirectory(self)
        let cache = UsageSnapshotCache(directory: URL(fileURLWithPath: tempDir.path))
        let claudeUsage = makeUsage(serviceID: .claude)
        let chatgptUsage = makeUsage(serviceID: .chatgpt, plan: "Plus")

        cache.save(claudeUsage)
        cache.save(chatgptUsage)
        let loaded = cache.load()

        XCTAssertEqual(loaded[.claude], claudeUsage)
        XCTAssertEqual(loaded[.chatgpt], chatgptUsage)
    }

    /// A second `save` for the same service replaces, rather than
    /// duplicates, its entry.
    func testCacheSaveOverwritesPreviousSnapshotForSameService() {
        let tempDir = TemporaryDirectory(self)
        let cache = UsageSnapshotCache(directory: URL(fileURLWithPath: tempDir.path))
        cache.save(makeUsage(plan: "Pro"))
        let updated = makeUsage(plan: "Max 20x")
        cache.save(updated)

        XCTAssertEqual(cache.load()[.claude], updated)
        XCTAssertEqual(cache.load().count, 1)
    }

    /// A brand-new `UsageSnapshotCache` instance (fresh app launch) must read
    /// back exactly what an earlier instance wrote (previous app run) —
    /// nothing in the type may hold state only in memory.
    func testCachePersistsAcrossSeparateCacheInstances() {
        let tempDir = TemporaryDirectory(self)
        let directoryURL = URL(fileURLWithPath: tempDir.path)
        let usage = makeUsage()

        UsageSnapshotCache(directory: directoryURL).save(usage)
        let reopened = UsageSnapshotCache(directory: directoryURL)

        XCTAssertEqual(reopened.load()[.claude], usage)
    }
}
