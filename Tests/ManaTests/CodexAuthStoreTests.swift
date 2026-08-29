import XCTest
@testable import Mana

/// Credential discovery for ChatGPT via the Codex CLI. Runs against a temporary
/// `CODEX_HOME` and an in-memory Keychain — never the real `~/.codex`.
final class CodexAuthStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_900_000)

    private func makeStore(
        directory: TemporaryDirectory,
        keychain: StubKeychain = StubKeychain()
    ) -> CodexAuthStore {
        CodexAuthStore(
            environment: StaticEnvironment(["CODEX_HOME": directory.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            now: { self.now }
        )
    }

    /// A JWT whose payload carries only `exp` — the shape the store reads to
    /// decide whether a refresh is due.
    private func jwt(expiringAt expiry: Date) -> String {
        let payload = #"{"exp":\#(Int(expiry.timeIntervalSince1970))}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    // MARK: - auth.json

    func testDecodesAuthFile() throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let store = makeStore(directory: directory)

        let credential = try XCTUnwrap(store.loadCredentials().first)
        XCTAssertEqual(credential.auth.tokens?.accessToken, "header.payload.signature")
        XCTAssertEqual(credential.auth.tokens?.refreshToken, "fake-refresh-token")
        XCTAssertEqual(credential.accountID, "acct-123")
        XCTAssertEqual(credential.source, .file(path: directory.path + "/auth.json"))
        XCTAssertTrue(credential.hasUsableAccessToken)
        XCTAssertFalse(credential.isAPIKeyOnly)
    }

    func testDefaultPathsAreProbedWhenCodexHomeIsUnset() {
        let store = CodexAuthStore(
            environment: StaticEnvironment(),
            files: LocalTextFileAccessor(),
            keychain: StubKeychain()
        )
        XCTAssertEqual(
            store.authPaths(),
            ["~/.config/codex/auth.json", "~/.codex/auth.json"]
        )
    }

    // MARK: - API-key-only auth.json

    func testAPIKeyOnlyAuthIsAValidCredentialNotAParseFailure() throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuthAPIKeyOnly, to: "auth.json")
        let store = makeStore(directory: directory)

        // It parses, and it is kept as a candidate…
        let credential = try XCTUnwrap(store.loadCredentials().first)
        XCTAssertEqual(credential.auth.apiKey, "sk-fake-api-key")
        XCTAssertNil(credential.auth.tokens?.accessToken)
        // …but it cannot serve the usage endpoint.
        XCTAssertFalse(credential.hasUsableAccessToken)
        XCTAssertTrue(credential.isAPIKeyOnly)
    }

    func testAPIKeyOnlyAuthReportsMissingScopeRatherThanNotLoggedIn() async {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuthAPIKeyOnly, to: "auth.json")
        let provider = ChatGPTProvider(
            authStore: makeStore(directory: directory),
            usageClient: CodexUsageClient(http: StubHTTPClient([])),
            now: { self.now }
        )

        await XCTAssertUsageErrorAsync(try await provider.fetchUsage(), .missingScope)
    }

    func testEmptyAuthFileIsNotACredential() {
        let directory = TemporaryDirectory(self)
        directory.write("{}", to: "auth.json")
        XCTAssertTrue(makeStore(directory: directory).loadCredentials().isEmpty)
    }

    func testMalformedAuthFileIsIgnored() {
        let directory = TemporaryDirectory(self)
        directory.write("<html>not json</html>", to: "auth.json")
        XCTAssertTrue(makeStore(directory: directory).loadCredentials().isEmpty)
    }

    // MARK: - Keychain fallback

    func testKeychainIsUsedAfterTheFiles() throws {
        let directory = TemporaryDirectory(self)
        let keychain = StubKeychain(items: [
            "Codex Auth\u{1}": ProviderFixtures.codexAuth(accessToken: "keychain.token.sig"),
        ])
        let store = makeStore(directory: directory, keychain: keychain)

        let credential = try XCTUnwrap(store.loadCredentials().first)
        XCTAssertEqual(credential.source, .keychain)
        XCTAssertEqual(credential.auth.tokens?.accessToken, "keychain.token.sig")
        XCTAssertTrue(store.hasCredentialMaterial())
    }

    func testFilesTakePrecedenceOverTheKeychain() {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(accessToken: "file.token.sig"), to: "auth.json")
        let keychain = StubKeychain(items: [
            "Codex Auth\u{1}": ProviderFixtures.codexAuth(accessToken: "keychain.token.sig"),
        ])
        let credentials = makeStore(directory: directory, keychain: keychain).loadCredentials()

        XCTAssertEqual(credentials.map(\.source), [
            .file(path: directory.path + "/auth.json"),
            .keychain,
        ])
    }

    // MARK: - Expiry

    func testRefreshIsDueFromTheAccessTokenJWTExpiry() {
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory)

        let fresh = CodexAuth(tokens: CodexTokens(
            accessToken: jwt(expiringAt: now.addingTimeInterval(3600))
        ))
        let expiring = CodexAuth(tokens: CodexTokens(
            accessToken: jwt(expiringAt: now.addingTimeInterval(60))
        ))
        XCTAssertFalse(store.needsRefresh(fresh))
        XCTAssertTrue(store.needsRefresh(expiring))
    }

    func testUnreadableExpiryFallsBackToTokenAge() {
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory)
        let old = ISO8601.string(from: now.addingTimeInterval(-9 * 24 * 3600))
        let recent = ISO8601.string(from: now.addingTimeInterval(-3600))

        XCTAssertTrue(store.needsRefresh(CodexAuth(
            tokens: CodexTokens(accessToken: "opaque"),
            lastRefresh: old
        )))
        XCTAssertFalse(store.needsRefresh(CodexAuth(
            tokens: CodexTokens(accessToken: "opaque"),
            lastRefresh: recent
        )))
        // A brand-new login with neither signal must not be force-refreshed:
        // that is what replays a spent refresh token.
        XCTAssertFalse(store.needsRefresh(CodexAuth(
            tokens: CodexTokens(accessToken: "opaque")
        )))
    }

    // MARK: - Rotation write-back

    func testRotationIsWrittenBackToTheFile() throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let store = makeStore(directory: directory)

        var credential = try XCTUnwrap(store.loadCredentials().first)
        credential.auth.tokens?.accessToken = "rotated.access.sig"
        credential.auth.tokens?.refreshToken = "rotated-refresh"

        XCTAssertTrue(store.persistRotation(credential, expectedRefreshToken: "fake-refresh-token"))
        let reloaded = try XCTUnwrap(store.loadCredentials().first)
        XCTAssertEqual(reloaded.auth.tokens?.accessToken, "rotated.access.sig")
        XCTAssertEqual(reloaded.auth.tokens?.refreshToken, "rotated-refresh")
        XCTAssertEqual(reloaded.auth.tokens?.accountID, "acct-123")
    }

    /// A real `auth.json` carries keys Mana does not model (`auth_mode`, and
    /// whatever `codex` adds next). Re-encoding only our own fields would delete
    /// them and could break the user's CLI login.
    func testRotationPreservesKeysManaDoesNotModel() throws {
        let directory = TemporaryDirectory(self)
        let original = """
        {
          "auth_mode": "chatgpt",
          "future_field": { "nested": true },
          "tokens": {
            "access_token": "old.access.sig",
            "refresh_token": "fake-refresh-token",
            "account_id": "acct-123",
            "unmodelled_token_field": "keep-me"
          },
          "last_refresh": "2026-08-27T10:00:00Z"
        }
        """
        directory.write(original, to: "auth.json")
        let store = makeStore(directory: directory)

        var credential = try XCTUnwrap(store.loadCredentials().first)
        credential.auth.tokens?.accessToken = "new.access.sig"
        XCTAssertTrue(store.persistRotation(credential, expectedRefreshToken: "fake-refresh-token"))

        let stored = try XCTUnwrap(directory.read("auth.json"))
        let object = try XCTUnwrap(ProviderParse.jsonObject(Data(stored.utf8)))
        XCTAssertEqual(object["auth_mode"] as? String, "chatgpt")
        XCTAssertEqual((object["future_field"] as? [String: Any])?["nested"] as? Bool, true)
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["access_token"] as? String, "new.access.sig")
        XCTAssertEqual(tokens["unmodelled_token_field"] as? String, "keep-me")
    }

    func testRotationIsSkippedSilentlyWhenTheCLIRotatedFirst() throws {
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let store = makeStore(directory: directory)
        var credential = try XCTUnwrap(store.loadCredentials().first)

        directory.write(
            ProviderFixtures.codexAuth(
                accessToken: "cli.access.sig",
                refreshToken: "cli-refresh"
            ),
            to: "auth.json"
        )
        credential.auth.tokens?.accessToken = "ours.access.sig"

        XCTAssertFalse(store.persistRotation(credential, expectedRefreshToken: "fake-refresh-token"))
        let reloaded = try XCTUnwrap(store.loadCredentials().first)
        XCTAssertEqual(reloaded.auth.tokens?.accessToken, "cli.access.sig")
    }

    /// The `Codex Auth` Keychain item belongs to the `codex` CLI. Writing it
    /// from Mana's binary rebuilds its ACL around Mana and locks the CLI out of
    /// its own credentials, so the write-back is file-only (see
    /// `CodexAuthSource.allowsRotationWriteBack`).
    func testKeychainSourceIsNeverWrittenBack() throws {
        let directory = TemporaryDirectory(self)
        let stored = ProviderFixtures.codexAuth()
        let keychain = StubKeychain(items: ["Codex Auth\u{1}": stored])
        let store = makeStore(directory: directory, keychain: keychain)

        var credential = try XCTUnwrap(store.loadCredentials().first)
        XCTAssertEqual(credential.source, .keychain)
        credential.auth.tokens?.accessToken = "rotated.access.sig"

        XCTAssertFalse(store.persistRotation(credential, expectedRefreshToken: "fake-refresh-token"))
        XCTAssertEqual(keychain.value(service: "Codex Auth"), stored)
    }

    func testRotationWriteFailureIsSwallowed() throws {
        // Root ignores the directory mode this test relies on to fail the write.
        try XCTSkipIf(getuid() == 0)
        let directory = TemporaryDirectory(self)
        directory.write(ProviderFixtures.codexAuth(), to: "auth.json")
        let store = makeStore(directory: directory)
        var credential = try XCTUnwrap(store.loadCredentials().first)
        credential.auth.tokens?.accessToken = "rotated.access.sig"

        // An atomic write needs a temporary file next to the target, so a
        // read-only directory fails the write while leaving the read intact.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }

        XCTAssertFalse(store.persistRotation(credential, expectedRefreshToken: "fake-refresh-token"))
    }

    // MARK: - Silent/interactive Keychain split (mirrors ClaudeAuthStore)

    /// A silent store (`allowsKeychainInteraction: false`) must never ask the
    /// stub for an interactive read — the same guarantee
    /// `KeychainSilentPathTests` verifies for Claude.
    func testSilentStoreNeverRequestsAnInteractiveKeychainRead() {
        let directory = TemporaryDirectory(self)
        let keychain = StubKeychain(items: [
            "Codex Auth\u{1}": ProviderFixtures.codexAuth(),
        ])
        let store = CodexAuthStore(
            environment: StaticEnvironment(["CODEX_HOME": directory.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            allowsKeychainInteraction: false,
            now: { self.now }
        )

        let credential = store.loadKeychainCredential()
        XCTAssertNotNil(credential)
        XCTAssertTrue(
            keychain.dataReads.allSatisfy { !$0.allowInteraction },
            "the silent store asked for an interactive read: \(keychain.dataReads)"
        )
    }

    /// The interactive store (the default) still reads the same item — only
    /// the silent one is restricted.
    func testInteractiveStoreStillReadsTheKeychainItem() {
        let directory = TemporaryDirectory(self)
        let keychain = StubKeychain(items: [
            "Codex Auth\u{1}": ProviderFixtures.codexAuth(accessToken: "keychain.token.sig"),
        ])
        let store = makeStore(directory: directory, keychain: keychain)

        XCTAssertEqual(store.loadKeychainCredential()?.auth.tokens?.accessToken, "keychain.token.sig")
        XCTAssertTrue(keychain.dataReads.contains { $0.allowInteraction })
    }

    /// The core access-denied case: the item is present (attributes probe
    /// succeeds) but the silent read is refused — "logged in via Keychain,
    /// permission not granted yet", the same distinction
    /// `ClaudeAuthStore.keychainAccessIsDenied()` makes.
    func testKeychainAccessIsDeniedWhenItemExistsButSilentReadIsRefused() {
        let directory = TemporaryDirectory(self)
        let keychain = StubKeychain(items: [
            "Codex Auth\u{1}": ProviderFixtures.codexAuth(),
        ])
        keychain.silentReadError = .accessDenied
        let store = CodexAuthStore(
            environment: StaticEnvironment(["CODEX_HOME": directory.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            allowsKeychainInteraction: false,
            now: { self.now }
        )

        XCTAssertTrue(store.keychainAccessIsDenied())
        XCTAssertNil(store.loadKeychainCredential())
    }

    /// No Keychain item at all: must not be misreported as access-denied.
    func testKeychainAccessIsNotDeniedWhenNoItemExists() {
        let directory = TemporaryDirectory(self)
        let store = makeStore(directory: directory)
        XCTAssertFalse(store.keychainAccessIsDenied())
    }
    /// Mirrors `ClaudeAuthStoreTests`: a probe that cannot answer is not
    /// evidence that the item is absent.
    func testKeychainAccessIsDeniedWhenTheExistenceProbeCannotAnswer() {
        let directory = TemporaryDirectory(self)
        let keychain = StubKeychain(items: ["Codex Auth\u{1}": ProviderFixtures.codexAuth()])
        keychain.silentReadError = .accessDenied
        keychain.existenceProbeIsInconclusive = true
        let store = CodexAuthStore(
            environment: StaticEnvironment(["CODEX_HOME": directory.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            allowsKeychainInteraction: false
        )

        XCTAssertTrue(store.keychainAccessIsDenied())
    }
}
