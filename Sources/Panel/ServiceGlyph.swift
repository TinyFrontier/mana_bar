import SwiftUI

/// TODO: replace with the real per-service logo asset (design-spec.md §3.3,
/// §3.7.1 — "Логотип сервиса"). SF Symbol placeholders only, chosen to be
/// visually distinct at 17px inside the ring / card header.
extension ServiceID {
    var glyphSystemName: String {
        switch self {
        case .claude: return "sparkles"
        case .chatgpt: return "bubble.left.fill"
        }
    }
}
