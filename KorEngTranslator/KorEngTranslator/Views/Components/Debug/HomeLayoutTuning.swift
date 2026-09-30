import SwiftUI
import Observation

/// Layout of the home (language select) screen: the title + body text and the language cards.
///
/// Defaults are today's layout. Debug builds can try other values live from the home screen's
/// Layout panel (ladybug, bottom right); they last until the app relaunches, then "Copy" hands
/// them over for the code. The text, body and cards stack top-down: moving the text moves the
/// body and cards with it, and a taller card grows downward with its language name pinned to
/// its bottom.
@Observable
final class HomeLayoutTuning {
    static let shared = HomeLayoutTuning()

    // Today's layout (points from the top of the safe area)
    static let defaultTextTop: CGFloat = AppSpacing.welcomeContentStart - 4   // title top
    static let defaultBodyTop: CGFloat = 240
    static let defaultCardTop: CGFloat = AppSpacing.cardsFromTop + 24
    static let defaultCardHeight: CGFloat = 212
    static let defaultCardRadius: CGFloat = 8

    /// Top of the title; the body and cards follow it
    var textTop: CGFloat = defaultTextTop
    /// Title bottom to body top. Nil keeps today's spacing.
    var titleBodyGap: CGFloat? = nil
    /// Body bottom to card top. Nil keeps today's spacing.
    var textCardsGap: CGFloat? = nil
    var cardHeight: CGFloat = defaultCardHeight
    var cardRadius: CGFloat = defaultCardRadius

    /// Rendered heights, for turning gaps into positions
    private(set) var titleHeight: CGFloat = 0
    private(set) var bodyHeight: CGFloat = 0

    var bodyTop: CGFloat {
        if let gap = titleBodyGap, titleHeight > 0 {
            return textTop + titleHeight + gap
        }
        return textTop + (Self.defaultBodyTop - Self.defaultTextTop)
    }

    var cardTop: CGFloat {
        if let gap = textCardsGap, bodyHeight > 0 {
            return bodyTop + bodyHeight + gap
        }
        return bodyTop + (Self.defaultCardTop - Self.defaultBodyTop)
    }

    /// The gaps as currently laid out
    var currentTitleBodyGap: CGFloat { bodyTop - textTop - titleHeight }
    var currentTextCardsGap: CGFloat { cardTop - bodyTop - bodyHeight }

    var isDefault: Bool {
        textTop == Self.defaultTextTop && titleBodyGap == nil && textCardsGap == nil
            && cardHeight == Self.defaultCardHeight && cardRadius == Self.defaultCardRadius
    }

    /// The typewriter empties the title between cycles, so only real line heights count
    func noteTitleHeight(_ height: CGFloat) {
        if height > 1, abs(height - titleHeight) > 0.25 { titleHeight = height }
    }

    /// The subtitle alternates English and Korean; keeping the taller one stops the cards
    /// from shifting by a fraction of a point each time the language changes
    func noteBodyHeight(_ height: CGFloat) {
        if height > bodyHeight + 0.25 { bodyHeight = height }
    }

    func reset() {
        textTop = Self.defaultTextTop
        titleBodyGap = nil
        textCardsGap = nil
        cardHeight = Self.defaultCardHeight
        cardRadius = Self.defaultCardRadius
    }

    /// For pasting into a chat or the code
    var summary: String {
        func pt(_ value: CGFloat) -> String { String(format: "%.0f", value) }
        return """
        Home layout (pt from the safe-area top)
        title top: \(pt(textTop))
        title-body gap: \(pt(currentTitleBodyGap)) (body top \(pt(bodyTop)))
        text-cards gap: \(pt(currentTextCardsGap)) (cards top \(pt(cardTop)))
        card height: \(pt(cardHeight)) (cards bottom \(pt(cardTop + cardHeight)))
        card corner radius: \(pt(cardRadius))
        """
    }
}

#if DEBUG
/// Ladybug + Layout panel on the home screen: sliders for the text position, the gaps, and the
/// cards' height and corner radius
struct HomeLayoutDebugPanel: View {
    @Bindable private var layout = HomeLayoutTuning.shared
    /// Launch with `-homeLayoutPanel` to start with it open
    @State private var isOpen = ProcessInfo.processInfo.arguments.contains("-homeLayoutPanel")
    /// The panel can sit at the top so it doesn't cover the cards it's tuning
    @State private var panelAtTop = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            if panelAtTop, isOpen { panel }
            Spacer(minLength: 0)
            if !panelAtTop, isOpen { panel }
            if !isOpen {
                HStack {
                    Spacer()
                    ladybug
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var ladybug: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isOpen = true }
        } label: {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.6)))
        }
    }

    /// Compact enough to fit under the cards at today's layout: one line per value
    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("HOME LAYOUT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                smallButton("Reset") {
                    withAnimation(.easeInOut(duration: 0.25)) { layout.reset() }
                }
                .disabled(layout.isDefault)
                .opacity(layout.isDefault ? 0.4 : 1)
                smallButton(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = layout.summary
                    print(layout.summary)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                iconButton(panelAtTop ? "arrow.down" : "arrow.up") {
                    withAnimation(.easeInOut(duration: 0.25)) { panelAtTop.toggle() }
                }
                iconButton("xmark") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isOpen = false }
                }
            }

            row("Text Y", value: layout.textTop, range: 40...420) { layout.textTop = $0 }
            row("Title ↔ body", value: layout.currentTitleBodyGap, range: 0...120) { layout.titleBodyGap = $0 }
            row("Text ↔ cards", value: layout.currentTextCardsGap, range: 0...240) { layout.textCardsGap = $0 }
            row("Card height", value: layout.cardHeight, range: 120...400) { layout.cardHeight = $0 }
            row("Card radius", value: layout.cardRadius, range: 0...60) { layout.cardRadius = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.78))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
        )
        .transition(.move(edge: panelAtTop ? .top : .bottom).combined(with: .opacity))
    }

    /// Label, -, 1pt slider, +, value
    private func row(_ label: String, value: CGFloat, range: ClosedRange<CGFloat>,
                     set: @escaping (CGFloat) -> Void) -> some View {
        let binding = Binding<CGFloat>(get: { value }, set: { set($0.rounded()) })
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 80, alignment: .leading)
            nudge("minus") { set((value - 1).rounded()) }
            Slider(value: binding, in: range)
                .tint(AppColors.gradientPeach)
                .controlSize(.small)
            nudge("plus") { set((value + 1).rounded()) }
            Text(String(format: "%.0f", value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppColors.gradientPeach)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func nudge(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func smallButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
#endif
