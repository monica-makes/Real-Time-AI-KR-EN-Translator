import SwiftUI
import Observation

/// Where the live translation screen's frame sits: the language row ("They speak" / "I speak")
/// under the Dynamic Island, and the mic control near the bottom. The Voice & Honorifics cards
/// sit `menuBelowMic` under the mic's resting spot, so they move with it. The setup screens' back
/// buttons sit at the language row's top too. Debug builds tune both from the screen's debug panel
/// (LAYOUT); values last until the app relaunches.
@Observable
final class LiveLayoutTuning {
    static let shared = LiveLayoutTuning()

    static let defaultLanguagesTop: CGFloat = 8    // language row top, below the safe-area top
    static let defaultMicBottom: CGFloat = 32      // mic control bottom, above the screen's bottom edge (Mic Y 700 on iPhone 17)
    /// The cards' bottom sits this much lower than the mic's resting bottom
    static let menuBelowMic: CGFloat = 8
    /// The lowest box (the cards) stays at least this far above the screen's bottom edge
    static let minBottomMargin: CGFloat = 20
    static let micHeight: CGFloat = 80

    var languagesTop = defaultLanguagesTop
    var micBottom = defaultMicBottom

    /// The lowest the mic can rest: its cards then sit `minBottomMargin` above the screen's edge
    static var lowestMicBottom: CGFloat { minBottomMargin + menuBelowMic }

    /// The Voice & Honorifics cards' bottom, above the screen's bottom edge
    var micMenuBottom: CGFloat { micBottom - Self.menuBelowMic }

    var isDefault: Bool {
        languagesTop == Self.defaultLanguagesTop && micBottom == Self.defaultMicBottom
    }

    func reset() {
        languagesTop = Self.defaultLanguagesTop
        micBottom = Self.defaultMicBottom
    }
}
