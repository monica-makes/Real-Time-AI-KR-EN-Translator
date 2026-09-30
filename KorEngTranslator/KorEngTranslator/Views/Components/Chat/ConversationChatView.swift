import SwiftUI

/// Both sides of the conversation as chat bubbles, newest at the bottom (AirPods Live
/// Translation style): the partner's on the left in outlined glass, mine on the right in
/// filled glass. Each bubble's top row is what was said, in the speaker's language (smaller,
/// secondary); the bottom row is its translation (larger, primary). Words fade in as they're
/// spoken and translated. Older bubbles fade and blur out under the language boxes above.
struct ConversationChatView: View {
    let turns: [ConversationTurn]
    /// This phone's language, for notices like "couldn't translate that"
    let isKorean: Bool

    /// Fade/blur band at the top, just under the language boxes
    static let topFade: CGFloat = 20
    /// Room under the newest bubble for its glass shadow (about 30pt on iOS 26, 13pt on iOS 27), so
    /// the scroll edge doesn't cut it off. Callers place the chat's bottom this much lower than
    /// where the newest bubble should sit.
    static let bottomShadowRoom: CGFloat = 36
    /// Bubbles take at most this share of the width, like Messages
    private static let maxBubbleShare: CGFloat = 0.8
    private static let sidePadding: CGFloat = 20
    /// Between two bubbles from the same speaker, and between speakers
    private static let sameSpeakerSpacing: CGFloat = 6
    private static let speakerChangeSpacing: CGFloat = 14

    @AppStorage(ChatTextReveal.storageKey) private var revealRaw = ChatTextReveal.defaultStyle.rawValue
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
                            ? Self.sameSpeakerSpacing : Self.speakerChangeSpacing))
                        .visualEffect { content, proxy in
                            // Blur a bubble as it slides out under the top fade
                            let bottom = proxy.frame(in: .scrollView).maxY
                            let band = Self.topFade * 2
                            let amount = min(max((band - bottom) / band, 0), 1)
                            return content.blur(radius: 6 * amount)
                        }
                        .transition(.asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.94, anchor: turn.side == .me ? .bottomTrailing : .bottomLeading))
                                .combined(with: .offset(y: 6)),
                            removal: .opacity
                        ))
                }
            }
            .padding(.horizontal, Self.sidePadding)
            .padding(.top, Self.topFade)
            .padding(.bottom, Self.bottomShadowRoom)
            .animation(.smooth(duration: 0.3), value: turns)
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
            withAnimation(.smooth(duration: 0.3)) {
                position.scrollTo(edge: .bottom)
            }
        }
        .mask {
            // Fade out over the top band so bubbles dissolve under the language boxes
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.topFade)
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

/// One speaker's bubble: original on top, translation below
struct ChatBubble: View {
    let turn: ConversationTurn
    let isKorean: Bool
    let reveal: ChatTextReveal

    private static let horizontalPadding: CGFloat = 14
    private static let verticalPadding: CGFloat = 9
    private static let rowSpacing: CGFloat = 3

    private var isMine: Bool { turn.side == .me }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            // Top row: what was said, in the speaker's language - smaller and lighter
            if !turn.original.isEmpty {
                RevealingText(
                    text: turn.original,
                    font: ChatFonts.original(for: turn.original),
                    color: AppColors.secondaryText,
                    lineSpacing: 1,
                    reveal: reveal
                )
            }

            // Bottom row: the translation, in the listener's language
            if !turn.translated.isEmpty {
                RevealingText(
                    text: turn.translated,
                    font: ChatFonts.translation(for: turn.translated),
                    color: AppColors.primaryText,
                    lineSpacing: 1,
                    reveal: reveal
                )
                .transition(.identity)  // its words fade in on their own, per the reveal style
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
        .padding(.vertical, Self.verticalPadding)
        .padding(.leading, Self.horizontalPadding + (isMine ? 0 : ChatBubbleShape.tailWidth))
        .padding(.trailing, Self.horizontalPadding + (isMine ? ChatBubbleShape.tailWidth : 0))
        .background {
            ChatBubbleBackground(isMine: isMine)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let speaker = isMine ? (isKorean ? "나" : "You") : (isKorean ? "상대방" : "Partner")
        return [speaker, turn.original, turn.translated].filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

/// Glass per the Figma call screen: my bubbles filled, the partner's outlined
private struct ChatBubbleBackground: View {
    let isMine: Bool

    /// Specular rim: bright top-left and bottom-right, fading between (like GlassEdgeRim)
    private static let rim = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(1.0), location: 0.0),
            .init(color: Color.white.opacity(0.55), location: 0.3),
            .init(color: Color.white.opacity(0.35), location: 0.6),
            .init(color: Color.white.opacity(0.9), location: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        let shape = ChatBubbleShape(tailOnRight: isMine)
        if isMine {
            // Filled glass (system glass brings its own shadow)
            shape
                .fill(Color.white.opacity(0.45))
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(Self.rim, lineWidth: 1))
        } else {
            // Outlined glass: a clear body with a bright rim and a hairline to hold it on beige
            shape
                .fill(Color.white.opacity(0.14))
                .overlay(shape.stroke(AppColors.primaryText.opacity(0.08), lineWidth: 2.5))
                .overlay(shape.stroke(Self.rim, lineWidth: 1.25))
        }
    }
}

/// Sans-serif faces only, picked by the row's script: Pretendard for Korean, the English body
/// face (Geist, or Söhne in the debug typography) otherwise
enum ChatFonts {
    /// Top row: smaller and lighter
    static func original(for text: String) -> Font {
        isKorean(text) ? AppTypography.b3Korean : AppTypography.b3
    }

    /// Bottom row: the translation, larger
    static func translation(for text: String) -> Font {
        isKorean(text) ? AppTypography.b2Korean : AppTypography.b2
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
