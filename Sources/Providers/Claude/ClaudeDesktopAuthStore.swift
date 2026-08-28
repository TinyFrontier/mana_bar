import CommonCrypto
import CryptoKit
import Foundation

enum ClaudeDesktopStatus: Equatable, Sendable {
    case notFound
    /// Material is there, but macOS would have to ask the user to allow reading
    /// the "Claude Safe Storage" Keychain item. Background polls never prompt.
    case permissionRequired
    /// Every cached token has expired — Claude Desktop must renew them itself.
    case stale
    case invalid
    case available
}

struct ClaudeDesktopCredential: Sendable {
    var oauth: ClaudeOAuth?
    var status: ClaudeDesktopStatus
}

/// Reads Claude Desktop's Electron OAuth cache as an **optional, read-only**
/// credential source (ТЗ §4.1).
///
/// Two rules govern this source, both from research doc §9.3:
/// 1. Only the current access token is borrowed. The refresh token is never
///    even decoded, so Mana can never rotate it and log the user out of Claude
///    Desktop.
/// 2. Nothing is ever written back here.
///
/// The cache is Electron `safeStorage`: AES-128-CBC with a key derived by
/// PBKDF2-HMAC-SHA1 (salt "saltysalt", 1003 rounds) from a password kept in the
/// Keychain item `Claude Safe Storage` / account `Claude Key`.
struct ClaudeDesktopAuthStore: Sendable {
    static let keychainService = "Claude Safe Storage"
    static let keychainAccount = "Claude Key"
    private static let configRelativePath = "Library/Application Support/Claude/config.json"
    private static let cacheV1Key = "oauth:tokenCache"
    private static let cacheV2Key = "oauth:tokenCacheV2"
    private static let apiHost = "https://api.anthropic.com"
    /// Client id Claude's production login mints full-scope tokens under; used
    /// only to rank cache entries, never sent anywhere.
    private static let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let inferenceScope = "user:inference"
    private static let expirySafetyMarginMs = 2 * 60 * 1000.0

    var files: TextFileAccessing
    var keychain: KeychainReading
    var homeDirectory: @Sendable () -> URL
    var now: @Sendable () -> Date

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainReading = KeychainStore(),
        homeDirectory: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
        self.now = now
    }

    /// Prompt-free evidence that Claude Desktop holds a login, for
    /// `hasLocalCredentials()`. Only looks at the config file; decryption (and
    /// any Keychain prompt) waits for a real fetch.
    func hasCredentialMaterial() -> Bool {
        guard let root = configRoot() else { return false }
        return root[Self.cacheV2Key] is String || root[Self.cacheV1Key] is String
    }

    func load(allowInteraction: Bool) -> ClaudeDesktopCredential {
        guard let root = configRoot(), hasCredentialMaterial() else {
            return ClaudeDesktopCredential(oauth: nil, status: .notFound)
        }

        let password: String?
        do {
            password = try keychain.readGenericPassword(
                service: Self.keychainService,
                account: Self.keychainAccount,
                allowInteraction: allowInteraction
            )
        } catch KeychainError.accessDenied {
            return ClaudeDesktopCredential(oauth: nil, status: .permissionRequired)
        } catch {
            return ClaudeDesktopCredential(oauth: nil, status: .invalid)
        }
        guard let password, let key = try? Self.deriveKey(password: password) else {
            return ClaudeDesktopCredential(oauth: nil, status: .notFound)
        }

        let v2 = Self.decodeCache(root[Self.cacheV2Key], key: key)
        let v1 = Self.decodeCache(root[Self.cacheV1Key], key: key)
        guard v2 != nil || v1 != nil else {
            return ClaudeDesktopCredential(oauth: nil, status: .invalid)
        }
        return Self.selectCredential(v2: v2, v1: v1, now: now())
    }

    // MARK: - Cache selection

    /// Picks the best usable cache entry. Ranking mirrors how Desktop itself
    /// resolves the active login: production client with full scopes first, then
    /// any full-scope entry, then scope richness, with expiry only as a
    /// tiebreak — so a stale wrong-tier token with a longer TTL cannot win.
    ///
    /// Mana does not filter by organization (single account per service in the
    /// MVP); with several org logins cached, the highest-ranked one is used.
    static func selectCredential(
        v2: [String: Any]?,
        v1: [String: Any]?,
        now: Date
    ) -> ClaudeDesktopCredential {
        let v2Result = candidates(in: v2, now: now)
        if let best = v2Result.available.max(by: { $0.rank < $1.rank }) {
            return ClaudeDesktopCredential(oauth: best.oauth, status: .available)
        }
        // V1 entries that V2 already supersedes are ignored.
        let v2Keys = Set(v2?.keys ?? [String: Any]().keys)
        let v1Result = candidates(in: v1?.filter { !v2Keys.contains($0.key) }, now: now)
        if let best = v1Result.available.max(by: { $0.rank < $1.rank }) {
            return ClaudeDesktopCredential(oauth: best.oauth, status: .available)
        }
        if v2Result.sawStale || v1Result.sawStale {
            return ClaudeDesktopCredential(oauth: nil, status: .stale)
        }
        if v2Result.sawInvalid || v1Result.sawInvalid {
            return ClaudeDesktopCredential(oauth: nil, status: .invalid)
        }
        return ClaudeDesktopCredential(oauth: nil, status: .notFound)
    }

    private struct Candidate {
        var oauth: ClaudeOAuth
        var clientID: String
        var scopes: [String]
        var expiresAt: Double

        var rank: (Int, Int, Int, Double) {
            let hasFullScope = scopes.contains(ClaudeAuthStore.usageScope)
                && scopes.contains(ClaudeDesktopAuthStore.inferenceScope)
            let isProductionClient = clientID == ClaudeDesktopAuthStore.productionClientID
            return (
                isProductionClient && hasFullScope ? 1 : 0,
                hasFullScope ? 1 : 0,
                scopes.count,
                expiresAt
            )
        }
    }

    private static func candidates(
        in cache: [String: Any]?,
        now: Date
    ) -> (available: [Candidate], sawStale: Bool, sawInvalid: Bool) {
        guard let cache else { return ([], false, false) }
        var available: [Candidate] = []
        var sawStale = false
        var sawInvalid = false

        for (cacheKey, rawEntry) in cache {
            guard let parsedKey = parseCacheKey(cacheKey),
                  parsedKey.apiHost == apiHost,
                  parsedKey.scopes.contains(ClaudeAuthStore.usageScope)
            else {
                continue
            }
            guard !(rawEntry is NSNull) else { continue }
            guard let entry = rawEntry as? [String: Any],
                  let token = (entry["token"] as? String)?.nilIfBlank,
                  let expiresAt = ProviderParse.number(entry["expiresAt"]), expiresAt.isFinite
            else {
                sawInvalid = true
                continue
            }
            guard expiresAt > now.timeIntervalSince1970 * 1000 + expirySafetyMarginMs else {
                sawStale = true
                continue
            }
            // refreshToken stays nil on purpose — see the type doc.
            let oauth = ClaudeOAuth(
                accessToken: token,
                refreshToken: nil,
                expiresAt: expiresAt,
                subscriptionType: entry["subscriptionType"] as? String,
                rateLimitTier: entry["rateLimitTier"] as? String,
                scopes: parsedKey.scopes
            )
            available.append(Candidate(
                oauth: oauth,
                clientID: parsedKey.clientID,
                scopes: parsedKey.scopes,
                expiresAt: expiresAt
            ))
        }
        return (available, sawStale, sawInvalid)
    }

    private struct CacheKey {
        var clientID: String
        var organization: String
        var apiHost: String
        var scopes: [String]
    }

    /// Cache keys look like
    /// `<clientUUID>:<orgUUID>:https://api.anthropic.com:<space-separated scopes>`.
    private static func parseCacheKey(_ value: String) -> CacheKey? {
        let marker = ":\(apiHost):"
        guard let markerRange = value.range(of: marker) else { return nil }
        let prefix = value[..<markerRange.lowerBound]
        guard let firstColon = prefix.firstIndex(of: ":") else { return nil }
        let clientID = String(prefix[..<firstColon])
        let organization = String(prefix[prefix.index(after: firstColon)...]).lowercased()
        guard UUID(uuidString: clientID) != nil, UUID(uuidString: organization) != nil else {
            return nil
        }
        let scopes = value[markerRange.upperBound...]
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return CacheKey(
            clientID: clientID,
            organization: organization,
            apiHost: apiHost,
            scopes: scopes
        )
    }

    // MARK: - Electron safeStorage

    private func configRoot() -> [String: Any]? {
        let path = homeDirectory().appendingPathComponent(Self.configRelativePath).path
        guard let text = files.readTextIfPresent(path),
              let data = text.data(using: .utf8)
        else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decodeCache(_ stored: Any?, key: Data) -> [String: Any]? {
        guard let base64 = stored as? String,
              let encrypted = Data(base64Encoded: base64),
              let plaintext = try? decrypt(encrypted, key: key)
        else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any]
    }

    /// PBKDF2-HMAC-SHA1, salt "saltysalt", 1003 rounds, 16-byte key — the
    /// Electron `safeStorage` scheme on macOS.
    static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyCount
                    )
                }
            }
        }
        guard result == kCCSuccess else { throw ClaudeDesktopCryptoError.keyDerivationFailed }
        return key
    }

    /// AES-128-CBC with an all-spaces IV, after the "v10" version prefix.
    static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else {
            throw ClaudeDesktopCryptoError.invalidCiphertext
        }

        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeDesktopCryptoError.decryptionFailed }
        output.count = outputLength
        return output
    }
}

enum ClaudeDesktopCryptoError: Error, Equatable {
    case keyDerivationFailed
    case invalidCiphertext
    case decryptionFailed
}
