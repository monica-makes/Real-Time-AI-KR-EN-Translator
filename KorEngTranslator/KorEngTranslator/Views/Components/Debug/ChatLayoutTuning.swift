import SwiftUI
import Observation

/// The live screen's chat bubbles: corner radius, padding, the gap between the original and its
/// translation, how far the newest bubble sits above the mic, the iMessage-style spring they grow
/// on, the gaps between bubbles, and the fade and blur they leave through under the language boxes.
/// Debug builds tune the bubble gaps and the fade from the CHAT BUBBLES panel (speech-bubble button,
/// bottom left; `-chatLayoutPanel` opens it at launch); values last until the app relaunches.
@Observable
final class ChatLayoutTuning {
    static let shared = ChatLayoutTuning()

    static let defaultCornerRadius: CGFloat = 20
    static let defaultVerticalPadding: CGFloat = 12    // top and bottom inside the bubble
    static let defaultHorizontalPadding: CGFloat = 16  // left and right, not counting the tail
    static let defaultRowSpacing: CGFloat = 6          // original row to translation row
    static let defaultMicGap: CGFloat = 20             // newest bubble's bottom to the mic button's top
    static let defaultBounce: CGFloat = 40             // grow spring's bounce (% of critical damping taken off)
    static let defaultSpringDuration: CGFloat = 400    // ms
    static let defaultTextDelay: CGFloat = 200         // ms from the bubble growing to its new words fading in
    static let defaultSameSpeakerGap: CGFloat = 8      // between two bubbles from the same speaker
    static let defaultSpeakerChangeGap: CGFloat = 16   // between bubbles when the speaker changes
    static let defaultFadeHeight: CGFloat = 36         // the top fade band, just under the language boxes
    static let defaultFadeBlur: CGFloat = 6            // blur of a bubble leaving under the fade

    var cornerRadius = defaultCornerRadius
    var verticalPadding = defaultVerticalPadding
    var horizontalPadding = defaultHorizontalPadding
    var rowSpacing = defaultRowSpacing
    var micGap = defaultMicGap
    var bounce = defaultBounce
    var springDuration = defaultSpringDuration
    var textDelay = defaultTextDelay
    var sameSpeakerGap = defaultSameSpeakerGap
    var speakerChangeGap = defaultSpeakerChangeGap
    var fadeHeight = defaultFadeHeight
    var fadeBlur = defaultFadeBlur

    /// 0...1 eased at both ends (smoothstep)
    static func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Clear to opaque along a smoothstep, for the top fade's mask
    static let easedFadeStops: [Gradient.Stop] = (0...12).map { i in
        let x = CGFloat(i) / 12
        return Gradient.Stop(color: Color.black.opacity(smoothstep(x)), location: x)
    }

    /// Bubbles appearing and growing, and the thread moving up to make room: a spring that
    /// overshoots a little, like Messages
    var growAnimation: Animation {
        .spring(duration: springDuration / 1000, bounce: bounce / 100)
    }

    /// New words wait this long, so the bubble grows first and the text fills in after
    var textDelaySeconds: TimeInterval { TimeInterval(textDelay) / 1000 }

    var isDefault: Bool {
        cornerRadius == Self.defaultCornerRadius
            && verticalPadding == Self.defaultVerticalPadding
            && horizontalPadding == Self.defaultHorizontalPadding
            && rowSpacing == Self.defaultRowSpacing
            && micGap == Self.defaultMicGap
            && bounce == Self.defaultBounce
            && springDuration == Self.defaultSpringDuration
            && textDelay == Self.defaultTextDelay
            && sameSpeakerGap == Self.defaultSameSpeakerGap
            && speakerChangeGap == Self.defaultSpeakerChangeGap
            && fadeHeight == Self.defaultFadeHeight
            && fadeBlur == Self.defaultFadeBlur
    }

    func reset() {
        cornerRadius = Self.defaultCornerRadius
        verticalPadding = Self.defaultVerticalPadding
        horizontalPadding = Self.defaultHorizontalPadding
        rowSpacing = Self.defaultRowSpacing
        micGap = Self.defaultMicGap
        bounce = Self.defaultBounce
        springDuration = Self.defaultSpringDuration
        textDelay = Self.defaultTextDelay
        sameSpeakerGap = Self.defaultSameSpeakerGap
        speakerChangeGap = Self.defaultSpeakerChangeGap
        fadeHeight = Self.defaultFadeHeight
        fadeBlur = Self.defaultFadeBlur
    }

    /// For pasting into a chat or the code
    var summary: String {
        func pt(_ value: CGFloat) -> String { String(format: "%.0f", value) }
        return """
        Chat bubbles
        corner radius: \(pt(cornerRadius))
        padding top/bottom: \(pt(verticalPadding)), left/right: \(pt(horizontalPadding))
        original-translation gap: \(pt(rowSpacing))
        newest bubble to mic: \(pt(micGap))
        grow spring: \(pt(springDuration))ms, bounce \(pt(bounce))%
        text delay: \(pt(textDelay))ms
        bubble gap: \(pt(sameSpeakerGap)) same speaker, \(pt(speakerChangeGap)) speaker change
        top fade: \(pt(fadeHeight)) tall, blur \(pt(fadeBlur))
        """
    }
}

#if DEBUG
/// CHAT BUBBLES panel for the live screen (speech-bubble button, bottom left)
struct ChatLayoutPanel: View {
    private var layout: ChatLayoutTuning { .shared }

    var body: some View {
        LayoutTunerPanel("CHAT BUBBLES", toggleIcon: "bubble.left.and.bubble.right.fill",
                         toggleOnLeading: true, launchArgument: "-chatLayoutPanel",
                         isDefault: layout.isDefault, onReset: { layout.reset() },
                         summary: { layout.summary }) {
            // Radius, padding, text gap, mic gap and the spring are baked in (see the defaults above)
            LayoutTunerRow("Same gap", value: layout.sameSpeakerGap, range: 0...40) { layout.sameSpeakerGap = max(0, $0) }
            LayoutTunerRow("Switch gap", value: layout.speakerChangeGap, range: 0...60) { layout.speakerChangeGap = max(0, $0) }
            LayoutTunerRow("Fade height", value: layout.fadeHeight, range: 0...160) { layout.fadeHeight = max(0, $0) }
            LayoutTunerRow("Fade blur", value: layout.fadeBlur, range: 0...30) { layout.fadeBlur = max(0, $0) }
        }
    }
}
#endif
