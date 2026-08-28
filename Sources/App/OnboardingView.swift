import ApplicationServices
import SwiftUI

/// First-run onboarding content (ТЗ §7): explains why Accessibility
/// permission is useful, offers the System Settings prompt for it, and
/// shows per-provider token-source status (found/not found + install/login
/// hint) — no manual token-entry form anywhere, per ТЗ §4.2/§7.
///
/// Hosted by `AppDelegate` in a plain `NSWindow` (see `showOnboardingWindow`
/// there): shown automatically on first launch (`AppSettings
/// .hasCompletedOnboarding == false`) and reachable again any time from the
/// status-bar menu.
struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var claudeFinding: CredentialSourceStatus.Finding?
    @State private var chatgptFinding: CredentialSourceStatus.Finding?

    /// Called when the user dismisses the screen ("Done"). `AppDelegate`
    /// closes the hosting window from this.
    var onDone: () -> Void = {}

    private let accessibilityPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Mana").font(.title2).bold()
                    Text("Two quick things, then you're set.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                accessibilitySection
                Divider()
                credentialsSection
                Divider()
                fallbackNote

                HStack {
                    Spacer()
                    Button("Done") {
                        settings.hasCompletedOnboarding = true
                        onDone()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 480, height: 580)
        .task { await refreshCredentialStatus() }
        .onReceive(accessibilityPoll) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    // MARK: - 1. Accessibility (ТЗ §7, §11)

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. Accessibility permission").font(.headline)
            Text("""
            Mana watches for your cursor reaching the screen edge, so the panel \
            can slide out automatically. That needs Accessibility access.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                statusRow(granted: accessibilityGranted, foundLabel: "Granted", missingLabel: "Not granted")
                Spacer()
                Button(accessibilityGranted ? "Granted" : "Open System Settings…") {
                    requestAccessibility()
                }
                .disabled(accessibilityGranted)
            }
        }
    }

    private func requestAccessibility() {
        // AXIsProcessTrustedWithOptions with the prompt option raises
        // macOS's own "not trusted" dialog, which includes an
        // "Open System Settings" button (ТЗ §7).
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 2. Token sources (ТЗ §4.2, §7)

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. Token sources").font(.headline)
            Text("""
            Mana reuses the login already stored by these CLI tools — there's \
            no token to paste in.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            credentialRow(serviceID: .claude, finding: claudeFinding)
            credentialRow(serviceID: .chatgpt, finding: chatgptFinding)

            Button("Recheck") {
                Task { await refreshCredentialStatus() }
            }
        }
    }

    private func credentialRow(serviceID: ServiceID, finding: CredentialSourceStatus.Finding?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                statusRow(
                    granted: finding == .found,
                    foundLabel: "Found",
                    missingLabel: finding == nil ? "Checking…" : (finding == .needsKeychainPermission ? "Needs permission" : "Not found")
                )
                Text(serviceID.displayName).font(.callout).bold()
            }
            if finding == .notFound {
                Text(CredentialSourceStatus.hint(serviceID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if finding == .needsKeychainPermission {
                // ТЗ §7 addendum: the login is already there — this is a
                // one-time Keychain grant, not an install/login step.
                Text(CredentialSourceStatus.permissionHint(serviceID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusRow(granted: Bool, foundLabel: String, missingLabel: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(granted ? foundLabel : missingLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Fallback note (ТЗ §7, §11)

    private var fallbackNote: some View {
        Text("""
        Tip: with or without Accessibility access, you can always show or hide \
        the panel from the Mana icon in the menu bar.
        """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshCredentialStatus() async {
        claudeFinding = nil
        chatgptFinding = nil
        async let claude = CredentialSourceStatus.status(.claude)
        async let chatgpt = CredentialSourceStatus.status(.chatgpt)
        claudeFinding = await claude
        chatgptFinding = await chatgpt
    }
}

#Preview {
    OnboardingView()
}
