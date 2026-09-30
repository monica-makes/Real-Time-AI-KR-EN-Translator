#if DEBUG
import SwiftUI

/// Debug Controls > CHAT TEXT: how chat text streams in, and a scripted conversation to watch it
struct ChatDebugSection: View {
    @Binding var conversation: ConversationLog
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
                    demo = ConversationDemo.play(into: $conversation, iSpeakKorean: iSpeakKorean)
                }
                chip("Clear", isSelected: false) {
                    demo?.cancel()
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

    /// Plays the script into `conversation`; cancel the task to stop it
    @MainActor
    static func play(into conversation: Binding<ConversationLog>, iSpeakKorean: Bool) -> Task<Void, Never> {
        Task { @MainActor in
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
