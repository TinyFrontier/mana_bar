import SwiftUI

/// Exact color values from docs/design/design-spec.md §2. Centralized so
/// `RingView`/`DetailCardView`/`PanelView` reference the same constants
/// instead of re-deriving hex values in three places.
enum ManaColor {
    static let panelBackground = Color.black
    static let cardBackground = Color.black

    static let ringCenter = Color(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2e / 255)
    static let ringBase = Color.white.opacity(0.09)
    static let spinnerStroke = Color.white.opacity(0.85)

    static let healthy = Color(red: 0x30 / 255, green: 0xd1 / 255, blue: 0x58 / 255)
    static let warning = Color(red: 0xff / 255, green: 0xd6 / 255, blue: 0x0a / 255)
    static let critical = Color(red: 0xff / 255, green: 0x45 / 255, blue: 0x3a / 255)
    static let unavailable = Color(red: 0x6b / 255, green: 0x6b / 255, blue: 0x70 / 255)

    static let progressBarTrack = Color.white.opacity(0.16)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.92)
    static let textFaint = Color.white.opacity(0.62)
    static let textVeryFaint = Color.white.opacity(0.5)
    static let glyphDimmed = Color.white.opacity(0.45)
    static let percentDimmed = Color.white.opacity(0.4)

    static let exhaustedText = Color(red: 0xff / 255, green: 0x9f / 255, blue: 0x8f / 255)
    static let separator = Color.white.opacity(0.1)

    static let reloginBackground = Color.white
    static let reloginBackgroundHover = Color.white.opacity(0.82)
    static let reloginText = Color(red: 0x0b / 255, green: 0x0b / 255, blue: 0x0c / 255)

    // design-spec.md §3.1/§3.6 specify these against the spec's own dark
    // background; at 0.45 opacity + 24-30pt radius they read as a grimy
    // smudge once the panel floats over an arbitrary light desktop
    // background (live feedback: "непонятная тень на светлом фоне"). Toned
    // down (paired with smaller `.shadow(radius:)` values at the two call
    // sites, PanelView/DetailCardView) so the shadow stays a subtle
    // "floating" cue on light backgrounds while still reading normally on
    // dark ones.
    static let panelShadow = Color.black.opacity(0.2)
    static let cardShadow = Color.black.opacity(0.2)

    static let errorBadgeBackground = Color(red: 0xff / 255, green: 0xd6 / 255, blue: 0x0a / 255)
}

extension UsageLevel {
    /// Maps the pure threshold result onto the design-spec ring/bar color.
    var color: Color {
        switch self {
        case .healthy: return ManaColor.healthy
        case .warning: return ManaColor.warning
        case .critical: return ManaColor.critical
        }
    }
}
