import Foundation

// FROZEN CONTRACT (2026-08-28): this file is the shared boundary between the
// provider layer and the UI layer. Change it only via the orchestrator session,
// never from a single-sided implementation task.

/// Common protocol every AI-service usage source conforms to (ТЗ §4.1).
/// Providers are isolated from each other: a failure in one must not affect
/// another (ТЗ §11). `fetchUsage()` throws `UsageError`; keeping the last
/// good snapshot on failure is the responsibility of the store layer above
/// (see `ServiceStatus.stale`).
protocol UsageProvider: Sendable {
    /// Stable identity of the service this provider fetches usage for.
    var serviceID: ServiceID { get }

    /// Cheap, local-only check whether a credential source exists at all
    /// (CLI keychain entry / credentials file), without hitting the network
    /// (ТЗ §4.2). `false` means "show: источник токена не найден".
    func hasLocalCredentials() async -> Bool

    /// Fetches a fresh usage snapshot for this service. Throws `UsageError`.
    /// Implementations own their auth flow: on 401/403 refresh the token and
    /// retry exactly once; a second auth failure surfaces `.sessionExpired`.
    func fetchUsage() async throws -> ServiceUsage
}

/// Typed failures of a usage fetch (research doc §9.2). The UI maps these to
/// the gray ring + message + "Re-login via CLI" hint (ТЗ §4.3).
enum UsageError: Error, Equatable, Sendable {
    /// No credential source found, or it holds no OAuth tokens at all.
    case notLoggedIn
    /// A credential item exists, but reading it silently is not permitted yet:
    /// the user must trigger one interactive read (Refresh Now) and grant
    /// Keychain access ("Always Allow") so background polls can work.
    case keychainAccessDenied
    /// Token invalid/expired and refresh failed — user must re-login in the CLI.
    case sessionExpired
    /// Token is valid for inference but lacks the scope needed for usage data
    /// (e.g. `claude setup-token` tokens without `user:profile`).
    case missingScope
    /// HTTP 429. Respect `retryAfter` (seconds) with a per-provider cooldown;
    /// skip network calls until it elapses and serve cached data.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-success HTTP status.
    case requestFailed(statusCode: Int)
    /// Transport-level failure (offline, DNS, timeout).
    case connectionFailed
    /// Response arrived but could not be parsed into the expected shape.
    case decodingFailed(String)

    /// Short human-readable text for the detail card (ТЗ §4.3).
    var userDescription: String {
        switch self {
        case .notLoggedIn: return "No token source found"
        case .keychainAccessDenied: return "Keychain permission needed — click Refresh Now"
        case .sessionExpired: return "Session expired — sign in again in the CLI"
        case .missingScope: return "Token lacks the scope for usage data"
        case .rateLimited: return "Too many requests — paused"
        case .requestFailed(let code): return "Service error (HTTP \(code))"
        case .connectionFailed: return "No connection"
        case .decodingFailed: return "Unexpected response format"
        }
    }
}
