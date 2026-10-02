import SwiftUI

/// Both sides of the conversation as chat bubbles, newest at the bottom (AirPods Live
/// Translation style): the partner's on the left in outlined glass, mine on the right in
/// filled glass. Each bubble's bottom row is in this phone's language (larger, primary): my own
/// words in my bubbles, the translation in my partner's. The other language sits on top (smaller,
/// secondary). Words fade in as they're spoken and translated. Older bubbles fade and blur out
/// under the language boxes above.
struct ConversationChatView: View {
    let turns: [ConversationTurn]
    /// This phone's language, for notices like "couldn't translate that"
    let isKorean: Bool

    /// Room under the newest bubble for its glass shadow (about 30pt on iOS 26, 13pt on iOS 27), so
    /// the scroll edge doesn't cut it off. Callers place the chat's bottom this much lower than
    /// where the newest bubble should sit.
    static let bottomShadowRoom: CGFloat = 36
    /// Bubbles take at most this share of the width, like Messages
    private static let maxBubbleShare: CGFloat = 0.8
    private static let sidePadding: CGFloat = 20

    @AppStorage(ChatTextReveal.storageKey) private var revealRaw = ChatTextReveal.defaultStyle.rawValue
    private var tuning: ChatLayoutTuning { .shared }
    @State private var width: CGFloat = 0
    @State private var position = ScrollPosition(edge: .bottom)
    /// Keep the newest bubble in view; off while the user has scrolled up to read
    @State private var followsNewest = true

    private var reveal: ChatTextReveal { ChatTextReveal.resolved(revealRaw) }

    private var maxBubbleWidth: CGFloat {
        width > 0 ? (width - Self.sidePadding * 2) * Self.maxBubbleShare : .infinity
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                    let alignment: Alignment = turn.side == .me ? .trailing : .leading
                    ChatBubble(turn: turn, isKorean: isKorean, reveal: reveal)
                        .frame(maxWidth: maxBubbleWidth, alignment: alignment)
                        .frame(maxWidth: .infinity, alignment: alignment)
                        .padding(.top, index == 0 ? 0 : (turns[index - 1].side == turn.side
                            ? tuning.sameSpeakerGap : tuning.speakerChangeGap))
                        .visualEffect { [fade = tuning.fadeHeight, maxBlur = tuning.fadeBlur] content, proxy in
                            // Blur a bubble as it slides out under the top fade, easing in and out
                            let bottom = proxy.frame(in: .scrollView).maxY
                            let band = max(fade * 2, 1)
                            let amount = min(max((band - bottom) / band, 0), 1)
                            return content.blur(radius: maxBlur * ChatLayoutTuning.smoothstep(amount))
                        }
                        // Pops up out of its tail corner, overshooting a little on the grow spring
                        .transition(.asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.7, anchor: turn.side == .me ? .bottomTrailing : .bottomLeading))
                                .combined(with: .offset(y: 10)),
                            removal: .opacity
                        ))
                }
            }
            .padding(.horizontal, Self.sidePadding)
            .padding(.top, tuning.fadeHeight)
            .padding(.bottom, Self.bottomShadowRoom)
            // New bubbles and every change in size ride an iMessage-style spring
            .animation(tuning.growAnimation, value: turns)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        .onScrollPhaseChange { _, phase, context in
            // Decide once a scroll settles, so our own animated scrolls never switch following off
            guard phase == .idle else { return }
            let geometry = context.geometry
            followsNewest = geometry.visibleRect.maxY >= geometry.contentSize.height - 40
        }
        .onChange(of: turns) {
            // New words and bubbles grow the content: stay on the newest one
            guard followsNewest else { return }
            withAnimation(tuning.growAnimation) {
                position.scrollTo(edge: .bottom)
            }
        }
        .mask {
            // Fade out over the top band so bubbles dissolve under the language boxes, on an eased
            // curve so there's no hard edge where the fade starts or ends
            VStack(spacing: 0) {
                LinearGradient(stops: ChatLayoutTuning.easedFadeStops, startPoint: .top, endPoint: .bottom)
                    .frame(height: tuning.fadeHeight)
                Color.black
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
    }
}

/// One speaker's bubble: the other language on top, this phone's language below (in my bubbles what I
/// said, in my partner's its translation). Radius, padding and the row gap come from
/// ChatLayoutTuning. New words wait for the bubble to finish growing before they fade in.
struct ChatBubble: View {
    let turn: ConversationTurn
    let isKorean: Bool
    let reveal: ChatTextReveal

    private var tuning: ChatLayoutTuning { .shared }
    private var isMine: Bool { turn.side == .me }

    var body: some View {
        BubbleTextLayout {
            VStack(alignment: .leading, spacing: tuning.rowSpacing) {
                // This phone's language is always the bottom row, larger: the English speaker reads
                // English big in both bubbles, the Korean speaker Korean
                if isMine {
                    translationRow
                    originalRow
                } else {
                    originalRow
                    translationRow
                }

                // Why a segment has no translation
                if let failure = turn.failure {
                    Text(ChatStrings.failure(failure, isKorean: isKorean))
                        .font(isKorean ? AppTypography.subtextKorean : AppTypography.subtext)
                        .foregroundColor(AppColors.errorRed)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
        }
        .padding(.vertical, tuning.verticalPadding)
        .padding(.leading, tuning.horizontalPadding + (isMine ? 0 : ChatBubbleShape.tailWidth))
        .padding(.trailing, tuning.horizontalPadding + (isMine ? ChatBubbleShape.tailWidth : 0))
        .background {
            ChatBubbleBackground(isMine: isMine, cornerRadius: tuning.cornerRadius)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// What was said, in the speaker's language
    @ViewBuilder
    private var originalRow: some View {
        if !turn.original.isEmpty {
            row(turn.original, main: isMine)
        }
    }

    /// The translation, in the listener's language
    @ViewBuilder
    private var translationRow: some View {
        if !turn.translated.isEmpty {
            row(turn.translated, main: !isMine)
                .transition(.identity)  // its words fade in on their own, per the reveal style
        }
    }

    /// The bottom (`main`) row is larger and primary; the top one smaller and lighter
    private func row(_ text: String, main: Bool) -> RevealingText {
        RevealingText(
            text: text,
            font: ChatFonts.font(for: text, main: main),
            color: main ? AppColors.primaryText : AppColors.secondaryText,
            lineSpacing: 1,
            reveal: reveal,
            startDelay: tuning.textDelaySeconds
        )
    }

    private var accessibilityText: String {
        let speaker = isMine ? (isKorean ? "나" : "You") : (isKorean ? "상대방" : "Partner")
        return [speaker, turn.original, turn.translated].filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

/// A bubble's text: hugs it while every row fits on one line; once a row has to wrap, takes the full width
/// on offer and keeps it, so a bubble that has reached its widest stays there while the rest of the
/// sentence wraps under it. Sized to its widest wrapped line instead, the bubble shrank (on the grow
/// spring) whenever a wrap pushed a word down to the next line. The portfolio's phone does the same.
struct BubbleTextLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let oneLine = content.sizeThatFits(.unspecified)
        guard let width = proposal.width, width < oneLine.width else { return oneLine }
        return CGSize(width: width, height: content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Glass per the Figma call screen: my bubbles filled, the partner's outlined (also the live
/// recording demo's bubbles)
struct ChatBubbleBackground: View {
    let isMine: Bool
    let cornerRadius: CGFloat

    /// Specular rim: bright top-left and bottom-right, fading between (like GlassEdgeRim)
    private static let rim = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(1.0), location: 0.0),
            .init(color: Color.white.opacity(0.65), location: 0.3),
            .init(color: Color.white.opacity(0.45), location: 0.6),
            .init(color: Color.white.opacity(1.0), location: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        let shape = ChatBubbleShape(tailOnRight: isMine, cornerRadius: cornerRadius)
        if isMine {
            // Filled glass, clipped to the bubble: the system glass draws a thin grey line just
            // outside its edge, which read as a dark fringe around the white rim
            shape
                .fill(Color.white.opacity(0.59))
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
                .overlay(rimStroke(shape, width: 0.5))
        } else {
            // Outlined glass: a clear body with a bright rim
            shape
                .fill(Color.white.opacity(0.24))
                .overlay(rimStroke(shape, width: 0.625))
        }
    }

    /// The rim drawn just inside the edge (a double-width stroke clipped to the bubble), so no
    /// half-covered pixels past the edge darken it
    private func rimStroke(_ shape: ChatBubbleShape, width: CGFloat) -> some View {
        shape
            .stroke(Self.rim, lineWidth: width * 2)
            .clipShape(shape)
    }
}

/// Sans-serif faces only, picked by the row's script: Pretendard for Korean, the English body
/// face (Geist, or Söhne in the debug typography) otherwise
enum ChatFonts {
    /// A bubble row's face: `main` for the bottom row (this phone's language), larger; otherwise the
    /// top row (the other language), smaller and lighter
    static func font(for text: String, main: Bool) -> Font {
        if isKorean(text) {
            return main ? AppTypography.b2Korean : AppTypography.b3Korean
        }
        return main ? AppTypography.b2 : AppTypography.b3
    }

    static func isKorean(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
    }
}

enum ChatStrings {
    /// Notice for a segment the server couldn't translate, in this phone's language
    static func failure(_ failure: TranslationFailureEvent, isKorean: Bool) -> String {
        if failure.isRefusal {
            return isKorean ? "번역할 수 없었어요. 다시 말씀해 주세요." : "Couldn't translate that - please rephrase."
        }
        return isKorean ? "번역에 실패했어요. 다시 시도해 주세요." : failure.message
    }
}
