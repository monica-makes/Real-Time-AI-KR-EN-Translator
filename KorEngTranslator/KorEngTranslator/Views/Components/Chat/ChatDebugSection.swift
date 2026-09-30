#if DEBUG
import SwiftUI

/// Debug Controls > CHAT TEXT: how chat text streams in, and a scripted conversation to watch it
struct ChatDebugSection: View {
    @Binding var conversation: ConversationLog
    /// On while the demo plays, so the screen can show the mic control expanded
    @Binding var isDemoPlaying: Bool
    /// The language this phone speaks (the demo gives the other one to the partner)
    let iSpeakKorean: Bool

    @AppStorage(ChatTextReveal.storageKey) private var revealRaw = ChatTextReveal.defaultStyle.rawValue
    @State private var demo: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHAT TEXT")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 6) {
                ForEach(ChatTextReveal.allCases, id: \.self) { style in
                    chip(style.label, isSelected: ChatTextReveal.resolved(revealRaw) == style) {
                        revealRaw = style.rawValue
                    }
                }
            }

            HStack(spacing: 6) {
                chip("Play demo chat", isSelected: false) {
                    demo?.cancel()
                    conversation = ConversationLog()
                    isDemoPlaying = true
                    demo = ConversationDemo.play(into: $conversation, iSpeakKorean: iSpeakKorean) {
                        isDemoPlaying = false
                    }
                }
                chip("Clear", isSelected: false) {
                    demo?.cancel()
                    isDemoPlaying = false
                    withAnimation(.smooth(duration: 0.3)) {
                        conversation = ConversationLog()
                    }
                }
            }
        }
    }

    private func chip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSelected ? AppColors.gradientPeach : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.white.opacity(0.2) : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }
}

/// A scripted two-person conversation fed through ConversationLog the way the server's
/// messages arrive: live captions word by word, then each segment's final and translation.
/// For watching the chat without a partner phone (Debug Controls, or `-orbPreview -chatDemo`).
enum ConversationDemo {
    private enum Event {
        case caption(String)
        case final(String, segment: String)
        case translation(original: String, translated: String, segment: String)
    }

    private struct Step {
        let delay: TimeInterval
        let koreanSpeaker: Bool
        let event: Event
    }

    /// Korean speaker's and English speaker's lines, alternating; each inner array is one turn's segments
    private static let turns: [(korean: Bool, segments: [(said: String, translated: String)])] = [
        (true, [("안녕하세요.", "Hello."),
                ("오늘 날씨가 정말 좋네요.", "The weather is really nice today.")]),
        (false, [("It really is a beautiful day.", "정말 아름다운 날이에요.")]),
        (true, [("혹시 이 근처에 맛있는 카페 아세요?", "Do you know any good cafés around here?")]),
        (false, [("There's a great one just around the corner.", "바로 모퉁이에 좋은 곳이 있어요."),
                 ("I can walk you there if you like.", "원하시면 거기까지 같이 걸어갈게요.")]),
        (true, [("좋아요! 커피 한잔 하면서 이야기해요.", "Great! Let's talk over a cup of coffee.")]),
        (false, [("Perfect. It's my treat today.", "좋아요. 오늘은 제가 살게요.")]),
        (true, [("정말요? 감사합니다.", "Really? Thank you."),
                ("다음에는 제가 살게요.", "Next time it's on me.")]),
        (false, [("Deal. So how long have you lived in Seoul?", "좋아요. 그런데 서울에 산 지 얼마나 되셨어요?")]),
        (true, [("한 5년 정도 됐어요.", "About five years now."),
                ("원래는 부산 출신이에요.", "I'm originally from Busan.")]),
        (false, [("I've always wanted to visit Busan.", "저는 늘 부산에 가 보고 싶었어요."),
                 ("Is the seafood as good as people say?", "해산물이 정말 소문만큼 맛있나요?")]),
        (true, [("네, 자갈치 시장은 꼭 가 보세요.", "Yes, you have to visit Jagalchi Market.")]),
        (false, [("I'll add it to my list.", "제 목록에 추가할게요."),
                 ("What else would you recommend?", "또 어떤 걸 추천하세요?")]),
        (true, [("해운대 해변도 좋고, 감천 문화마을도 예뻐요.", "Haeundae Beach is nice, and Gamcheon Culture Village is pretty too.")]),
        (false, [("That sounds amazing.", "정말 멋지네요."),
                 ("Maybe we could go together sometime.", "언제 같이 가도 좋겠네요.")]),
        (true, [("좋아요! 기차로 두 시간 반이면 가요.", "Sure! It's only two and a half hours by train.")]),
        (false, [("Oh, here's the café.", "아, 카페에 도착했어요."),
                 ("What would you like to drink?", "뭐 드시고 싶으세요?")]),
        (true, [("저는 아이스 아메리카노 주세요.", "I'll have an iced Americano, please.")]),
        (false, [("Two iced Americanos, then.", "그럼 아이스 아메리카노 두 잔이요."),
                 ("Let's grab a seat by the window.", "창가 자리에 앉아요.")]),
    ]

    /// Seconds between live-caption words, from a final to its translation, and between turns
    private static let wordInterval: TimeInterval = 0.28
    private static let translationDelay: TimeInterval = 0.9
    private static let turnPause: TimeInterval = 1.4

    private static var steps: [Step] {
        var steps: [Step] = []
        var segmentNumber = 0
        for turn in turns {
            for (index, segment) in turn.segments.enumerated() {
                segmentNumber += 1
                let id = "demo-\(segmentNumber)"
                let words = segment.said.split(separator: " ")
                for count in 1...words.count {
                    let delay = count == 1 ? (index == 0 ? turnPause : 0.35) : wordInterval
                    steps.append(Step(delay: delay, koreanSpeaker: turn.korean,
                                      event: .caption(words.prefix(count).joined(separator: " "))))
                }
                steps.append(Step(delay: 0.3, koreanSpeaker: turn.korean, event: .final(segment.said, segment: id)))
                steps.append(Step(delay: translationDelay, koreanSpeaker: turn.korean,
                                  event: .translation(original: segment.said, translated: segment.translated, segment: id)))
            }
        }
        return steps
    }

    /// Plays the script into `conversation`; cancel the task to stop it. `onFinish` runs once the
    /// whole script has played (not when cancelled).
    @MainActor
    static func play(into conversation: Binding<ConversationLog>, iSpeakKorean: Bool,
                     onFinish: (() -> Void)? = nil) -> Task<Void, Never> {
        Task { @MainActor in
            defer { if !Task.isCancelled { onFinish?() } }
            for step in steps {
                try? await Task.sleep(for: .seconds(step.delay))
                guard !Task.isCancelled else { return }
                let side: ConversationSide = step.koreanSpeaker == iSpeakKorean ? .me : .partner
                let direction: TranslationDirection = step.koreanSpeaker ? .koreanToEnglish : .englishToKorean
                withAnimation {
                    switch step.event {
                    case .caption(let text):
                        conversation.wrappedValue.apply(
                            TranscriptEvent(text: text, isFinal: false, segmentId: nil, direction: direction), side: side)
                    case .final(let text, let segment):
                        conversation.wrappedValue.apply(
                            TranscriptEvent(text: text, isFinal: true, segmentId: segment, direction: direction), side: side)
                    case .translation(let original, let translated, let segment):
                        conversation.wrappedValue.apply(
                            TranslationEvent(original: original, translated: translated, segmentId: segment,
                                             direction: direction, honorific: nil), side: side)
                    }
                }
            }
        }
    }
}
#endif
