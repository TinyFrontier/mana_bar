import Foundation

/// Common protocol every AI-service usage source conforms to (ТЗ §4.1).
/// Providers are isolated from each other: a failure in one must not affect
/// another (ТЗ §11) — each `fetchUsage()` call should catch its own errors
/// and surface them via `ServiceUsage.state`, only throwing for truly
/// unrecoverable setup problems (e.g. missing token).
protocol UsageProvider: Sendable {
    /// Stable identity of the service this provider fetches usage for.
    var serviceID: ServiceID { get }

    /// Fetches a fresh usage snapshot for this service.
    func fetchUsage() async throws -> ServiceUsage
}
