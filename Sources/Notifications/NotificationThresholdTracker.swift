import Foundation

/// One notification-worthy event produced by `NotificationThresholdTracker`.
struct ThresholdCrossing: Equatable {
    enum Kind: Equatable {
        /// `threshold` (0...1) was just crossed from below.
        case thresholdReached(Double)
        /// The window rolled over (`resetsAt` changed) right after a cycle
        /// that had hit 100% — brand-voice "Mana restored" moment
        /// (ТЗ §1.1, §5, optional per task brief).
        case windowReset
    }

    let serviceID: ServiceID
    let isWeekly: Bool
    let kind: Kind
    /// `usedPercent` (0...100) at the moment of the crossing.
    let percent: Double
}

/// Pure, UI/system-framework-free core of the notifications feature (ТЗ §5):
/// detects threshold crossings "снизу вверх" (from below) per service per
/// window (session/weekly), and enforces "not more than one notification
/// per threshold per session window" by remembering which thresholds already
/// fired for the *current* window instance — identified by its `resetsAt`.
/// The moment `resetsAt` changes, that memory is cleared (a new window
/// started), which is exactly the cooldown-reset rule ТЗ §5 asks for.
///
/// Kept free of `UNUserNotificationCenter`/`AppSettings` so it's directly
/// unit-testable without touching the system notification center or
/// `UserDefaults`; `NotificationManager` wraps one instance of this and maps
/// `ThresholdCrossing` to actual `UNNotificationRequest`s.
final class NotificationThresholdTracker {
    private struct WindowMemory {
        var resetsAt: Date?
        var lastPercent: Double
        var firedThresholds: Set<Double>
        /// Whether this cycle ever reached 100% — drives the optional
        /// "Mana restored" event on the *next* window.
        var wasExhausted: Bool
    }

    private struct Key: Hashable {
        let serviceID: ServiceID
        let isWeekly: Bool
    }

    private var memory: [Key: WindowMemory] = [:]

    init() {}

    /// Evaluates a fresh `ServiceUsage` snapshot against the configured
    /// thresholds and returns every crossing that just happened. Call once
    /// per successful fetch (ТЗ §5) — a window with no session/weekly data
    /// present is simply skipped, not treated as 0%.
    ///
    /// - Parameters:
    ///   - sessionThresholds: fractions 0...1 (e.g. `[0.8, 0.95]`).
    ///   - weeklyThresholds: fractions 0...1, evaluated independently of
    ///     `sessionThresholds` (ТЗ §5: "отдельно для сессии и недели").
    func evaluate(usage: ServiceUsage, sessionThresholds: [Double], weeklyThresholds: [Double]) -> [ThresholdCrossing] {
        var results: [ThresholdCrossing] = []
        if let window = usage.sessionWindow {
            results += evaluate(serviceID: usage.serviceID, isWeekly: false, window: window, thresholds: sessionThresholds)
        }
        if let window = usage.weeklyWindow {
            results += evaluate(serviceID: usage.serviceID, isWeekly: true, window: window, thresholds: weeklyThresholds)
        }
        return results
    }

    /// Discards all memory for one service (e.g. it just went `.unavailable`
    /// or was disabled) so a later re-enable/re-login starts clean instead
    /// of replaying stale "already fired" state against a new login.
    func reset(serviceID: ServiceID) {
        memory = memory.filter { $0.key.serviceID != serviceID }
    }

    private func evaluate(serviceID: ServiceID, isWeekly: Bool, window: UsageWindow, thresholds: [Double]) -> [ThresholdCrossing] {
        let key = Key(serviceID: serviceID, isWeekly: isWeekly)
        var results: [ThresholdCrossing] = []

        // A window instance is identified by its `resetsAt`. When it changes
        // from what we last saw, the previous cycle ended — clear the
        // per-threshold cooldown and, if that cycle had hit 100%, emit the
        // optional "Mana restored" event.
        if let existing = memory[key], existing.resetsAt != window.resetsAt {
            if existing.wasExhausted {
                results.append(ThresholdCrossing(serviceID: serviceID, isWeekly: isWeekly, kind: .windowReset, percent: window.usedPercent))
            }
            memory[key] = nil
        }

        var mem = memory[key] ?? WindowMemory(resetsAt: window.resetsAt, lastPercent: 0, firedThresholds: [], wasExhausted: false)
        mem.resetsAt = window.resetsAt

        // "Снизу вверх": fires when the last known percent was below the
        // threshold and the fresh one is at/above it. On the very first
        // observation of a window `lastPercent` starts at 0, so a session
        // that's already high the first time Mana ever sees it (e.g. right
        // after launch) still notifies once — silently sitting above 80%
        // forever without a single alert would defeat the point of §5.
        for threshold in thresholds {
            guard !mem.firedThresholds.contains(threshold) else { continue }
            let thresholdPercent = threshold * 100
            if mem.lastPercent < thresholdPercent, window.usedPercent >= thresholdPercent {
                mem.firedThresholds.insert(threshold)
                results.append(ThresholdCrossing(serviceID: serviceID, isWeekly: isWeekly, kind: .thresholdReached(threshold), percent: window.usedPercent))
            }
        }

        if window.usedPercent >= 100 { mem.wasExhausted = true }
        mem.lastPercent = window.usedPercent
        memory[key] = mem
        return results
    }
}
