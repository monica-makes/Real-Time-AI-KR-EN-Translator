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

#if DEBUG
/// PARTNER SEARCH panel for the "Looking for your partner..." screen (keyboard button, bottom right)
struct PartnerSearchLayoutPanel: View {
    private var layout: PartnerSearchLayoutTuning { .shared }

    var body: some View {
        LayoutTunerPanel("PARTNER SEARCH", toggleIcon: "keyboard.fill",
                         launchArgument: "-partnerSearchLayoutPanel",
                         isDefault: layout.isDefault, onReset: { layout.reset() },
                         summary: { layout.summary }) {
            LayoutTunerRow("Title Y", value: layout.titleTop, range: 0...500) { layout.titleTopOverride = max(0, $0) }
            LayoutTunerRow("Title ↔ dots", value: layout.titleDotsGap, range: 0...60) { layout.titleDotsGap = max(0, $0) }
            LayoutTunerRow("Dots ↔ body", value: layout.dotsBodyGap, range: 0...80) { layout.dotsBodyGap = max(0, $0) }
            LayoutTunerRow("Dot spacing", value: layout.dotSpacing, range: 0...40) { layout.dotSpacing = max(0, $0) }
            LayoutTunerRow("Body lines", value: layout.bodyLineSpacing, range: 0...24) { layout.bodyLineSpacing = max(0, $0) }
            LayoutTunerRow("Card Y", value: layout.cardTop, range: 0...700) { layout.cardTopOverride = max(0, $0) }
        }
    }
}

/// A setup screen's Debug Controls card that folds away: "Hide" above its top-right corner tucks it
/// into a ladybug button (bottom right, left of the layout panel's button), and the ladybug brings
/// it back. Remembered across launches.
struct CollapsibleDebugControls<Panel: View>: View {
    @AppStorage("debugControlsHidden") private var isHidden = false
    @ViewBuilder let panel: () -> Panel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer(minLength: 0)
                .frame(maxWidth: .infinity)  // full width, so the folded ladybug sits at the right
            if isHidden {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isHidden = false }
                } label: {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .accessibilityLabel("Show debug controls")
                // Left of the layout panel's toggle (16pt in, 44pt wide), on the same line
                .padding(.trailing, 16 + 44 + 8)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isHidden = true }
                } label: {
                    Label("Hide", systemImage: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                }
                .padding(.trailing, 20)
                panel()
                    .padding(.horizontal, 20)
                    // Clear of the layout panel's toggle in the bottom-right corner
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .hiddenWhileRecording()
    }
}
#endif
