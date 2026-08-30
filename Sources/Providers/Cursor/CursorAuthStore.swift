import Foundation

/// Where a Cursor login was found. Both sources belong to the Cursor app —
/// Mana reads them and never writes back, for the same reason it leaves the
/// `claude`/`codex` Keychain items alone (see
/// `ClaudeCredentialSource.allowsRotationWriteBack`).
enum CursorCredentialSource: Equatable, Sendable {
    /// Cursor's VS Code-style global storage database.
    case stateDatabase
    /// The `cursor-access-token` / `cursor-refresh-token` Keychain items.
    case keychain

    var label: String {
        switch self {
        case .stateDatabase: return "state-db"
        case .keychain: return "keychain"
        }
    }
}

struct CursorCredential: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    /// `cursorAuth/stripeMembershipType` — "free", "pro", … Used as the plan
    /// label when the usage response carries no nicer name.
    var membershipType: String?
    var source: CursorCredentialSource

    var canRefresh: Bool { refreshToken?.nilIfBlank != nil }
}

/// Finds the login the Cursor app already holds on this machine (ТЗ §4.1
/// applied to Cursor): its `state.vscdb` first, the Keychain items second.
///
/// Cursor writes the same tokens to both, but the database is the copy it
/// keeps current, so it wins — the same "app's own store first" rule the
/// Claude side follows for Claude Code's Keychain item.
struct CursorAuthStore: Sendable {
    static let stateDatabasePath =
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let stateTable = "ItemTable"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"
    static let keychainRefreshTokenService = "cursor-refresh-token"

    var sqlite: SQLiteReading
    var keychain: KeychainReading
    /// Whether reading Cursor's Keychain items may raise the macOS "allow
    /// access" dialog — same silent/interactive split as the other providers.
    var allowsKeychainInteraction: Bool
    var now: @Sendable () -> Date

    init(
        sqlite: SQLiteReading = SQLiteCLIStore(),
        keychain: KeychainReading = KeychainStore(),
        allowsKeychainInteraction: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.allowsKeychainInteraction = allowsKeychainInteraction
        self.now = now
    }

    /// Every login found, database before Keychain. Empty means "not logged
    /// in" — the provider decides whether a Keychain grant is what is actually
    /// missing.
    func loadCredentials() -> [CursorCredential] {
        var credentials: [CursorCredential] = []
        if let fromDatabase = databaseCredential() { credentials.append(fromDatabase) }
        if let fromKeychain = keychainCredential() { credentials.append(fromKeychain) }
        return credentials
    }

    /// Cheap, prompt-free "is there a login at all" probe for the launch path
    /// and the Settings/onboarding status rows.
    func hasCredentialMaterial() -> Bool {
        if databaseValue(Self.accessTokenKey) != nil { return true }
        if keychain.genericPasswordExists(service: Self.keychainAccessTokenService) == true { return true }
        return false
    }

    /// The item exists but a silent read of it is refused — a one-time grant is
    /// missing, not a login. Mirrors `ClaudeAuthStore.keychainAccessIsDenied()`,
    /// including treating an unanswerable probe as inconclusive rather than as
    /// evidence of absence.
    func keychainAccessIsDenied() -> Bool {
        guard databaseValue(Self.accessTokenKey) == nil else { return false }
        if keychain.genericPasswordExists(service: Self.keychainAccessTokenService) == false {
            return false
        }
        do {
            _ = try keychain.readGenericPassword(
                service: Self.keychainAccessTokenService,
                account: nil,
                allowInteraction: allowsKeychainInteraction
            )
        } catch KeychainError.accessDenied {
            return true
        } catch {
            // Any other outcome is not the permission case.
        }
        return false
    }

    // MARK: - Sources

    private func databaseCredential() -> CursorCredential? {
        guard let accessToken = databaseValue(Self.accessTokenKey) else { return nil }
        return CursorCredential(
            accessToken: accessToken,
            refreshToken: databaseValue(Self.refreshTokenKey),
            membershipType: databaseValue(Self.membershipTypeKey),
            source: .stateDatabase
        )
    }

    private func keychainCredential() -> CursorCredential? {
        guard let accessToken = keychainValue(Self.keychainAccessTokenService) else { return nil }
        return CursorCredential(
            accessToken: accessToken,
            refreshToken: keychainValue(Self.keychainRefreshTokenService),
            membershipType: nil,
            source: .keychain
        )
    }

    private func databaseValue(_ key: String) -> String? {
        sqlite.value(
            inDatabase: Self.stateDatabasePath,
            table: Self.stateTable,
            key: key
        )?.nilIfBlank
    }

    private func keychainValue(_ service: String) -> String? {
        // A throw here (locked keychain, denied, cancelled) is not "not logged
        // in": it just means this source cannot answer right now.
        let value = try? keychain.readGenericPassword(
            service: service,
            account: nil,
            allowInteraction: allowsKeychainInteraction
        )
        return (value ?? nil)?.nilIfBlank
    }
}
