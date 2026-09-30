import SwiftUI
import Observation

/// Layout of the home (language select) screen: the title + body text and the language cards.
/// The Create / Join screen after it puts its title, body and cards in the same places.
///
/// Defaults are today's layout. Debug builds can try other values live from the home screen's
/// Layout panel (ladybug, bottom right); they last until the app relaunches, then "Copy" hands
/// them over for the code. The cards start at Card Y and the text stacks up from them: a bigger
/// gap moves the text up instead of moving the cards down, and a taller card grows downward with
/// its language name pinned to its bottom.
@Observable
final class HomeLayoutTuning {
    static let shared = HomeLayoutTuning()

    // Today's layout (points from the top of the safe area)
    static let defaultTextTop: CGFloat = 166   // title top; the 40pt title ends 16pt above the body
    static let defaultBodyTop: CGFloat = 222   // the two-line body (46pt) ends 44pt above the cards
    static let defaultCardTop: CGFloat = 312
    static let defaultCardHeight: CGFloat = 216
    static let defaultCardRadius: CGFloat = 20   // every card and box in the app uses it (AppStyle.cornerRadius)
    static let defaultTitleBodyGap: CGFloat = 16

    /// Every page after home sets its body this much closer to its title than home does;
    /// nothing below the body moves
    static let bodyLiftAfterHome: CGFloat = 4

    /// Title bottom to body top. Nil keeps today's spacing.
    var titleBodyGap: CGFloat? = nil
    /// Body bottom to card top. Nil keeps today's spacing.
    var textCardsGap: CGFloat? = nil
    /// Card Y: the cards' top; the text stacks up from it
    var cardTop: CGFloat = defaultCardTop
    var cardHeight: CGFloat = defaultCardHeight
    var cardRadius: CGFloat = defaultCardRadius

    /// Rendered heights, for turning gaps into positions
    private(set) var titleHeight: CGFloat = 0
    private(set) var bodyHeight: CGFloat = 0

    var bodyTop: CGFloat {
        if let gap = textCardsGap, bodyHeight > 0 {
            return cardTop - gap - bodyHeight
        }
        return cardTop - (Self.defaultCardTop - Self.defaultBodyTop)
    }

    /// Top of the title
    var textTop: CGFloat {
        if let gap = titleBodyGap, titleHeight > 0 {
            return bodyTop - gap - titleHeight
        }
        return bodyTop - (Self.defaultBodyTop - Self.defaultTextTop)
    }

    /// The gaps as currently laid out
    var currentTitleBodyGap: CGFloat { bodyTop - textTop - titleHeight }

    /// Home's title-body gap for the pages after it to copy (today's 16 until home has measured its title)
    var titleBodySpacing: CGFloat {
        titleHeight > 0 ? currentTitleBodyGap : titleBodyGap ?? Self.defaultTitleBodyGap
    }
    var currentTextCardsGap: CGFloat { cardTop - bodyTop - bodyHeight }

    /// Lowest the title can start: with the body touching the cards
    var lowestTextTop: CGFloat { textTop + currentTextCardsGap }

    /// Moves the title and body together; the cards stay put, so the text-cards gap changes
    func moveText(toTop top: CGFloat) {
        textCardsGap = max(0, currentTextCardsGap + textTop - top)
    }

    var isDefault: Bool {
        titleBodyGap == nil && textCardsGap == nil && cardTop == Self.defaultCardTop
            && cardHeight == Self.defaultCardHeight && cardRadius == Self.defaultCardRadius
    }

    /// The typewriter empties the title between cycles, so only real line heights count
    func noteTitleHeight(_ height: CGFloat) {
        if height > 1, abs(height - titleHeight) > 0.25 { titleHeight = height }
    }

    /// The subtitle alternates English and Korean; keeping the taller one stops the text
    /// from shifting by a fraction of a point each time the language changes
    func noteBodyHeight(_ height: CGFloat) {
        if height > bodyHeight + 0.25 { bodyHeight = height }
    }

    func reset() {
        titleBodyGap = nil
        textCardsGap = nil
        cardTop = Self.defaultCardTop
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
/// cards' position, height and corner radius
struct HomeLayoutDebugPanel: View {
    private var layout: HomeLayoutTuning { .shared }

    var body: some View {
        LayoutTunerPanel("HOME LAYOUT", launchArgument: "-homeLayoutPanel", isDefault: layout.isDefault,
                         onReset: { layout.reset() }, summary: { layout.summary }) {
            LayoutTunerRow("Text Y", value: layout.textTop, range: 0...max(1, layout.lowestTextTop)) { layout.moveText(toTop: $0) }
            LayoutTunerRow("Title ↔ body", value: layout.currentTitleBodyGap, range: 0...120) { layout.titleBodyGap = $0 }
            LayoutTunerRow("Text ↔ cards", value: layout.currentTextCardsGap, range: 0...240) { layout.textCardsGap = $0 }
            LayoutTunerRow("Card Y", value: layout.cardTop, range: 0...700) { layout.cardTop = $0 }
            LayoutTunerRow("Card height", value: layout.cardHeight, range: 120...400) { layout.cardHeight = $0 }
            LayoutTunerRow("Card radius", value: layout.cardRadius, range: 0...60) { layout.cardRadius = $0 }
        }
    }
}
#endif
