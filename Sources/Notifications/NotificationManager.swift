import Foundation
import UserNotifications

/// Fires local macOS notifications when a service's usage crosses a
/// configured threshold (default 80% / 95%, ТЗ §5), separately for the
/// session and weekly windows, with a per-threshold-per-window cooldown
/// ("не чаще одного уведомления на порог за окно сессии").
///
/// The actual crossing/cooldown bookkeeping lives in the pure, testable
/// `NotificationThresholdTracker`; this type only requests authorization and
/// maps a `ThresholdCrossing` onto a real `UNNotificationRequest` — it is
/// intentionally not unit-tested itself (touches `UNUserNotificationCenter`,
/// a system framework), unlike the tracker.
final class NotificationManager {
    static let shared = NotificationManager()

    private let center: UNUserNotificationCenter
    private let tracker = NotificationThresholdTracker()
    private var didRequestAuthorization = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Requests local-notification authorization. Safe to call more than
    /// once (e.g. every launch): `UNUserNotificationCenter` only prompts the
    /// user the very first time a process asks; later calls just report the
    /// already-decided status, so this never re-shows the system dialog.
    /// Call once at launch (ТЗ §5 — "при первом включении").
    func requestAuthorizationIfNeeded() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // Soft-fail (task brief): notifications simply won't show; no
            // other Mana feature depends on this succeeding.
        }
    }

    /// Evaluates a fresh usage snapshot against `AppSettings`' configured
    /// thresholds and fires a notification for every newly crossed one.
    /// Call from `UsageCoordinator` right after each successful fetch.
    @MainActor
    func evaluate(_ usage: ServiceUsage) {
        let settings = AppSettings.shared
        let crossings = tracker.evaluate(
            usage: usage,
            sessionThresholds: settings.sessionNotificationThresholds,
            weeklyThresholds: settings.weeklyNotificationThresholds
        )
        for crossing in crossings {
            post(crossing, serviceName: usage.serviceID.displayName)
        }
    }

    /// Drops cooldown memory for a service — call when it becomes
    /// `.unavailable` (logged out) so a later re-login starts clean.
    func reset(serviceID: ServiceID) {
        tracker.reset(serviceID: serviceID)
    }

    private func post(_ crossing: ThresholdCrossing, serviceName: String) {
        let content = UNMutableNotificationContent()
        let windowName = crossing.isWeekly ? "weekly" : "session"

        switch crossing.kind {
        case .thresholdReached(let threshold):
            content.title = "\(serviceName) at \(Int(crossing.percent.rounded()))%"
            content.body = "\(serviceName) \(windowName) usage crossed \(Int((threshold * 100).rounded()))%."
        case .windowReset:
            // ТЗ §1.1 brand voice: "Mana restored" on a reset after 100%.
            content.title = "Mana restored"
            content.body = "\(serviceName) \(windowName) limit has reset."
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }
}
