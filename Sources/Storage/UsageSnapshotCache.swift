import Foundation

// This file talks ONLY in the Codable DTOs below — never in the frozen
// `ServiceUsage`/`UsageWindow` contract types themselves (UsageProvider.swift/
// ServiceUsage.swift stay off-limits for this wave). Keeping the wire format
// as a separate, explicit mapping means a future change to the frozen struct
// can never silently change what's on disk (or vice versa) via synthesized
// `Codable` on the contract type.

/// Codable mirror of `UsageWindow.Kind` (research doc §9 п.7: disk cache).
/// `ServiceUsage`/`UsageWindow` are frozen-contract, non-`Codable` types —
/// this DTO is the only thing that ever touches disk.
enum UsageWindowKindDTO: Codable, Equatable {
    case session
    case weekly
    case modelWeekly(String)
    case billingPeriod

    init(_ kind: UsageWindow.Kind) {
        switch kind {
        case .session: self = .session
        case .weekly: self = .weekly
        case .modelWeekly(let name): self = .modelWeekly(name)
        case .billingPeriod: self = .billingPeriod
        }
    }

    var asUsageWindowKind: UsageWindow.Kind {
        switch self {
        case .session: return .session
        case .weekly: return .weekly
        case .modelWeekly(let name): return .modelWeekly(name)
        case .billingPeriod: return .billingPeriod
        }
    }
}

/// Codable mirror of `UsageWindow`.
struct UsageWindowDTO: Codable, Equatable {
    var kind: UsageWindowKindDTO
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    var periodDuration: TimeInterval?

    init(_ window: UsageWindow) {
        kind = UsageWindowKindDTO(window.kind)
        label = window.label
        usedPercent = window.usedPercent
        resetsAt = window.resetsAt
        periodDuration = window.periodDuration
    }

    var asUsageWindow: UsageWindow {
        UsageWindow(
            kind: kind.asUsageWindowKind,
            label: label,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            periodDuration: periodDuration
        )
    }
}

/// Codable mirror of `ServiceUsage` (research doc §9 п.7: "кэш на диске").
/// Holds exactly what `ServiceUsage` holds — plan/windows/refresh time/
/// warning — and nothing else: no tokens, no credentials, no account
/// identifiers, since `ServiceUsage` never carries any either.
struct ServiceUsageDTO: Codable, Equatable {
    var serviceID: ServiceID
    var plan: String?
    var windows: [UsageWindowDTO]
    var refreshedAt: Date
    var warning: String?

    init(_ usage: ServiceUsage) {
        serviceID = usage.serviceID
        plan = usage.plan
        windows = usage.windows.map(UsageWindowDTO.init)
        refreshedAt = usage.refreshedAt
        warning = usage.warning
    }

    var asServiceUsage: ServiceUsage {
        ServiceUsage(
            serviceID: serviceID,
            plan: plan,
            windows: windows.map { $0.asUsageWindow },
            refreshedAt: refreshedAt,
            warning: warning
        )
    }
}

/// Persists the last successful `ServiceUsage` snapshot per provider to a
/// single JSON file in Application Support, so a relaunch can show
/// yesterday's numbers immediately instead of a blank `.loading` state
/// (research doc §9 п.7). Deliberately dumb: whole-file read + whole-file
/// atomic rewrite — the payload is a couple of small structs per provider,
/// not worth a real database for.
///
/// "Freshness only within the current launch session" (research doc §9 п.7)
/// is enforced by the *caller* (`UsageCoordinator`), not here: this type has
/// no opinion on staleness, it just stores/loads whatever it's given.
struct UsageSnapshotCache {
    private let fileURL: URL
    private let fileManager: FileManager

    /// - Parameter directory: overridden by tests to a throwaway temp
    ///   directory; defaults to `~/Library/Application Support/Mana/`.
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let resolvedDirectory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        fileURL = resolvedDirectory.appendingPathComponent("usage-cache.json")
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Mana", isDirectory: true)
    }

    /// Every cached snapshot, keyed by service. Missing/corrupt file → empty
    /// (never throws — a cache miss is not an error condition for callers).
    func load() -> [ServiceID: ServiceUsage] {
        loadRaw().reduce(into: [:]) { result, entry in
            guard let id = ServiceID(rawValue: entry.key) else { return }
            result[id] = entry.value.asServiceUsage
        }
    }

    /// Writes `usage` into the cache, replacing any existing entry for the
    /// same service, and leaving every other provider's entry untouched.
    /// Best-effort: a write failure (e.g. sandboxed/read-only volume) is
    /// silently dropped rather than surfaced, since the cache is purely an
    /// optimization — losing it never loses data the app itself needs.
    func save(_ usage: ServiceUsage) {
        var raw = loadRaw()
        raw[usage.serviceID.rawValue] = ServiceUsageDTO(usage)
        writeRaw(raw)
    }

    private func loadRaw() -> [String: ServiceUsageDTO] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: ServiceUsageDTO].self, from: data)) ?? [:]
    }

    private func writeRaw(_ raw: [String: ServiceUsageDTO]) {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(raw)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort cache — see `save(_:)` doc.
        }
    }
}
