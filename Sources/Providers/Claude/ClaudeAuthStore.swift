import CryptoKit
import Foundation

/// The OAuth blob Claude Code stores, in both its Keychain item and its
/// `.credentials.json` file (both use these exact camelCase keys).
struct ClaudeOAuth: Codable, Equatable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    /// Expiry in epoch **milliseconds**, as written by Claude Code.
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]?
}

struct ClaudeCredentialsFile: Codable, Equatable, Sendable {
    var claudeAiOauth: ClaudeOAuth?
}

/// Where one credential came from. Also decides whether Mana may write a
/// rotated token back to it.
enum ClaudeCredentialSource: Equatable, Sendable {
    case keychain(service: String, account: String?)
    case file(path: String)
    /// Claude Desktop's Electron cache — read-only by design.
    case desktop
    /// `CLAUDE_CODE_OAUTH_TOKEN`, typically a `claude setup-token` token.
    case environment

    /// Log-safe kind name. Never carries a token; the Keychain service name is
    /// deliberately not included either.
    var label: String {
        switch self {
        case .keychain: return "keychain"
        case .file: return "file"
        case .desktop: return "desktop"
        case .environment: return "environment"
        }
    }

    /// Whether Mana may run its own refresh against this source. Desktop and
    /// environment credentials are owned by another process and must never be
    /// rotated by Mana (research doc §9.3: rotating Claude Desktop's token
    /// would log the user out of Desktop).
    var allowsRefresh: Bool {
        switch self {
        case .keychain, .file: return true
        case .desktop, .environment: return false
        }
    }

    /// Whether a rotated token may be written back to this source.
    ///
    /// The file, yes — it is a plain `~/.claude/.credentials.json` Mana can
    /// rewrite without side effects. The **Keychain item, no**, even though
    /// Mana can read it and ТЗ §4.2 originally asked for a write-back to the
    /// same source: `Claude Code-credentials` is a legacy login-keychain item
    /// owned by the `claude` CLI, and a `SecItemUpdate` from a different
    /// binary makes macOS rebuild the item's ACL / partition list around the
    /// writer. `/usr/bin/security` — the path the CLI reads its own token
    /// through — drops out of the trusted list, and every later CLI read
    /// raises the "security wants to access key" password prompt until the
    /// user re-grants it by hand. Skipping the write-back costs one extra
    /// refresh round-trip per expiry; the alternative breaks the user's CLI.
    var allowsRotationWriteBack: Bool {
        switch self {
        case .file: return true
        case .keychain, .desktop, .environment: return false
        }
    }

    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

struct ClaudeCredential: Equatable, Sendable {
    var oauth: ClaudeOAuth
    var source: ClaudeCredentialSource
    /// `true` for an inference-only token (env var): it can run the model but
    /// the usage endpoint rejects it.
    var inferenceOnly: Bool
    /// The raw document this credential was read from, so a rotation is merged
    /// back onto it instead of replacing it with only the fields Mana models.
    var rawText: String?

    var hasUsableAccessToken: Bool {
        oauth.accessToken?.nilIfBlank != nil
    }

    /// Whether Mana may perform its own refresh with this credential. Never for
    /// Claude Desktop: its refresh token is not even read, so that Desktop's own
    /// session survives (research doc §9.3).
    var canRefresh: Bool {
        source.allowsRefresh && oauth.refreshToken?.nilIfBlank != nil
    }
}

/// Discovers the OAuth logins that already exist on this machine, in the fixed
/// order ТЗ §4.1 prescribes: Claude Code Keychain entry → `~/.claude/.credentials.json`
/// (or `$CLAUDE_CONFIG_DIR/.credentials.json`) → optionally Claude Desktop.
///
/// Nothing is cached: every fetch re-reads the sources, because the `claude` CLI
/// rotates tokens out-of-band (ТЗ §4.2).
struct ClaudeAuthStore: Sendable {
    static let usageScope = "user:profile"
    private static let defaultHome = "~/.claude"
    private static let credentialFileName = ".credentials.json"
    private static let keychainServicePrefix = "Claude Code"
    private static let keychainServiceSuffix = "-credentials"
    /// Refresh once the access token is within this window of expiry.
    static let refreshWindow: TimeInterval = 5 * 60

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainReading
    var desktop: ClaudeDesktopAuthStore
    var allowsDesktopFallback: Bool
    /// Whether reading Claude Code's Keychain item may raise the macOS
    /// "allow access" dialog.
    ///
    /// The item belongs to Claude Code, so the first read from Mana's binary
    /// prompts once; "Always Allow" makes every later read silent. Left `true`
    /// so a fresh install works without the user hunting for a button. A store
    /// layer that would rather keep background polls strictly silent can build
    /// its polling provider with `false` and an interactive one for the manual
    /// "Refresh now" path.
    var allowsKeychainInteraction: Bool
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainReading = KeychainStore(),
        desktop: ClaudeDesktopAuthStore? = nil,
        allowsDesktopFallback: Bool = true,
        allowsKeychainInteraction: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.desktop = desktop ?? ClaudeDesktopAuthStore(files: files, keychain: keychain, now: now)
        self.allowsDesktopFallback = allowsDesktopFallback
        self.allowsKeychainInteraction = allowsKeychainInteraction
        self.now = now
    }

    // MARK: - Discovery

    /// Every credential currently readable, in probe order. The provider walks
    /// this list and falls through to the next entry on an auth-expiry error, so
    /// a fresh `claude` login is picked up whichever source it landed in.
    func loadCredentials(allowDesktopInteraction: Bool = false) -> [ClaudeCredential] {
        var candidates: [ClaudeCredential] = []
        if let keychainCredential = loadKeychainCredential() { candidates.append(keychainCredential) }
        if let fileCredential = loadFileCredential() { candidates.append(fileCredential) }

        // Only reach for Claude Desktop when no CLI login can read usage — it is
        // an optional, read-only source and can require a Keychain prompt.
        let hasLiveCLILogin = candidates.contains {
            $0.hasUsableAccessToken && liveUsageAvailability($0) == .available
        }
        if allowsDesktopFallback, !hasLiveCLILogin,
           let desktopOAuth = desktop.load(allowInteraction: allowDesktopInteraction).oauth {
            candidates.append(ClaudeCredential(
                oauth: desktopOAuth,
                source: .desktop,
                inferenceOnly: false
            ))
        }

        // A `CLAUDE_CODE_OAUTH_TOKEN` is inference-only: keep it last so it can
        // never shadow a real login, and mark it so the provider reports
        // "missing scope" rather than a blank card (research doc §9.3).
        if let envToken = environment.value(for: "CLAUDE_CODE_OAUTH_TOKEN")?.nilIfBlank {
            var oauth = candidates.first?.oauth ?? ClaudeOAuth()
            oauth.accessToken = envToken
            oauth.refreshToken = nil
            candidates.append(ClaudeCredential(
                oauth: oauth,
                source: .environment,
                inferenceOnly: true
            ))
        }

        return candidates
    }

    /// Whether a Keychain candidate is confirmed present by the cheap
    /// attributes-only probe, yet the same silent read `loadKeychainCredential()`
    /// performs fails with `.accessDenied` rather than "no such item" — the
    /// user *is* logged in via Claude Code, Mana just has not been granted
    /// permission to read that Keychain item silently yet. One interactive
    /// "Refresh Now" + "Always Allow" fixes this permanently (research doc:
    /// silent-path Keychain fix). Distinct from a genuine `.notLoggedIn`,
    /// where no candidate exists at all — that case must not be reported here.
    func keychainAccessIsDenied() -> Bool {
        for service in keychainServiceCandidates() {
            for account in [currentUserAccount(), nil] {
                // Only a definite `false` — `errSecItemNotFound` — rules this
                // candidate out. `nil` means the probe could not answer (the
                // silent gate was held by an open interactive dialog, or
                // `securityd` refused the attributes query outright), and
                // treating "could not answer" as "not there" is exactly how a
                // logged-in user ends up reading "No token source found"
                // when the real state is a missing one-time grant. The read
                // below still separates the two: denied throws, absent does
                // not.
                if keychain.genericPasswordExists(service: service, account: account) == false {
                    continue
                }
                do {
                    _ = try keychain.readGenericPassword(
                        service: service,
                        account: account,
                        allowInteraction: allowsKeychainInteraction
                    )
                } catch KeychainError.accessDenied {
                    return true
                } catch {
                    // Any other outcome (readable, locked for an unrelated
                    // reason, malformed) is not the permission case.
                }
            }
        }
        return false
    }

    /// Cheap, local-only, prompt-free evidence that a login exists at all
    /// (ТЗ §4.2). Never reads a secret it does not have to and never hits the
    /// network.
    func hasCredentialMaterial() -> Bool {
        for service in keychainServiceCandidates() {
            if keychain.genericPasswordExists(service: service, account: currentUserAccount()) == true {
                return true
            }
            if keychain.genericPasswordExists(service: service, account: nil) == true {
                return true
            }
        }
        if loadFileCredential() != nil { return true }
        if environment.value(for: "CLAUDE_CODE_OAUTH_TOKEN")?.nilIfBlank != nil { return true }
        if allowsDesktopFallback, desktop.hasCredentialMaterial() { return true }
        return false
    }

    /// Re-reads exactly the source a credential came from. Called immediately
    /// before Mana refreshes a token: the `claude` CLI may have rotated it in the
    /// meantime, and sending an already-used refresh token would invalidate the
    /// user's legitimate CLI session (ТЗ §4.2, research doc §9.3).
    func reload(_ source: ClaudeCredentialSource) -> ClaudeCredential? {
        switch source {
        case .keychain(let service, let account):
            return keychainCredential(service: service, account: account)
        case .file:
            return loadFileCredential()
        case .desktop, .environment:
            return nil
        }
    }

    // MARK: - Scope

    enum LiveUsageAvailability: Equatable, Sendable {
        case available
        /// The token can run inference but not read usage — it lacks
        /// `user:profile`. Distinct from "not logged in" (research doc §9.3).
        case missingProfileScope
    }

    func liveUsageAvailability(_ credential: ClaudeCredential) -> LiveUsageAvailability {
        if credential.inferenceOnly { return .missingProfileScope }
        // Older credentials predate the `scopes` field: treat absent/empty as
        // "unknown, allow" rather than suppressing a token that may well work.
        guard let scopes = credential.oauth.scopes, !scopes.isEmpty else { return .available }
        return scopes.contains(Self.usageScope) ? .available : .missingProfileScope
    }

    func needsRefresh(_ oauth: ClaudeOAuth) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return expiresAt - now().timeIntervalSince1970 * 1000 <= Self.refreshWindow * 1000
    }

    // MARK: - Rotation write-back

    /// Persists a rotated token back to the file it came from (ТЗ §4.2, as
    /// amended: the Keychain item is read-only to Mana — see
    /// `allowsRotationWriteBack`).
    ///
    /// Best-effort and deliberately silent: the source is re-read first, and if
    /// its refresh token no longer matches the one we started from, another
    /// process rotated it and the write is **skipped** rather than blindly
    /// overwriting (research doc §9.3). Returns whether the write happened; no
    /// caller treats `false` as a failure worth surfacing.
    @discardableResult
    func persistRotation(_ credential: ClaudeCredential, expectedRefreshToken: String?) -> Bool {
        guard credential.source.allowsRotationWriteBack else { return false }
        guard let current = reload(credential.source),
              current.oauth.refreshToken == expectedRefreshToken
        else {
            return false
        }

        // Merge onto the document actually on disk so fields Mana does not model
        // survive the rotation. A base that is not plain JSON (a hex-encoded
        // blob) is left alone rather than rewritten in a format the CLI may not
        // expect — the refreshed token still works for this session.
        guard let baseText = current.rawText,
              let text = JSONMerge.merged(
                  into: baseText,
                  updating: ClaudeCredentialsFile(claudeAiOauth: credential.oauth),
                  prettyPrinted: credential.source.isFile
              )
        else {
            return false
        }

        do {
            guard case .file(let path) = credential.source else { return false }
            try files.writeText(path, text)
            return true
        } catch {
            // Silent skip: the refreshed token still works for this session, and
            // the next poll re-reads whatever the CLI has.
            return false
        }
    }

    // MARK: - Sources

    func credentialsPath() -> String {
        let home = environment.value(for: "CLAUDE_CONFIG_DIR")?.nilIfBlank ?? Self.defaultHome
        return home.trimmingTrailingSlashes + "/" + Self.credentialFileName
    }

    /// Claude Code names its Keychain item `Claude Code-credentials`, suffixed
    /// with a hash of `CLAUDE_CONFIG_DIR` when that override is set.
    func keychainServiceCandidates() -> [String] {
        let base = Self.keychainServicePrefix + Self.keychainServiceSuffix
        guard let configDir = environment.value(for: "CLAUDE_CONFIG_DIR")?.nilIfBlank else {
            return [base]
        }
        return ["\(base)-\(Self.hashSuffix(configDir))", base]
    }

    static func parseCredentials(_ text: String) -> ClaudeCredentialsFile? {
        ProviderParse.decodeJSONWithHexFallback(text, as: ClaudeCredentialsFile.self)
    }

    private func loadFileCredential() -> ClaudeCredential? {
        let path = credentialsPath()
        guard let text = files.readTextIfPresent(path),
              let parsed = Self.parseCredentials(text),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.nilIfBlank != nil
        else {
            return nil
        }
        return ClaudeCredential(
            oauth: oauth,
            source: .file(path: path),
            inferenceOnly: false,
            rawText: text
        )
    }

    /// Keychain before file: on macOS the Keychain item is Claude Code's source
    /// of truth, and a stale `.credentials.json` can linger next to it.
    private func loadKeychainCredential() -> ClaudeCredential? {
        for service in keychainServiceCandidates() {
            if let credential = keychainCredential(service: service, account: currentUserAccount()) {
                return credential
            }
            if let credential = keychainCredential(service: service, account: nil) {
                return credential
            }
        }
        return nil
    }

    private func keychainCredential(service: String, account: String?) -> ClaudeCredential? {
        // A throw here (locked keychain, denied) is not "not logged in": it just
        // means this source cannot answer, so the next one is tried.
        let read = try? keychain.readGenericPassword(
            service: service,
            account: account,
            allowInteraction: allowsKeychainInteraction
        )
        guard let value = read ?? nil,
              let parsed = Self.parseCredentials(value),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.nilIfBlank != nil
        else {
            return nil
        }
        return ClaudeCredential(
            oauth: oauth,
            source: .keychain(service: service, account: account),
            inferenceOnly: false,
            rawText: value
        )
    }

    private func currentUserAccount() -> String? {
        NSUserName().nilIfBlank
    }

    private static func hashSuffix(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}
