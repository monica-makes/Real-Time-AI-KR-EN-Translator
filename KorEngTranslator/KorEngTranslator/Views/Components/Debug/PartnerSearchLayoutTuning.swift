import SwiftUI
import Observation

/// Where the "Looking for your partner..." screen (English and Korean) puts things: the title,
/// the loading dots `titleDotsGap` under it, the body `dotsBodyGap` under the dots, and the
/// headphones card. The title and card follow the home screen (HomeLayoutTuning) until they're
/// tuned here. Debug builds tune them from the PARTNER SEARCH panel (keyboard button, bottom right;
/// `-partnerSearchLayoutPanel` opens it at launch); values last until the app relaunches.
@Observable
final class PartnerSearchLayoutTuning {
    static let shared = PartnerSearchLayoutTuning()

    static let defaultTitleDotsGap: CGFloat = 12   // title's last line to the dots
    static let defaultDotsBodyGap: CGFloat = 20    // dots to the body's first line
    static let defaultDotSpacing: CGFloat = 8      // between the loading dots
    static let defaultBodyLineSpacing: CGFloat = 5 // between the body's two lines (22pt line height at 17pt)

    /// nil follows the home screen's title top / card top
    var titleTopOverride: CGFloat?
    var cardTopOverride: CGFloat?
    var titleDotsGap = defaultTitleDotsGap
    var dotsBodyGap = defaultDotsBodyGap
    var dotSpacing = defaultDotSpacing
    var bodyLineSpacing = defaultBodyLineSpacing

    /// Title top, from the safe-area top
    var titleTop: CGFloat { titleTopOverride ?? HomeLayoutTuning.shared.textTop }
    /// Headphones card top, from the safe-area top
    var cardTop: CGFloat { cardTopOverride ?? HomeLayoutTuning.shared.cardTop }

    var isDefault: Bool {
        titleTopOverride == nil && cardTopOverride == nil
            && titleDotsGap == Self.defaultTitleDotsGap && dotsBodyGap == Self.defaultDotsBodyGap
            && dotSpacing == Self.defaultDotSpacing && bodyLineSpacing == Self.defaultBodyLineSpacing
    }

    func reset() {
        titleTopOverride = nil
        cardTopOverride = nil
        titleDotsGap = Self.defaultTitleDotsGap
        dotsBodyGap = Self.defaultDotsBodyGap
        dotSpacing = Self.defaultDotSpacing
        bodyLineSpacing = Self.defaultBodyLineSpacing
    }

    /// For pasting into a chat or the code
    var summary: String {
        func pt(_ value: CGFloat) -> String { String(format: "%.0f", value) }
        return """
        Partner search layout (pt from the safe-area top)
        title top: \(pt(titleTop))\(titleTopOverride == nil ? " (home's)" : "")
        title-dots gap: \(pt(titleDotsGap))
        dots-body gap: \(pt(dotsBodyGap))
        dot spacing: \(pt(dotSpacing))
        body line spacing: \(pt(bodyLineSpacing))
        card top: \(pt(cardTop))\(cardTopOverride == nil ? " (home's)" : "")
        """
    }
}
