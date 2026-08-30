import XCTest
@testable import Mana

/// Opt-in smoke test against the **real** APIs, using whatever CLI login exists
/// on the current machine. Skipped by default — the rest of the suite must stay
/// hermetic — and enabled with:
///
/// ```
/// MANA_LIVE_SMOKE=1 xcodebuild -project Mana.xcodeproj -scheme Mana test \
///   -destination 'platform=macOS'
/// ```
///
/// It prints only percentages, window labels and reset times. Tokens, headers
/// and raw response bodies are never printed, logged, or written anywhere —
/// the same rule the production code follows (research doc §9.2 п.9).
///
/// Note: reading Claude Code's Keychain item from a test binary can raise the
/// macOS "allow access" dialog, which is why this never runs unattended.
final class LiveSmokeTests: XCTestCase {
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MANA_LIVE_SMOKE"] == "1"
    }

    func testClaudeLiveUsage() async throws {
        try XCTSkipUnless(isEnabled, "set MANA_LIVE_SMOKE=1 to run the live smoke test")
        try await smoke(ClaudeProvider(), name: "Claude")
    }

    func testChatGPTLiveUsage() async throws {
        try XCTSkipUnless(isEnabled, "set MANA_LIVE_SMOKE=1 to run the live smoke test")
        try await smoke(ChatGPTProvider(), name: "ChatGPT")
    }

    func testCursorLiveUsage() async throws {
        try XCTSkipUnless(isEnabled, "set MANA_LIVE_SMOKE=1 to run the live smoke test")
        try await smoke(CursorProvider(), name: "Cursor")
    }

    private func smoke(_ provider: some UsageProvider, name: String) async throws {
        let hasCredentials = await provider.hasLocalCredentials()
        try XCTSkipUnless(hasCredentials, "no local \(name) CLI login on this machine")

        let usage = try await provider.fetchUsage()
        print("[live] \(name) plan=\(usage.plan ?? "n/a") windows=\(usage.windows.count)")
        for window in usage.windows {
            let reset = window.resetsAt.map(ISO8601.string(from:)) ?? "not started"
            print("[live] \(name) \(window.label): \(window.usedPercent)% used, resets \(reset)")
        }

        XCTAssertFalse(usage.windows.isEmpty, "\(name) returned no usage windows")
        for window in usage.windows {
            XCTAssertTrue(
                (0...100).contains(window.usedPercent),
                "\(name) \(window.label) percentage out of range"
            )
        }
    }
}
