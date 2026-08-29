import AppKit
import SwiftUI

/// Real per-service logos (design-spec.md §3.3, §3.7.1 — "Логотип сервиса"),
/// bundled as vector image sets in `Sources/Resources/Assets.xcassets`:
/// - `ServiceClaudeLogo` — the actual Claude mark, original colors
///   (`#D97757`), rendered as-is.
/// - `ServiceOpenAILogo` — the actual OpenAI mark, template-rendered so it
///   can be tinted (white on Mana's dark panel/card backgrounds).
extension ServiceID {
    /// Name of this service's entry in `Assets.xcassets`.
    var logoAssetName: String {
        switch self {
        case .claude: return "ServiceClaudeLogo"
        case .chatgpt: return "ServiceOpenAILogo"
        }
    }

    /// SF Symbol fallback for `ServiceLogo`, used only when the named asset
    /// can't be loaded (e.g. a bundle without `Assets.xcassets`) — chosen to
    /// be visually distinct at 17px inside the ring / card header.
    var glyphSystemName: String {
        switch self {
        case .claude: return "sparkles"
        case .chatgpt: return "bubble.left.fill"
        }
    }
}

/// One service's logo, sized to fit a `size`×`size` container: the real
/// vector asset when the app bundle has it, an SF Symbol placeholder
/// otherwise. `.foregroundStyle` applied by the caller reaches both — it
/// tints the SF Symbol and the template-rendered OpenAI asset, and is a
/// harmless no-op on the original-rendered Claude asset (design-spec.md
/// §3.3: "цветной для Claude, монохром/white для OpenAI").
struct ServiceLogo: View {
    let serviceID: ServiceID
    /// Container size (design-spec.md §3.3: 17×17 glyph container in
    /// `RingView`; also used for `DetailCardView`'s header).
    var size: CGFloat = 17
    /// Fallback-only: how large the SF Symbol renders relative to `size` —
    /// callers pass whatever their pre-logo placeholder used, so the
    /// fallback path looks identical to before this asset existed.
    var fallbackScale: CGFloat = 0.62
    var fallbackWeight: Font.Weight = .semibold

    /// Cheap existence probe — `Image(_:)` renders nothing (not a crash) for
    /// a missing asset name, so this is what actually drives the fallback.
    private var hasAsset: Bool {
        NSImage(named: NSImage.Name(serviceID.logoAssetName)) != nil
    }

    var body: some View {
        Group {
            if hasAsset {
                Image(serviceID.logoAssetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.74, height: size * 0.74)
            } else {
                Image(systemName: serviceID.glyphSystemName)
                    .font(.system(size: size * fallbackScale, weight: fallbackWeight))
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    HStack(spacing: 16) {
        ServiceLogo(serviceID: .claude)
        ServiceLogo(serviceID: .chatgpt).foregroundStyle(.white)
    }
    .padding()
    .background(Color.black)
}
