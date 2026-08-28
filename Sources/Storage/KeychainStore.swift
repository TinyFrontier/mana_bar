import Foundation
import Security

/// Wraps the Security framework Keychain APIs for storing per-service
/// session tokens. Per docs/ТЗ-Mana.md §4.2 and §8, tokens (MVP: pasted
/// manually in Settings) must live only in the Keychain — never in
/// UserDefaults, plists, or logs — so a restart doesn't require re-login
/// (ТЗ §10, acceptance criterion 5).
///
/// Setup-phase stub: defines the storage surface; SecItem calls are TODO.
struct KeychainStore {
    enum StoreError: Error {
        case notImplemented
    }

    private let service = "com.manabar.Mana"

    /// Persists (or replaces) the token for a given service.
    func setToken(_ token: String, for serviceID: ServiceID) throws {
        // TODO: SecItemAdd / SecItemUpdate against `service` + serviceID.rawValue account.
        throw StoreError.notImplemented
    }

    /// Reads the stored token for a given service, if any.
    func token(for serviceID: ServiceID) throws -> String? {
        // TODO: SecItemCopyMatching against `service` + serviceID.rawValue account.
        throw StoreError.notImplemented
    }

    /// Removes the stored token for a given service (e.g. on "Re-login" / sign out).
    func deleteToken(for serviceID: ServiceID) throws {
        // TODO: SecItemDelete against `service` + serviceID.rawValue account.
        throw StoreError.notImplemented
    }
}
