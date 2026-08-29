import ApplicationServices
import Foundation

/// Live view of the app's Accessibility (TCC) trust state.
///
/// `AXIsProcessTrusted()` is a point-in-time read and macOS sends no
/// notification when the user flips the switch in System Settings → Privacy &
/// Security → Accessibility. Reading it once at launch therefore leaves the
/// app permanently believing the answer it got before the user granted
/// anything: the onboarding keeps saying "Not granted" and `HotZoneMonitor`
/// is never re-armed. This type closes that gap with a cheap poll — one
/// `AXIsProcessTrusted()` call every `pollInterval` seconds — that **stops
/// itself the moment the answer turns `true`**, so the steady state after a
/// grant is zero timers and zero work.
///
/// `isTrusted` is `@Published`, so both `AppDelegate` (which re-`start()`s the
/// hot-zone monitor on the transition) and `OnboardingView` (which shows the
/// status row) observe the same source of truth and can never disagree.
///
/// Note: `pollInterval` deliberately trades latency for cost. A grant is
/// noticed within a couple of seconds, which is well inside the time it takes
/// the user to switch back from System Settings.
@MainActor
final class AccessibilityPermissionMonitor: ObservableObject {
    /// Shared instance used by the app (`AppDelegate`, `OnboardingView`).
    /// Tests must construct their own instance with an injected `probe`
    /// instead — `.shared` reads this machine's real TCC state.
    static let shared = AccessibilityPermissionMonitor()

    /// Current, freshly-observed trust state.
    @Published private(set) var isTrusted: Bool

    /// `true` while the retry timer is installed. Always `false` once
    /// permission has been granted — the whole point of the design.
    private(set) var isPolling = false

    /// Seconds between polls while permission is still missing (ТЗ §7).
    let pollInterval: TimeInterval

    private let probe: () -> Bool
    private var timer: Timer?

    /// - Parameters:
    ///   - pollInterval: seconds between `probe` calls while untrusted.
    ///   - probe: trust source. Defaults to the real `AXIsProcessTrusted()`;
    ///     tests inject a closure they can flip.
    init(pollInterval: TimeInterval = 2, probe: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.pollInterval = pollInterval
        self.probe = probe
        self.isTrusted = probe()
    }

    deinit {
        timer?.invalidate()
    }

    /// Re-reads the live state and publishes it. Called by the poll timer, by
    /// the onboarding "Recheck" button, and whenever the onboarding window is
    /// (re)opened.
    /// - Returns: the freshly-read trust state.
    @discardableResult
    func recheck() -> Bool {
        let trusted = probe()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        if trusted {
            // Granted: nothing left to watch for.
            stopPolling()
        }
        return trusted
    }

    /// Starts the poll if — and only if — permission is still missing.
    /// Idempotent: calling it repeatedly never stacks timers.
    func startPollingIfNeeded() {
        guard !recheck() else { return }
        guard !isPolling else { return }

        isPolling = true
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        }
        // `.common` so the poll keeps running while a menu is tracking or a
        // window is being resized.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        isPolling = false
    }

    /// Raises macOS's own "app would like to control this computer" dialog,
    /// which carries the "Open System Settings" button (ТЗ §7), and starts
    /// watching for the user's answer.
    func requestAccess() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if trusted != isTrusted {
            isTrusted = trusted
        }
        startPollingIfNeeded()
    }
}
