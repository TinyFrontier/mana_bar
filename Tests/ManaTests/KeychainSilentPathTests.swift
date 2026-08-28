import Foundation
import XCTest
@testable import Mana

/// The silent (background-poll) Keychain path must always finish fast.
///
/// Background: the `claude` CLI keeps its login in a **legacy**, file-based
/// login-keychain item (`Claude Code-credentials`) owned by another
/// application. Reading such an item enters `securityd`'s interactive ACL
/// authorization path unless this process has been granted access — measured at
/// 8+ seconds per call on a machine without that grant, and sometimes not
/// returning at all. A background poll must therefore fail fast instead of
/// waiting: "the item is there, but this app may not read it silently" is
/// reported as "no credentials" for the silent provider, while the interactive
/// "Refresh Now" path stays free to raise the system dialog.
final class KeychainSilentPathTests: XCTestCase {
    private static let liveClaudeService = "Claude Code-credentials"

    /// Budget for anything on the silent path. Generous next to the ~30 ms the
    /// fixed code actually takes, tight next to the 8 s+ it used to take.
    private static let silentBudget: TimeInterval = 2

    private func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    private func makeStore(
        directory: TemporaryDirectory,
        keychain: StubKeychain,
        allowsKeychainInteraction: Bool
    ) -> ClaudeAuthStore {
        ClaudeAuthStore(
            environment: StaticEnvironment(["CLAUDE_CONFIG_DIR": directory.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            allowsDesktopFallback: false,
            allowsKeychainInteraction: allowsKeychainInteraction
        )
    }

    /// A Keychain holding a Claude login under the current user's account name,
    /// whose secret cannot be read without interaction — the exact shape of a
    /// machine where Mana has not been granted access to Claude Code's item.
    private func makeUnreadableKeychain(
        service: String,
        value: String = ProviderFixtures.claudeCredentials()
    ) -> StubKeychain {
        let keychain = StubKeychain(items: ["\(service)\u{1}\(NSUserName())": value])
        keychain.silentReadError = .accessDenied
        return keychain
    }

    // MARK: - Existence probe

    /// The launch-path probe answers from attributes alone: it must never ask
    /// for the secret, because asking is what can block.
    func testCredentialProbeNeverRequestsTheSecret() throws {
        let directory = TemporaryDirectory(self)
        let probe = makeStore(
            directory: directory,
            keychain: StubKeychain(),
            allowsKeychainInteraction: false
        )
        let service = try XCTUnwrap(probe.keychainServiceCandidates().first)
        let keychain = makeUnreadableKeychain(service: service)
        let store = makeStore(
            directory: directory,
            keychain: keychain,
            allowsKeychainInteraction: false
        )

        var present = false
        let duration = elapsed { present = store.hasCredentialMaterial() }

        XCTAssertTrue(present)
        XCTAssertLessThan(duration, Self.silentBudget)
        XCTAssertTrue(
            keychain.dataReads.isEmpty,
            "the existence probe requested the secret: \(keychain.dataReads)"
        )
    }

    // MARK: - Item present, silent read refused

    func testUnreadableItemIsNotReportedAsACredential() throws {
        let directory = TemporaryDirectory(self)
        let probe = makeStore(
            directory: directory,
            keychain: StubKeychain(),
            allowsKeychainInteraction: false
        )
        let service = try XCTUnwrap(probe.keychainServiceCandidates().first)
        let keychain = makeUnreadableKeychain(service: service)
        let store = makeStore(
            directory: directory,
            keychain: keychain,
            allowsKeychainInteraction: false
        )

        // The probe still sees the item — the login does exist on this machine.
        XCTAssertTrue(store.hasCredentialMaterial())

        var credentials: [ClaudeCredential] = []
        let duration = elapsed { credentials = store.loadCredentials() }

        XCTAssertTrue(
            credentials.isEmpty,
            "an item that cannot be read silently must not become a usable credential"
        )
        XCTAssertLessThan(duration, Self.silentBudget)
        XCTAssertFalse(keychain.dataReads.isEmpty, "no read was attempted at all")
        XCTAssertTrue(
            keychain.dataReads.allSatisfy { !$0.allowInteraction },
            "the silent store asked for an interactive read: \(keychain.dataReads)"
        )
    }

    /// The same item read by the interactive store still works — the manual
    /// "Refresh Now" path is the one allowed to raise the system dialog.
    func testInteractiveStoreStillReadsTheSameItem() throws {
        let directory = TemporaryDirectory(self)
        let probe = makeStore(
            directory: directory,
            keychain: StubKeychain(),
            allowsKeychainInteraction: false
        )
        let service = try XCTUnwrap(probe.keychainServiceCandidates().first)
        let keychain = makeUnreadableKeychain(
            service: service,
            value: ProviderFixtures.claudeCredentials(accessToken: "keychain-token")
        )
        let store = makeStore(
            directory: directory,
            keychain: keychain,
            allowsKeychainInteraction: true
        )

        let credentials = store.loadCredentials()
        XCTAssertEqual(credentials.count, 1)
        XCTAssertEqual(credentials.first?.oauth.accessToken, "keychain-token")
        XCTAssertTrue(keychain.dataReads.contains { $0.allowInteraction })
    }

    func testSilentProviderFailsFastAsNotLoggedIn() async throws {
        let directory = TemporaryDirectory(self)
        let probe = makeStore(
            directory: directory,
            keychain: StubKeychain(),
            allowsKeychainInteraction: false
        )
        let service = try XCTUnwrap(probe.keychainServiceCandidates().first)
        let http = StubHTTPClient([])
        let provider = ClaudeProvider(
            authStore: makeStore(
                directory: directory,
                keychain: makeUnreadableKeychain(service: service),
                allowsKeychainInteraction: false
            ),
            usageClient: ClaudeUsageClient(http: http)
        )

        let start = Date()
        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .notLoggedIn)
        XCTAssertLessThan(Date().timeIntervalSince(start), Self.silentBudget)
        XCTAssertTrue(http.sentRequests.isEmpty, "a request was sent without a credential")
    }

    // MARK: - Live diagnostic

    /// Opt-in measurement against this machine's real Keychain, for verifying
    /// the fix where the problem actually reproduces:
    ///
    /// ```
    /// MANA_KEYCHAIN_DIAG=1 xcodebuild -project Mana.xcodeproj -scheme Mana test \
    ///   -destination 'platform=macOS' \
    ///   -only-testing:ManaTests/KeychainSilentPathTests/testLiveSilentPathIsFast
    /// ```
    ///
    /// Prints timings only — never a token, never a Keychain value.
    func testLiveSilentPathIsFast() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MANA_KEYCHAIN_DIAG"] == "1",
            "set MANA_KEYCHAIN_DIAG=1 to measure the real Keychain"
        )

        let keychain = KeychainStore()
        let account = NSUserName()

        var exists: Bool?
        let probeTime = elapsed {
            exists = keychain.genericPasswordExists(
                service: Self.liveClaudeService,
                account: account
            )
        }
        print(String(
            format: "[kcdiag] genericPasswordExists -> %@ in %.1f ms",
            String(describing: exists), probeTime * 1000
        ))

        var readOutcome = "nil"
        let readTime = elapsed {
            do {
                let value = try keychain.readGenericPassword(
                    service: Self.liveClaudeService,
                    account: account,
                    allowInteraction: false
                )
                readOutcome = value == nil ? "no item" : "value read"
            } catch {
                readOutcome = "\(error)"
            }
        }
        print(String(
            format: "[kcdiag] silent readGenericPassword -> %@ in %.1f ms",
            readOutcome, readTime * 1000
        ))

        let store = ClaudeAuthStore(allowsKeychainInteraction: false)

        var present = false
        let materialTime = elapsed { present = store.hasCredentialMaterial() }
        print(String(
            format: "[kcdiag] hasCredentialMaterial -> %@ in %.1f ms",
            present ? "true" : "false", materialTime * 1000
        ))

        var count = 0
        let loadTime = elapsed { count = store.loadCredentials().count }
        print(String(
            format: "[kcdiag] loadCredentials -> %d credential(s) in %.1f ms",
            count, loadTime * 1000
        ))

        XCTAssertLessThan(probeTime, Self.silentBudget, "existence probe is slow")
        XCTAssertLessThan(readTime, Self.silentBudget, "silent Keychain read is slow")
        XCTAssertLessThan(materialTime, Self.silentBudget, "hasCredentialMaterial is slow")
        XCTAssertLessThan(loadTime, Self.silentBudget, "silent credential load is slow")
    }
}
