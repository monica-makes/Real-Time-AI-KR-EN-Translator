import SwiftUI
import Observation

/// Where the live translation screen's frame sits: the language row ("They speak" / "I speak")
/// under the Dynamic Island, and the mic control near the bottom. The Voice & Honorifics cards
/// sit `menuBelowMic` under the mic's resting spot, so they move with it. Debug builds tune both
/// from the screen's debug panel (LAYOUT); values last until the app relaunches.
@Observable
final class LiveLayoutTuning {
    static let shared = LiveLayoutTuning()

    static let defaultLanguagesTop: CGFloat = 32   // language row top, below the safe-area top
    static let defaultMicBottom: CGFloat = 70      // mic control bottom, above the screen's bottom edge
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

#if DEBUG
/// LAYOUT section for the live screen's debug panel: Languages Y moves the language row, Mic Y
/// moves the mic control and the cards with it (both as tops from the safe-area top, bigger is
/// lower). The mic stops where the cards would come within 20pt of the screen's bottom edge.
struct LiveLayoutDebugSection: View {
    private var layout: LiveLayoutTuning { .shared }

    var body: some View {
        // Mic Y is the mic control's top, from the safe-area top like the other layout panels
        let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
        let fromSafeTop = (window?.bounds.height ?? 874) - (window?.safeAreaInsets.top ?? 62)
        let micY = fromSafeTop - layout.micBottom - LiveLayoutTuning.micHeight
        let maxMicY = fromSafeTop - LiveLayoutTuning.lowestMicBottom - LiveLayoutTuning.micHeight

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LAYOUT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Button("Reset") {
                    withAnimation(.easeInOut(duration: 0.25)) { layout.reset() }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .disabled(layout.isDefault)
                .opacity(layout.isDefault ? 0.4 : 1)
            }
            LayoutTunerRow("Languages Y", value: layout.languagesTop, range: 0...240) { layout.languagesTop = $0 }
            LayoutTunerRow("Mic Y", value: micY, range: min(300, micY)...max(maxMicY, micY)) {
                layout.micBottom = max(LiveLayoutTuning.lowestMicBottom, fromSafeTop - LiveLayoutTuning.micHeight - $0)
            }
        }
        .frame(width: 280)
    }
}
#endif
