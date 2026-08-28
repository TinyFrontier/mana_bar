import Foundation

/// `auth.json` as the Codex CLI writes it (snake_case keys).
struct CodexTokens: Codable, Equatable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

struct CodexAuth: Codable, Equatable, Sendable {
    var tokens: CodexTokens?
    var lastRefresh: String?
    /// An `auth.json` may carry **only** this key. That is a valid Codex setup,
    /// not a parse failure — it just cannot read subscription usage, because
    /// OpenAI API keys have no access to the ChatGPT usage endpoint
    /// (research doc §9.3).
    var apiKey: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
        case apiKey = "OPENAI_API_KEY"
    }
}

enum CodexAuthSource: Equatable, Sendable {
    case file(path: String)
    case keychain

    var isFile: Bool {
        if case .file = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .file: return "file"
        case .keychain: return "keychain"
        }
    }
}

struct CodexCredential: Equatable, Sendable {
    var auth: CodexAuth
    var source: CodexAuthSource
    /// The raw document this credential was read from, so a rotation is merged
    /// back onto it rather than replacing it with only the fields Mana models —
    /// a real `auth.json` also carries keys such as `auth_mode`.
    var rawText: String?

    var hasUsableAccessToken: Bool {
        auth.tokens?.accessToken?.nilIfBlank != nil
    }

    /// An API-key-only credential: present and valid, but usage is unavailable.
    var isAPIKeyOnly: Bool {
        !hasUsableAccessToken && auth.apiKey?.nilIfBlank != nil
    }

    var accountID: String? {
        auth.tokens?.accountID?.nilIfBlank
    }
}

/// Finds the OAuth login the Codex CLI already holds: `auth.json` under
/// `$CODEX_HOME` (or `~/.config/codex` / `~/.codex`), with the `Codex Auth`
/// Keychain item as a fallback (ТЗ §4.1).
struct CodexAuthStore: Sendable {
    static let keychainService = "Codex Auth"
    /// Refresh once the access token is within this window of its JWT `exp` —
    /// the same slack the `codex` CLI uses, so both rotate on one schedule.
    static let refreshWindow: TimeInterval = 5 * 60
    /// Fallback age limit for tokens whose `exp` cannot be read.
    static let maxTokenAge: TimeInterval = 8 * 24 * 60 * 60
    private static let authFileName = "auth.json"
    private static let defaultHomes = ["~/.config/codex", "~/.codex"]

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainReading
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainReading = KeychainStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.now = now
    }

    // MARK: - Discovery

    /// Every credential currently readable, files first then Keychain.
    func loadCredentials() -> [CodexCredential] {
        var candidates = authPaths().compactMap { loadCredential(atPath: $0) }
        if let keychainCredential = loadKeychainCredential() {
            candidates.append(keychainCredential)
        }
        return candidates
    }

    /// Cheap, local-only check without reading any secret (ТЗ §4.2).
    func hasCredentialMaterial() -> Bool {
        if authPaths().contains(where: { loadCredential(atPath: $0) != nil }) { return true }
        return keychain.genericPasswordExists(service: Self.keychainService) == true
    }

    /// Re-reads exactly one source, for the "the CLI may have rotated the token
    /// under us" check before a refresh (ТЗ §4.2).
    func reload(_ source: CodexAuthSource) -> CodexCredential? {
        switch source {
        case .file(let path): return loadCredential(atPath: path)
        case .keychain: return loadKeychainCredential()
        }
    }

    func loadCredential(atPath path: String) -> CodexCredential? {
        guard let text = files.readTextIfPresent(path),
              let auth = Self.parseAuth(text),
              Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexCredential(auth: auth, source: .file(path: path), rawText: text)
    }

    func loadKeychainCredential() -> CodexCredential? {
        guard let value = (try? keychain.readGenericPassword(service: Self.keychainService)) ?? nil,
              let auth = Self.parseAuth(value),
              Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexCredential(auth: auth, source: .keychain, rawText: value)
    }

    func authPaths() -> [String] {
        if let home = environment.value(for: "CODEX_HOME")?.nilIfBlank {
            return [home.trimmingTrailingSlashes + "/" + Self.authFileName]
        }
        return Self.defaultHomes.map { $0 + "/" + Self.authFileName }
    }

    static func parseAuth(_ text: String) -> CodexAuth? {
        ProviderParse.decodeJSONWithHexFallback(text, as: CodexAuth.self)
    }

    /// Whether a parsed `auth.json` carries anything credential-like at all —
    /// an OAuth access token **or** a bare API key. The API-key-only case is
    /// kept (rather than discarded as junk) so the provider can report
    /// "usage unavailable" instead of "not logged in".
    static func hasTokenLikeAuth(_ auth: CodexAuth) -> Bool {
        auth.tokens?.accessToken?.nilIfBlank != nil || auth.apiKey?.nilIfBlank != nil
    }

    // MARK: - Expiry

    /// Prefer the access token's own JWT `exp`; fall back to the wall-clock age
    /// of `last_refresh` only when `exp` is unreadable. A brand-new login with
    /// neither does not need a refresh.
    func needsRefresh(_ auth: CodexAuth) -> Bool {
        if let accessToken = auth.tokens?.accessToken,
           let expiresAt = accessTokenExpiry(accessToken) {
            return expiresAt.timeIntervalSince(now()) <= Self.refreshWindow
        }
        guard let lastRefresh = auth.lastRefresh,
              let date = ISO8601.date(from: lastRefresh)
        else {
            return false
        }
        return now().timeIntervalSince(date) > Self.maxTokenAge
    }

    func accessTokenExpiry(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - Rotation write-back

    /// Writes a rotated token back to the source it came from (ТЗ §4.2), after
    /// confirming that source still holds the refresh token we consumed. A
    /// conflict means the `codex` CLI rotated first: skip silently rather than
    /// overwrite, which is what trips `refresh_token_reused` (research doc §9.3).
    @discardableResult
    func persistRotation(_ credential: CodexCredential, expectedRefreshToken: String?) -> Bool {
        guard let current = reload(credential.source),
              current.auth.tokens?.refreshToken == expectedRefreshToken
        else {
            return false
        }

        // Merge onto the document actually on disk: `auth.json` carries keys
        // Mana does not model (`auth_mode`, and whatever `codex` adds next), and
        // re-encoding only our own fields would delete them.
        guard let baseText = current.rawText,
              let text = JSONMerge.merged(
                  into: baseText,
                  updating: credential.auth,
                  prettyPrinted: credential.source.isFile
              )
        else {
            return false
        }

        do {
            switch credential.source {
            case .file(let path):
                try files.writeText(path, text)
            case .keychain:
                try keychain.writeGenericPassword(
                    service: Self.keychainService,
                    account: nil,
                    value: text
                )
            }
            return true
        } catch {
            return false
        }
    }
}
