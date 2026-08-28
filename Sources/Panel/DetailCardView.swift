import SwiftUI

/// Flyout detail card shown to the left of the panel island when a ring is
/// hovered (ТЗ §3.4; design-spec.md §3.6–§3.7): service name/logo, a
/// "Current session" row (relative reset time) and an "All models" row
/// (absolute reset time), each with a 5px progress bar. On `stale`/
/// `unavailable` status the progress rows are replaced by
/// `error.userDescription` plus a "Re-login via CLI" stub button
/// (design-spec.md §3.7.4, ТЗ §4.3). Fade+slide entrance/exit animation is
/// owned by the parent `PanelView`, which controls this view's presence.
struct DetailCardView: View {
    let serviceID: ServiceID
    let status: ServiceStatus
    /// Ring/bar color thresholds (ТЗ §3.3, §6), same value `RingView` uses —
    /// threaded in by `PanelView` from `AppSettings`.
    var thresholds: UsageThresholds = .default
    /// Error-state action button (ТЗ §4.3): triggers the same interactive
    /// manual refresh as the status-bar "Refresh Now" menu item, for both the
    /// `.keychainAccessDenied` "Grant access" button and every other error's
    /// "Re-login via CLI" button — Mana never collects a token itself, so
    /// either way the next successful poll is what actually clears the error.
    /// Defaults to a no-op for Previews and other contexts with nothing to
    /// wire it to.
    var onErrorAction: () -> Void = {}

    private let cardWidth: CGFloat = 300

    private var isLoadingState: Bool {
        if case .loading = status { return true }
        return false
    }

    private var isErrorState: Bool { status.error != nil }

    private var usage: ServiceUsage? { status.usage }

    private var modelWeeklyWindows: [UsageWindow] {
        usage?.windows.filter {
            if case .modelWeekly = $0.kind { return true }
            return false
        } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isErrorState {
                errorSection
            } else if isLoadingState {
                loadingSection
            } else {
                dataSection
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 18, trailing: 18))
        .frame(width: cardWidth, alignment: .leading)
        .background(ManaColor.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .trailing) {
            CardArrow()
                .fill(ManaColor.cardBackground)
                .frame(width: 14, height: 30)
                .offset(x: 12)
        }
        .shadow(color: ManaColor.cardShadow, radius: 30, x: 0, y: 22)
    }

    // MARK: Header (design-spec.md §3.7.1)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: serviceID.glyphSystemName)
                .font(.system(size: 17 * 0.8, weight: .semibold))
                .foregroundStyle(ManaColor.textPrimary)
                .frame(width: 17, height: 17)
            Text("\(serviceID.displayName) Usage")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(ManaColor.textPrimary)
        }
    }

    // MARK: Data state (design-spec.md §3.7.2, §3.7.3)

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let sessionWindow = usage?.sessionWindow {
                sectionRow(title: "Current session", window: sessionWindow, style: .relative, animatesFill: true)
            }
            if let weeklyWindow = usage?.weeklyWindow {
                sectionRow(title: "All models", window: weeklyWindow, style: .absolute, animatesFill: false)
            }
            ForEach(Array(modelWeeklyWindows.enumerated()), id: \.offset) { _, window in
                sectionRow(title: window.label, window: window, style: .absolute, animatesFill: false)
            }
            if let sessionWindow = usage?.sessionWindow, sessionWindow.usedPercent >= 100 {
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

    // MARK: Error state (design-spec.md §3.7.4, §8.2; ТЗ §4.3)

    private var isKeychainAccessDenied: Bool {
        if case .keychainAccessDenied = status.error { return true }
        return false
    }

    private var errorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status.error?.userDescription ?? "")
                .font(.system(size: 13))
                .lineSpacing(13 * 0.45)
                .foregroundStyle(ManaColor.textFaint)

            if isKeychainAccessDenied {
                // ТЗ addendum (silent-path Keychain fix): the permission is a
                // one-time grant, not a re-login — spell that out so the user
                // knows a single click fixes it for good.
                Text("Разрешение выдаётся один раз: подтвердите «Always Allow» в системном диалоге Keychain.")
                    .font(.system(size: 11.5))
                    .lineSpacing(11.5 * 0.4)
                    .foregroundStyle(ManaColor.textVeryFaint)
            }

            Button(action: onErrorAction) {
                Text(isKeychainAccessDenied ? "Grant access" : "Re-login via CLI")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ManaColor.reloginText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .background(ManaColor.reloginBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 16)
    }
}

/// design-spec.md §3.6: 14×30 quadratic-bezier pointer, positioned at the
/// card's trailing edge, vertically centered on the hovered ring.
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
        DetailCardView(serviceID: .chatgpt, status: .stale(.placeholder, .connectionFailed))
        DetailCardView(serviceID: .claude, status: .loading)
    }
    .padding(40)
    .background(Color.gray)
}
