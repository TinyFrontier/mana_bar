import Foundation
import UserNotifications

/// Fires local macOS notifications when a service's usage crosses a
/// configured threshold (default 80% / 95%, ТЗ §5), separately for the
/// session and weekly windows, with a per-threshold-per-session cooldown
/// ("не чаще одного уведомления на порог за окно сессии").
///
/// Setup-phase stub: authorization request + the actual threshold-crossing
/// bookkeeping are TODO for the implementation phase.
final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    /// Requests local-notification authorization (call once at launch).
    func requestAuthorizationIfNeeded() async {
        // TODO: UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Evaluates a fresh usage snapshot against configured thresholds and
    /// fires a notification if a new threshold was crossed since last check.
    func evaluate(_ usage: ServiceUsage) {
        // TODO: compare against AppSettings thresholds + per-threshold cooldown
        // state, then post a UNNotificationRequest ("Mana restored" copy per
        // docs/ТЗ-Mana.md §1.1 brand voice for reset notifications).
    }
}
