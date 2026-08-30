import SwiftUI

/// Flyout detail card shown to the left of the panel island when a ring is
/// hovered (ТЗ §3.4; design-spec.md §3.6–§3.7): service name/logo, a
/// "Current session" row (relative reset time) and an "All models" row
/// (absolute reset time), each with a 5px progress bar.
///
/// Error handling is per-case (ТЗ §4.3 live-feedback fix — the old one-size-
/// -fits-all "Re-login via CLI" button was actively wrong for a rate limit,
/// where a manual refresh can't do anything until the cooldown elapses):
/// - `.stale` (last-good data + an error): the progress rows stay visible,
///   with a compact one-line warning underneath — never the full error
///   block, so a transient failure never makes numbers disappear.
/// - `.unavailable(.rateLimited)`: explanatory text plus, when the
///   coordinator's cooldown deadline is known, "in ~N min"/"at HH:MM" —
///   deliberately NO button (see `errorSection`).
/// - `.unavailable(.keychainAccessDenied)`: "Grant access" button.
/// - `.unavailable(.notLoggedIn / .sessionExpired / .missingScope)`: a CLI
///   login hint plus "Re-login via CLI".
/// - `.unavailable(.connectionFailed / .requestFailed / .decodingFailed)`:
///   "Retry" button.
///
/// Fade+slide entrance/exit animation is owned by the parent `PanelView`,
/// which controls this view's presence.
struct DetailCardView: View {
    let serviceID: ServiceID
    let status: ServiceStatus
    /// Ring/bar color thresholds (ТЗ §3.3, §6), same value `RingView` uses —
    /// threaded in by `PanelView` from `AppSettings`.
    var thresholds: UsageThresholds = .default
    /// Which screen edge the panel docks to (ТЗ §6) — threaded in by
    /// `PanelView` so the card's arrow points back at the island regardless
    /// of which side that island actually lives on. Defaults to `.right`
    /// (the original/only behavior) so every existing call site — including
    /// the `#Preview` below — keeps compiling unchanged.
    var edge: PanelEdge = .right
    /// Error-state action button (ТЗ §4.3): triggers the same interactive
    /// manual refresh as the status-bar "Refresh Now" menu item, for both the
    /// `.keychainAccessDenied` "Grant access" button and every other error's
    /// "Re-login via CLI" button — Mana never collects a token itself, so
    /// either way the next successful poll is what actually clears the error.
    /// Defaults to a no-op for Previews and other contexts with nothing to
    /// wire it to.
    var onErrorAction: () -> Void = {}
    /// `PanelModel.refreshingServiceIDs.contains(serviceID)`, threaded in by
    /// `PanelView` — shows a small in-progress cue (header spinner) for the
    /// duration of a manual refresh or the launch-time re-check of a
    /// disk-cache-seeded snapshot, without hiding whatever data is already
    /// on screen (ТЗ §4.3 live-feedback fix).
    var isRefreshing: Bool = false
    /// `PanelModel.cooldownUntil[serviceID]`, threaded in by `PanelView` —
    /// only meaningful for `.rateLimited`, see `errorSection`.
    var cooldownUntil: Date? = nil
    /// `PanelModel.timedOutServiceIDs.contains(serviceID)`, threaded in by
    /// `PanelView` — picks the honest wording for `.connectionFailed`
    /// (see `UsageErrorCopy`).
    var timedOut: Bool = false

    private var errorText: String {
        guard let error = status.error else { return "" }
        return UsageErrorCopy.text(for: error, timedOut: timedOut)
    }

    private let cardWidth: CGFloat = 300

    private var isErrorState: Bool { status.error != nil }

    private var usage: ServiceUsage? { status.usage }

    private func modelWeeklyWindows(in usage: ServiceUsage) -> [UsageWindow] {
        usage.windows.filter {
            if case .modelWeekly = $0.kind { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let usage {
                // `.ready` (no error) and `.stale` (has last-good data, plus
                // an error) both land here: the fix for the bug where `.stale`
                // used to hit `errorSection` and hide the numbers entirely.
                // `.stale` gets the same progress rows PLUS a compact warning
                // line — never the full button/hint block, which is only for
                // "no data at all" (ТЗ §4.3).
                dataSection(usage: usage)
                if status.error != nil {
                    staleWarningRow(errorText)
                }
            } else if isErrorState {
                errorSection
            } else {
                loadingSection
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 18, trailing: 18))
        .frame(width: cardWidth, alignment: .leading)
        .background(ManaColor.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: edge == .right ? .trailing : .leading) {
            // `CardArrow` is drawn pointing right (toward an island on the
            // card's trailing side); for a left-edge dock the island sits on
            // the card's *leading* side instead, so the shape is mirrored in
            // place (flip around its own center) rather than redrawn, and
            // pinned to the card's leading edge with the offset sign flipped
            // to match (ТЗ §6).
            CardArrow()
                .fill(ManaColor.cardBackground)
                .frame(width: 14, height: 30)
                .scaleEffect(x: edge == .right ? 1 : -1, y: 1)
                .offset(x: edge == .right ? 12 : -12)
        }
        // design-spec.md §3.6, tuned down from the spec's dark-background
        // value — see ColorPalette.swift.
        .shadow(color: ManaColor.cardShadow, radius: 16, x: 0, y: 12)
    }

    // MARK: Header (design-spec.md §3.7.1)

    private var header: some View {
        HStack(spacing: 10) {
            ServiceLogo(serviceID: serviceID, size: 17, fallbackScale: 0.8)
                .foregroundStyle(ManaColor.textPrimary)
            Text("\(serviceID.displayName) Usage")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(ManaColor.textPrimary)
            if isRefreshing {
                Spacer(minLength: 8)
                // ТЗ §4.3 live-feedback fix: the only visible cue that a
                // manual refresh (or the launch-time re-check of a
                // disk-cache-seeded snapshot) is actually in flight — never
                // hides `dataSection`/`errorSection`, just sits alongside.
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
    }

    // MARK: Data state (design-spec.md §3.7.2, §3.7.3)

    private func dataSection(usage: ServiceUsage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let sessionWindow = usage.sessionWindow {
                sectionRow(title: "Current session", window: sessionWindow, style: .relative, animatesFill: true)
            }
            if let weeklyWindow = usage.weeklyWindow {
                sectionRow(title: "All models", window: weeklyWindow, style: .absolute, animatesFill: false)
            }
            ForEach(Array(modelWeeklyWindows(in: usage).enumerated()), id: \.offset) { _, window in
                sectionRow(title: window.label, window: window, style: .absolute, animatesFill: false)
            }
            if let sessionWindow = usage.sessionWindow, sessionWindow.usedPercent >= 100 {
                exhaustedMessage(sessionWindow: sessionWindow)
            }
        }
        .padding(.top, 14)
    }

    private enum ResetStyle { case relative, absolute }

    private func resetText(for window: UsageWindow, style: ResetStyle) -> String {
        switch style {
        case .relative: return ResetFormatter.relative(resetsAt: window.resetsAt)
        case .absolute: return ResetFormatter.absolute(resetsAt: window.resetsAt)
        }
    }

    @ViewBuilder
    private func sectionRow(title: String, window: UsageWindow, style: ResetStyle, animatesFill: Bool) -> some View {
        let percent = window.usedPercent
        let fraction = min(max(percent / 100, 0), 1)
        let level = UsageLevel.forPercent(percent, thresholds: thresholds)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ManaColor.textSecondary)
                Spacer()
                Text(resetText(for: window, style: style))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(ManaColor.textVeryFaint)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ManaColor.progressBarTrack)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(level.color)
                        .frame(width: max(0, geo.size.width * fraction))
                        .animation(animatesFill ? .easeInOut(duration: 0.24) : nil, value: fraction)
                }
            }
            .frame(height: 5)

            Text("\(Int(percent.rounded()))% Used")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(ManaColor.textFaint)
        }
    }

    /// design-spec.md §1.5, §8.1: shown once the session window hits 100%.
    private func exhaustedMessage(sessionWindow: UsageWindow) -> some View {
        Text("Session limit reached. Mana restores \(ResetFormatter.relativeShort(resetsAt: sessionWindow.resetsAt)).")
            .font(.system(size: 12.5))
            .lineSpacing(12.5 * 0.4)
            .foregroundStyle(ManaColor.exhaustedText)
            .padding(.top, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(ManaColor.separator).frame(height: 1)
            }
    }

    // MARK: Loading state (design-spec.md §8.3)

    private var loadingSection: some View {
        Text("Refreshing…")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ManaColor.textVeryFaint)
            .padding(.top, 16)
    }

    // MARK: Stale state — data visible, compact warning line underneath

    /// design-spec.md doesn't have a dedicated "data + warning" treatment, so
    /// this deliberately stays much quieter than `errorSection`: no button,
    /// small faint text, single line — the numbers above are still the
    /// primary content (ТЗ §4.3: "серое кольцо + текст ошибки, но цифры
    /// остаются видны").
    private func staleWarningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(ManaColor.textVeryFaint)
            Text(text)
                .font(.system(size: 11))
                .lineSpacing(11 * 0.4)
                .foregroundStyle(ManaColor.textVeryFaint)
        }
        .padding(.top, 10)
    }

    // MARK: Error state (design-spec.md §3.7.4, §8.2; ТЗ §4.3) — no data at all

    /// CLI login hint for `.notLoggedIn`/`.sessionExpired`/`.missingScope`:
    /// names the actual CLI tool for this service, since "Re-login via CLI"
    /// alone doesn't say which one.
    private var cliLoginHint: String {
        switch serviceID {
        case .claude: return "Sign in with `claude` in a terminal, then click the button."
        case .chatgpt: return "Sign in with `codex` in a terminal, then click the button."
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(errorText)
                .font(.system(size: 13))
                .lineSpacing(13 * 0.45)
                .foregroundStyle(ManaColor.textFaint)

            switch status.error {
            case .rateLimited?:
                // Live-feedback fix: this used to show a "Re-login via CLI"
                // button that visibly did nothing, because a rate limit isn't
                // an auth problem — manual refresh still respects this exact
                // cooldown (`UsageCoordinator.eligible`). No button at all;
                // just say when Mana will try again on its own.
                if let hint = ResetFormatter.rateLimitRetryHint(cooldownUntil: cooldownUntil) {
                    Text("Retrying automatically \(hint).")
                        .font(.system(size: 11.5))
                        .lineSpacing(11.5 * 0.4)
                        .foregroundStyle(ManaColor.textVeryFaint)
                }

            case .keychainAccessDenied?:
                // ТЗ addendum (silent-path Keychain fix): the permission is a
                // one-time grant, not a re-login — spell that out so the user
                // knows a single click fixes it for good.
                Text("The grant is one-time: choose \u{201C}Always Allow\u{201D} in the Keychain dialog.")
                    .font(.system(size: 11.5))
                    .lineSpacing(11.5 * 0.4)
                    .foregroundStyle(ManaColor.textVeryFaint)
                actionButton(title: "Grant access")

            case .notLoggedIn?, .sessionExpired?, .missingScope?:
                Text(cliLoginHint)
                    .font(.system(size: 11.5))
                    .lineSpacing(11.5 * 0.4)
                    .foregroundStyle(ManaColor.textVeryFaint)
                actionButton(title: "Re-login via CLI")

            case .connectionFailed?, .requestFailed?, .decodingFailed?:
                actionButton(title: "Retry")

            case nil:
                EmptyView()
            }
        }
        .padding(.top, 16)
    }

    private func actionButton(title: String) -> some View {
        Button(action: onErrorAction) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ManaColor.reloginText)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .background(ManaColor.reloginBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// design-spec.md §3.6: 14×30 quadratic-bezier pointer, positioned at the
/// card's trailing edge, vertically centered on the hovered ring. Points
/// right by construction (toward a `.right`-edge dock's island); the
/// `DetailCardView` overlay mirrors it with `.scaleEffect(x: -1)` for a
/// `.left`-edge dock rather than duplicating the path.
private struct CardArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addCurve(
            to: CGPoint(x: 12.2, y: 14.2),
            control1: CGPoint(x: 0, y: 9),
            control2: CGPoint(x: 2, y: 12)
        )
        path.addCurve(
            to: CGPoint(x: 12.2, y: 15.8),
            control1: CGPoint(x: 13.3, y: 14.45),
            control2: CGPoint(x: 13.3, y: 15.55)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: 30),
            control1: CGPoint(x: 2, y: 18),
            control2: CGPoint(x: 0, y: 21)
        )
        path.closeSubpath()
        return path
    }
}

#Preview {
    HStack(alignment: .top, spacing: 24) {
        DetailCardView(serviceID: .claude, status: .ready(.placeholder))
        DetailCardView(serviceID: .claude, status: .unavailable(.keychainAccessDenied))
        DetailCardView(serviceID: .chatgpt, status: .stale(.placeholder, .connectionFailed), isRefreshing: true)
        DetailCardView(serviceID: .claude, status: .loading)
        DetailCardView(
            serviceID: .claude,
            status: .unavailable(.rateLimited(retryAfter: 120)),
            cooldownUntil: Date().addingTimeInterval(120)
        )
        DetailCardView(serviceID: .chatgpt, status: .unavailable(.notLoggedIn))
        DetailCardView(serviceID: .claude, status: .unavailable(.connectionFailed))
        // Left-edge dock: arrow mirrored onto the leading side (ТЗ §6).
        DetailCardView(serviceID: .claude, status: .ready(.placeholder), edge: .left)
    }
    .padding(40)
    .background(Color.gray)
}
