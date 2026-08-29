import XCTest
@testable import Mana

/// Credential discovery for Claude. Every case runs against a temporary
/// directory and an in-memory Keychain — never the developer's real `~/.claude`
/// or login keychain.
final class ClaudeAuthStoreTests: XCTestCase {
    private func makeStore(
        directory: TemporaryDirectory,
        keychain: StubKeychain = StubKeychain(),
        environment extra: [String: String] = [:],
        now: Date = Date(timeIntervalSince1970: 1_787_900_000)
    ) -> ClaudeAuthStore {
        var values = ["CLAUDE_CONFIG_DIR": directory.path]
        values.merge(extra) { _, new in new }
        return ClaudeAuthStore(
            environment: StaticEnvironment(values),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            // The Desktop store gets the same stubbed Keychain and a home
            // directory that holds no Claude Desktop config.
            desktop: ClaudeDesktopAuthStore(
                files: LocalTextFileAccessor(),
                keychain: keychain,
                homeDirectory: { directory.url },
                now: { now }
            ),
            now: { now }
        )
    }

    // MARK: - Files

    func testDecodesCredentialsFile() throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let store = makeStore(directory: directory)

        let credentials = store.loadCredentials()
        XCTAssertEqual(credentials.count, 1)
        let credential = try XCTUnwrap(credentials.first)
        XCTAssertEqual(credential.oauth.accessToken, "fake-access-token")
        XCTAssertEqual(credential.oauth.refreshToken, "fake-refresh-token")
        XCTAssertEqual(credential.oauth.scopes, ["user:inference", "user:profile"])
        XCTAssertEqual(credential.source, .file(path: directory.path + "/.credentials.json"))
        XCTAssertTrue(credential.hasUsableAccessToken)
        XCTAssertTrue(credential.canRefresh)
    }

    func testMissingFileAndEmptyKeychainMeansNoCredentials() {
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory)
        XCTAssertTrue(store.loadCredentials().isEmpty)
        XCTAssertFalse(store.hasCredentialMaterial())
    }

    func testMalformedCredentialsFileIsIgnoredRatherThanCrashing() {
        let directory = TemporaryDirectory(self)
        directory.write("{ not json", to: ".credentials.json")
        let store = makeStore(directory: directory)
        XCTAssertTrue(store.loadCredentials().isEmpty)
    }

    func testCredentialsWithoutAccessTokenAreIgnored() {
        let directory = TemporaryDirectory(self)
        directory.write(#"{"claudeAiOauth":{"refreshToken":"only-refresh"}}"#, to: ".credentials.json")
        let store = makeStore(directory: directory)
        XCTAssertTrue(store.loadCredentials().isEmpty)
    }

    func testHexEncodedCredentialsAreDecoded() throws {
        let directory = TemporaryDirectory(self)
        let json = #"{"claudeAiOauth":{"accessToken":"hex-token"}}"#
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        directory.write(hex, to: ".credentials.json")

        let store = makeStore(directory: directory)
        XCTAssertEqual(store.loadCredentials().first?.oauth.accessToken, "hex-token")
    }

    // MARK: - Source order

    func testKeychainWinsOverTheFileButTheFileStaysAsAFallback() throws {
        let directory = TemporaryDirectory(self)
        directory.write(
            ProviderFixtures.claudeCredentials(accessToken: "file-token"),
            to: ".credentials.json"
        )
        let store0 = makeStore(directory: directory)
        let service = try XCTUnwrap(store0.keychainServiceCandidates().first)
        let keychain = StubKeychain(items: [
            "\(service)\u{1}": ProviderFixtures.claudeCredentials(accessToken: "keychain-token"),
        ])
        let store = makeStore(directory: directory, keychain: keychain)

        let credentials = store.loadCredentials()
        XCTAssertEqual(credentials.count, 2)
        XCTAssertEqual(credentials[0].oauth.accessToken, "keychain-token")
        XCTAssertEqual(credentials[1].oauth.accessToken, "file-token")
    }

    func testKeychainServiceNameIsSuffixedForACustomConfigDirectory() {
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory)
        let candidates = store.keychainServiceCandidates()
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates[0].hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(candidates.last, "Claude Code-credentials")
    }

    func testDefaultKeychainServiceNameWithoutAnOverride() {
        let store = ClaudeAuthStore(
            environment: StaticEnvironment(),
            files: LocalTextFileAccessor(),
            keychain: StubKeychain()
        )
        XCTAssertEqual(store.keychainServiceCandidates(), ["Claude Code-credentials"])
        XCTAssertEqual(store.credentialsPath(), "~/.claude/.credentials.json")
    }

    // MARK: - Environment token

    func testEnvironmentTokenIsLastAndMarkedInferenceOnly() throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let store = makeStore(
            directory: directory,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "setup-token"]
        )

        let credentials = store.loadCredentials()
        let last = try XCTUnwrap(credentials.last)
        XCTAssertEqual(last.source, .environment)
        XCTAssertEqual(last.oauth.accessToken, "setup-token")
        XCTAssertTrue(last.inferenceOnly)
        XCTAssertFalse(last.canRefresh)
        // An inference-only token can never read usage.
        XCTAssertEqual(store.liveUsageAvailability(last), .missingProfileScope)
        // …and it must not displace the real login.
        XCTAssertEqual(credentials.first?.source, .file(path: directory.path + "/.credentials.json"))
    }

    // MARK: - Scope

    func testScopesWithoutUserProfileCannotReadUsage() {
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory)
        let credential = ClaudeCredential(
            oauth: ClaudeOAuth(accessToken: "t", scopes: ["user:inference"]),
            source: .file(path: "/tmp/x"),
            inferenceOnly: false
        )
        XCTAssertEqual(store.liveUsageAvailability(credential), .missingProfileScope)
    }

    func testAbsentScopesAreTreatedAsAllowed() {
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory)
        let credential = ClaudeCredential(
            oauth: ClaudeOAuth(accessToken: "t", scopes: nil),
            source: .file(path: "/tmp/x"),
            inferenceOnly: false
        )
        XCTAssertEqual(store.liveUsageAvailability(credential), .available)
    }

    // MARK: - Expiry

    func testNeedsRefreshUsesEpochMilliseconds() {
        let now = Date(timeIntervalSince1970: 1_787_900_000)
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory, now: now)

        let comfortablyValid = ClaudeOAuth(expiresAt: (now.timeIntervalSince1970 + 3600) * 1000)
        let aboutToExpire = ClaudeOAuth(expiresAt: (now.timeIntervalSince1970 + 60) * 1000)
        XCTAssertFalse(store.needsRefresh(comfortablyValid))
        XCTAssertTrue(store.needsRefresh(aboutToExpire))
        // No expiry recorded: nothing to act on.
        XCTAssertFalse(store.needsRefresh(ClaudeOAuth()))
    }

    // MARK: - Rotation write-back

    func testRotationIsWrittenBackToTheFileItCameFrom() throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let store = makeStore(directory: directory)

        var credential = try XCTUnwrap(store.loadCredentials().first)
        credential.oauth.accessToken = "rotated-access"
        credential.oauth.refreshToken = "rotated-refresh"

        XCTAssertTrue(store.persistRotation(credential, expectedRefreshToken: "fake-refresh-token"))
        let reloaded = try XCTUnwrap(store.loadCredentials().first)
        XCTAssertEqual(reloaded.oauth.accessToken, "rotated-access")
        XCTAssertEqual(reloaded.oauth.refreshToken, "rotated-refresh")
        // Fields the CLI owns survive the round-trip.
        XCTAssertEqual(reloaded.oauth.subscriptionType, "max")
    }

    func testRotationPreservesKeysManaDoesNotModel() throws {
        let directory = TemporaryDirectory(self)
        let original = """
        {
          "futureTopLevelKey": "keep-me",
          "claudeAiOauth": {
            "accessToken": "old-access",
            "refreshToken": "fake-refresh-token",
            "scopes": ["user:profile"],
            "unmodelledField": 7
          }
        }
        """
        directory.write(original, to: ".credentials.json")
        let store = makeStore(directory: directory)

        var credential = try XCTUnwrap(store.loadCredentials().first)
        credential.oauth.accessToken = "new-access"
        XCTAssertTrue(store.persistRotation(credential, expectedRefreshToken: "fake-refresh-token"))

        let stored = try XCTUnwrap(directory.read(".credentials.json"))
        let object = try XCTUnwrap(ProviderParse.jsonObject(Data(stored.utf8)))
        XCTAssertEqual(object["futureTopLevelKey"] as? String, "keep-me")
        let oauth = try XCTUnwrap(object["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["unmodelledField"] as? Int, 7)
    }

    /// A hex-encoded credential blob is a format Mana can read but must not
    /// rewrite as plain JSON — the write is skipped instead.
    func testHexEncodedSourceIsNotRewrittenAsJSON() throws {
        let directory = TemporaryDirectory(self)
        let json = #"{"claudeAiOauth":{"accessToken":"hex-token","refreshToken":"hex-refresh"}}"#
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        directory.write(hex, to: ".credentials.json")
        let store = makeStore(directory: directory)

        var credential = try XCTUnwrap(store.loadCredentials().first)
        credential.oauth.accessToken = "rotated"
        XCTAssertFalse(store.persistRotation(credential, expectedRefreshToken: "hex-refresh"))
        XCTAssertEqual(directory.read(".credentials.json"), hex)
    }

    func testRotationIsSkippedSilentlyWhenTheCLIRotatedFirst() throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        let store = makeStore(directory: directory)
        var credential = try XCTUnwrap(store.loadCredentials().first)

        // The `claude` CLI rewrites the file between our read and our write.
        directory.write(
            ProviderFixtures.claudeCredentials(
                accessToken: "cli-access",
                refreshToken: "cli-refresh"
            ),
            to: ".credentials.json"
        )
        credential.oauth.accessToken = "ours"

        XCTAssertFalse(store.persistRotation(credential, expectedRefreshToken: "fake-refresh-token"))
        let reloaded = try XCTUnwrap(store.loadCredentials().first)
        XCTAssertEqual(reloaded.oauth.accessToken, "cli-access")
        XCTAssertEqual(reloaded.oauth.refreshToken, "cli-refresh")
    }

    /// The Keychain item belongs to the `claude` CLI. A `SecItemUpdate` from
    /// Mana's binary rebuilds its ACL around Mana and locks `/usr/bin/security`
    /// — the path the CLI reads its own token through — out of it, leaving the
    /// user with a keychain-password prompt on every CLI read. Mana reads that
    /// item; it never writes it, refresh or no refresh.
    func testKeychainSourceIsNeverWrittenBack() throws {
        let directory = TemporaryDirectory(self)
        let store0 = makeStore(directory: directory)
        let service = try XCTUnwrap(store0.keychainServiceCandidates().first)
        let stored = ProviderFixtures.claudeCredentials(accessToken: "keychain-token")
        let keychain = StubKeychain(items: ["\(service)\u{1}": stored])
        let store = makeStore(directory: directory, keychain: keychain)

        var credential = try XCTUnwrap(store.loadCredentials().first)
        XCTAssertEqual(credential.source.label, "keychain")
        // Mana may still run the refresh itself — it just keeps the result to
        // this session instead of writing it back.
        XCTAssertTrue(credential.canRefresh)

        credential.oauth.accessToken = "rotated-access"
        XCTAssertFalse(store.persistRotation(credential, expectedRefreshToken: "fake-refresh-token"))
        XCTAssertEqual(keychain.value(service: service), stored)
    }

    func testDesktopAndEnvironmentSourcesAreNeverWrittenBack() {
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory)
        for source in [ClaudeCredentialSource.desktop, .environment] {
            let credential = ClaudeCredential(
                oauth: ClaudeOAuth(accessToken: "t", refreshToken: "r"),
                source: source,
                inferenceOnly: false
            )
            XCTAssertFalse(store.persistRotation(credential, expectedRefreshToken: "r"))
            XCTAssertFalse(credential.canRefresh)
        }
    }

    // MARK: - Local detection

    func testHasCredentialMaterialSeesTheFileWithoutReadingAnySecret() {
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory)
        XCTAssertFalse(store.hasCredentialMaterial())

        directory.write(ProviderFixtures.claudeCredentials(), to: ".credentials.json")
        XCTAssertTrue(store.hasCredentialMaterial())
    }

    func testHasCredentialMaterialSeesAKeychainItem() throws {
        let directory = TemporaryDirectory(self)
        let store0 = makeStore(directory: directory)
        let service = try XCTUnwrap(store0.keychainServiceCandidates().first)
        let keychain = StubKeychain(items: ["\(service)\u{1}": "irrelevant"])
        XCTAssertTrue(makeStore(directory: directory, keychain: keychain).hasCredentialMaterial())
    }

    // MARK: - Keychain access-denied diagnosis

    /// The core case: an item is present (attributes probe succeeds) but the
    /// silent read is denied — this is "logged in, permission not granted
    /// yet", not "not logged in".
    func testKeychainAccessIsDeniedWhenItemExistsButSilentReadIsRefused() throws {
        let directory = TemporaryDirectory(self)
        let probe = makeStore(directory: directory)
        let service = try XCTUnwrap(probe.keychainServiceCandidates().first)
        let keychain = StubKeychain(items: [
            "\(service)\u{1}\(NSUserName())": ProviderFixtures.claudeCredentials(),
        ])
        keychain.silentReadError = .accessDenied

        let store = ClaudeAuthStore(
            environment: StaticEnvironment(["CLAUDE_CONFIG_DIR": directory.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            allowsDesktopFallback: false,
            allowsKeychainInteraction: false
        )

        XCTAssertTrue(store.keychainAccessIsDenied())
        XCTAssertTrue(store.loadCredentials().isEmpty)
    }

    /// The existence probe can fail to answer at all — it loses the silent gate
    /// to an open interactive dialog, or `securityd` refuses the attributes
    /// query. "Could not tell" is not "not there": treating it as absence is
    /// what made a logged-in user see "Источник токена не найден" instead of
    /// the one-time-grant prompt. The silent read still separates the two.
    func testKeychainAccessIsDeniedWhenTheExistenceProbeCannotAnswer() throws {
        let directory = TemporaryDirectory(self)
        let probe = makeStore(directory: directory)
        let service = try XCTUnwrap(probe.keychainServiceCandidates().first)
        let keychain = StubKeychain(items: [
            "\(service)\u{1}\(NSUserName())": ProviderFixtures.claudeCredentials(),
        ])
        keychain.silentReadError = .accessDenied
        keychain.existenceProbeIsInconclusive = true

        let store = ClaudeAuthStore(
            environment: StaticEnvironment(["CLAUDE_CONFIG_DIR": directory.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            allowsDesktopFallback: false,
            allowsKeychainInteraction: false
        )

        XCTAssertTrue(store.keychainAccessIsDenied())
    }

    /// No Keychain item at all (nor a locked-but-present one): must not be
    /// misreported as an access-denied case.
    func testKeychainAccessIsNotDeniedWhenNoItemExists() {
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory)
        XCTAssertFalse(store.keychainAccessIsDenied())
    }

    /// A readable item (interactive store, or one Mana already has permission
    /// for) must never be diagnosed as access-denied, even though it exists.
    func testKeychainAccessIsNotDeniedWhenTheItemIsReadable() throws {
        let directory = TemporaryDirectory(self)
        let probe = makeStore(directory: directory)
        let service = try XCTUnwrap(probe.keychainServiceCandidates().first)
        let keychain = StubKeychain(items: [
            "\(service)\u{1}\(NSUserName())": ProviderFixtures.claudeCredentials(),
        ])
        let store = ClaudeAuthStore(
            environment: StaticEnvironment(["CLAUDE_CONFIG_DIR": directory.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            allowsDesktopFallback: false,
            allowsKeychainInteraction: false
        )

        XCTAssertFalse(store.keychainAccessIsDenied())
    }
}
