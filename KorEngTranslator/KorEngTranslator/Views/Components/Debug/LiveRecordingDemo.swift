import SwiftUI
import QuartzCore

#if DEBUG
// Hooks the live recording demo puts on the app's own buttons (each call inside #if DEBUG). They
// do nothing outside the demo.
extension View {
    /// Names a button that uses IOSPressStyle, so the live demo's autopilot can hold it down
    func recordingPressID(_ id: String) -> some View {
        environment(\.recordingPressID, id)
    }

    /// A mic menu card that presses in when the live demo's autopilot taps it (the cards use the
    /// system glass style, whose press only a finger can start)
    @ViewBuilder
    func recordingCardPress(_ id: String) -> some View {
        if LiveRecordingDemo.isOn {
            modifier(RecordingCardPress(id: id))
        } else {
            self
        }
    }
}

// MARK: - Live screen recording demo
//
// Records the live translation screen for the Remotion reel (~/Projects/dari-reel, the phone in
// shots 05-07), on the reel's own timeline, with the reel's chat and menu motion and the app's own
// look. It opens straight into the resting screen with no pairing and no network:
//
//   -liveDemo -demoAutopilot -orbStyle flow -orbFlowClock 24.8 -orbFlowAngle 199.2 -noStatusBar -livePace 2
//
// -liveDemo alone opens the resting screen and stops there. The orb options are OrbFlowStyle's.
// -livePace k runs the conversation k times slower than the first take (the reel's CHAT_PACE, 2 since
// the user found the conversation "way too fast"); everything after it comes later by as much. Without
// it the take is the first, 1x one.
// Debug buttons, panels and the connection pill are hidden (RecordingDemo.hidesDebugUI). The take
// is the same on every run: t = 0 is `Autopilot.settle` after the screen appears, the orb's flow
// clock reads -orbFlowClock there, and every tap and line below is timed from it. Taps press the
// real buttons (IOSPressStyle, held without a finger), with no touch dot. stderr logs "live: t0"
// and each tap on the host clock.

enum LiveRecordingDemo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-liveDemo")
    static let autopilot = isOn && ProcessInfo.processInfo.arguments.contains("-demoAutopilot")
    /// The mic shows mic.fill the whole take (the app's slashed mic means "tap to pause")
    static var keepsMicIcon: Bool { isOn }

    /// How many times slower the conversation runs than in the first take (-livePace, default 1)
    static let pace: Double = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-livePace"), i + 1 < args.count,
              let k = Double(args[i + 1]), k > 0 else { return 1 }
        return k
    }()
    /// The conversation in the first take: from the first bubble to the end of the last one's reveal
    /// (the reel's CHAT_SPAN, beats 29.5-38.5)
    static let chatSpan = (from: 2.25, to: 6.75)
    /// How much later everything after the conversation comes at this pace (4.5 s at 2)
    static var extra: Double { (chatSpan.to - chatSpan.from) * (pace - 1) }
    /// A time inside the conversation, given on the first take's timing
    static func inChat(_ t: Double) -> Double { chatSpan.from + (t - chatSpan.from) * pace }

    /// The take, in seconds from t = 0 (the reel's beat grid: LiveScreenRef in dari-reel)
    enum Autopilot {
        /// The screen appears, then rests this long before t = 0, so the first frames (shader
        /// compiles, the edge light's warm-up) are out of the take
        static let settle: Double = 1.5
        static let micTap: Double = 1.625
        // After the conversation: the first take's times, later by as much as it's slower
        static let moreTap: Double = 7.45 + LiveRecordingDemo.extra
        static let menuOpen: Double = 7.50 + LiveRecordingDemo.extra
        static let honorificsTap: Double = 8.15 + LiveRecordingDemo.extra
        /// Honorifics: OFF -> ON (the label and crown swap), then the 요 rolls into my last line
        static let flip: Double = 8.25 + LiveRecordingDemo.extra
        static let roll: Double = 8.35 + LiveRecordingDemo.extra
        static let end: Double = 10.5 + LiveRecordingDemo.extra
        /// How long the mic and More stay down, and the Honorifics card
        static let buttonHold: Double = 0.16
        static let cardHold: Double = 0.12
        /// The hint fades on a cosine ease from the mic tap
        static let hintFade = Animation.timingCurve(0.37, 0, 0.63, 1, duration: 0.35)
    }

    /// One line of the conversation: the partner speaks Korean (left), I speak English (right).
    /// My lines are casual (반말) until Honorifics turns on.
    struct Line {
        let mine: Bool
        let said: String
        let translated: String
        /// When the bubble appears
        let at: Double

        var saidWords: Int { said.split(separator: " ").count }
        var translatedWords: Int { translated.split(separator: " ").count }
        /// When the translation row starts revealing, from the bubble appearing
        var translationStart: Double { originalStart + Double(saidWords) * wordStep + 0.12 * pace }
        /// When the voice light goes off (the reel's revealEnd + 0.15), from the bubble appearing
        var voiceEnd: Double { translationStart + Double(translatedWords + 1) * wordStep + 0.15 }
    }

    /// A line every 0.725 s in the first take (every 1.45 s at pace 2)
    static let lines: [Line] = [
        Line(mine: false, said: "오늘 저녁에 같이 밥 먹을래요?", translated: "Want to get dinner together tonight?", at: inChat(2.25)),
        Line(mine: true, said: "Sure! Where should we go?", translated: "좋아! 어디로 갈까?", at: inChat(2.975)),
        Line(mine: false, said: "제가 아는 삼겹살집이 있어요.", translated: "I know a great samgyeopsal place.", at: inChat(3.70)),
        Line(mine: true, said: "Perfect. What time?", translated: "완벽해. 몇 시에 볼까?", at: inChat(4.425)),
        Line(mine: false, said: "7시 어때요?", translated: "How about 7?", at: inChat(5.15)),
        Line(mine: true, said: "Want to get dessert after?", translated: "끝나고 디저트도 먹을래?", at: inChat(5.875)),
    ]
    /// My last line gains its polite ending when Honorifics turns on: 먹을래? -> 먹을래요?
    static let politeEnding = "요"

    // The reel's motion
    /// Each word fades in over this long, this long after the one before (at the conversation's pace)
    static let wordStep: Double = 0.07 * pace
    /// The original row starts this long after its bubble appears
    static let originalStart: Double = 0.20 * pace
    /// Each voice light comes on this long before its bubble appears
    static let voiceLead: Double = 0.35
    /// The partner's edge light fades over 0.45 s (EdgeBeam); its fade is centered on each edge
    static let edgeFade: Double = 0.45
    /// My voice level while I talk (the scripted demo's)
    static let myLevel: CGFloat = 0.65
    /// The mic lifts this far when the menu opens, and the thread rises with it
    static let menuLift: CGFloat = 96
    static let menuCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.22, y: 1),
                                            endControlPoint: UnitPoint(x: 0.36, y: 1))
    static let menuDuration: Double = 0.4

    /// A critically damped spring released from rest: still at first, lands softly, never overshoots
    /// (omega 8: 90% after 0.49 s; omega 12: 90% after 0.32 s)
    static func settle(_ t: Double, _ omega: Double) -> Double {
        t <= 0 ? 0 : 1 - (1 + omega * t) * exp(-omega * t)
    }

    /// The menu's reveal at t (0...1)
    static func menuOpen(at t: Double) -> Double {
        menuCurve.value(at: min(max((t - Autopilot.menuOpen) / menuDuration, 0), 1))
    }
}

// MARK: - Clock

/// t = 0. What the autopilot changes goes through the screen's own SwiftUI state (bindings, and the
/// environment for the held buttons), the way the buttons themselves change it.
@MainActor
final class LiveRecordingDemoState {
    static let shared = LiveRecordingDemoState()

    private var fixedStart: (media: CFTimeInterval, date: Date)?

    /// t = 0 of the take on the media clock and the wall clock: `settle` after the first ask (the
    /// screen as it appears). Nil without the autopilot.
    var start: (media: CFTimeInterval, date: Date)? {
        guard LiveRecordingDemo.autopilot else { return nil }
        if fixedStart == nil {
            let settle = LiveRecordingDemo.Autopilot.settle
            fixedStart = (CACurrentMediaTime() + settle, Date().addingTimeInterval(settle))
        }
        return fixedStart
    }

    /// Seconds since t = 0 (negative before it; -infinity without the autopilot)
    func seconds(at date: Date) -> Double {
        start.map { date.timeIntervalSince($0.date) } ?? -.infinity
    }
}

// MARK: - Screen hooks

extension View {
    /// The live screen: Honorifics starts OFF, and the autopilot plays the take through the screen's
    /// own state (the same changes its buttons make)
    @ViewBuilder
    func liveRecordingDemo(isSessionActive: Binding<Bool>, hasStartedOnce: Binding<Bool>,
                           isMicMenuOpen: Binding<Bool>, honorificsOn: Binding<Bool>,
                           voice: Binding<VoiceActivity?>) -> some View {
        if LiveRecordingDemo.isOn {
            modifier(LiveRecordingScreenHooks(isSessionActive: isSessionActive, hasStartedOnce: hasStartedOnce,
                                              isMicMenuOpen: isMicMenuOpen, honorificsOn: honorificsOn,
                                              voice: voice))
        } else {
            self
        }
    }

    /// The live screen's chat: in the demo, the scripted thread on the reel's motion instead
    @ViewBuilder
    func replacedByLiveDemoChat() -> some View {
        if LiveRecordingDemo.isOn {
            LiveDemoChat()
        } else {
            self
        }
    }
}

extension EnvironmentValues {
    /// The name the live demo's autopilot holds a button down by (recordingPressID)
    @Entry var recordingPressID: String? = nil
    /// The buttons the live demo's autopilot is holding down
    @Entry var recordingHeldIDs: Set<String> = []
}

extension EnvironmentValues {
    /// Whether the live demo's autopilot is holding this button down (see recordingPressID)
    var isRecordingHeld: Bool {
        recordingPressID.map(recordingHeldIDs.contains) ?? false
    }
}

private struct RecordingCardPress: ViewModifier {
    let id: String
    @Environment(\.recordingHeldIDs) private var held

    func body(content: Content) -> some View {
        let isHeld = held.contains(id)
        content
            .scaleEffect(isHeld ? 1 - 0.035 : 1)
            .animation(IOSPress.animation(pressed: isHeld), value: isHeld)
    }
}

private struct LiveRecordingScreenHooks: ViewModifier {
    @Binding var isSessionActive: Bool
    @Binding var hasStartedOnce: Bool
    @Binding var isMicMenuOpen: Bool
    @Binding var honorificsOn: Bool
    @Binding var voice: VoiceActivity?

    /// The buttons held down right now, handed to them through the environment
    @State private var held: Set<String> = []

    func body(content: Content) -> some View {
        content
            .environment(\.recordingHeldIDs, held)
            .onAppear {
                voice = .silent
                honorificsOn = false
                // Fixes t = 0 (the orb's flow clock and the chat read it too)
                if LiveRecordingDemoState.shared.start != nil {
                    RecordingDemo.log("live: screen appeared, t0 in \(LiveRecordingDemo.Autopilot.settle) s")
                }
            }
            .task { await runAutopilot() }
    }

    private func runAutopilot() async {
        guard let t0 = LiveRecordingDemoState.shared.start?.media else { return }
        typealias A = LiveRecordingDemo.Autopilot

        var events: [(at: Double, run: () -> Void)] = []
        func press(_ id: String, at time: Double, hold: Double, label: String) {
            events.append((time, {
                held.insert(id)
                RecordingDemo.log("live: \(label) down")
            }))
            events.append((time + hold, { held.remove(id) }))
        }

        events.append((0, { RecordingDemo.log("live: t0") }))

        // The mic: pressed, the hint fades, More and Stop squeeze out
        events.append((A.micTap, {
            withAnimation(A.hintFade) { hasStartedOnce = true }
            held.insert("mic")
            isSessionActive = true
            RecordingDemo.log("live: mic down")
        }))
        events.append((A.micTap + A.buttonHold, { held.remove("mic") }))

        // The voice lights: each side's from a moment before its bubble until its words are in. The
        // partner's light fades over 0.45 s, so it flips half that early to center the fade on the edge.
        var mine = 0
        var theirs = 0
        func updateVoice() {
            voice = VoiceActivity(myLevel: mine > 0 ? LiveRecordingDemo.myLevel : 0,
                                  partnerSpeaking: theirs > 0, mySpeechLike: true)
        }
        for line in LiveRecordingDemo.lines {
            let shift = line.mine ? 0 : LiveRecordingDemo.edgeFade / 2
            let on = line.at - LiveRecordingDemo.voiceLead - shift
            let off = line.at + line.voiceEnd - shift
            if line.mine {
                events.append((on, { mine += 1; updateVoice() }))
                events.append((off, { mine -= 1; updateVoice() }))
            } else {
                events.append((on, { theirs += 1; updateVoice() }))
                events.append((off, { theirs -= 1; updateVoice() }))
            }
        }

        // More opens the menu: the mic lifts on the cards' reveal curve (the thread rises in LiveDemoChat)
        press("ellipsis", at: A.moreTap, hold: A.buttonHold, label: "More")
        events.append((A.menuOpen, {
            withAnimation(MicMenuCards.revealAnimation) { isMicMenuOpen = true }
        }))

        // Honorifics: the card presses, its label and crown swap, then the 요 rolls in (LiveDemoChat)
        press("crown-simple", at: A.honorificsTap, hold: A.cardHold, label: "Honorifics")
        events.append((A.flip, { honorificsOn = true }))
        events.append((A.end, { RecordingDemo.log("live: end of the take") }))

        for event in events.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }).map(\.element) {
            // No timer leeway: a default sleep woke up to 15 ms late
            let wait = t0 + event.at - CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(for: .seconds(wait), tolerance: .zero) }
            guard !Task.isCancelled else { return }
            event.run()
        }
    }
}

// MARK: - Chat

/// The scripted conversation on the reel's motion, in the app's bubbles. Every bubble lands on a
/// settle from rest (no bounce), pushing the thread up by its height and gap on the same curve; words
/// reveal one by one; the thread rises with the mic when the menu opens; my last line gains its 요.
/// Time-driven, so it's the same on every run.
struct LiveDemoChat: View {
    private typealias Demo = LiveRecordingDemo

    @State private var heights = Array(repeating: CGFloat(0), count: LiveRecordingDemo.lines.count)
    @State private var size = CGSize.zero
    @State private var polite = PoliteMetrics()

    private var tuning: ChatLayoutTuning { .shared }
    private static let sidePadding: CGFloat = 20
    private static let maxBubbleShare: CGFloat = 0.8

    var body: some View {
        TimelineView(.animation) { context in
            thread(at: LiveRecordingDemoState.shared.seconds(at: context.date))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .clipped()
        .mask {
            // The app's top fade, so older lines melt away under the language boxes
            VStack(spacing: 0) {
                LinearGradient(stops: ChatLayoutTuning.easedFadeStops, startPoint: .top, endPoint: .bottom)
                    .frame(height: tuning.fadeHeight)
                Color.black
            }
        }
        .background { measurements }
        .allowsHitTesting(false)
    }

    private func thread(at t: Double) -> some View {
        let lines = Demo.lines
        let arrivals = lines.map { Demo.settle(t - $0.at, 8) }
        let menuLift = Demo.menuLift * Demo.menuOpen(at: t)
        let maxBubbleWidth = max(0, (size.width - Self.sidePadding * 2) * Self.maxBubbleShare)
        return ZStack(alignment: .bottom) {
            ForEach(lines.indices, id: \.self) { i in
                let line = lines[i]
                let a = arrivals[i]
                // Everything newer pushes this bubble up, each on its own arrival
                let pushed = (i + 1 ..< lines.count).reduce(CGFloat(0)) { sum, j in
                    sum + (heights[j] + gap(before: j)) * arrivals[j]
                }
                let lift = pushed + menuLift
                // The app's blur for a bubble leaving under the top fade
                let bottom = size.height - ConversationChatView.bottomShadowRoom - lift
                let band = max(tuning.fadeHeight * 2, 1)
                let leaving = tuning.fadeBlur * ChatLayoutTuning.smoothstep((band - bottom) / band)
                let corner: UnitPoint = line.mine ? .bottomTrailing : .bottomLeading
                let side: Alignment = line.mine ? .trailing : .leading

                LiveDemoBubble(line: line, t: t - line.at, polite: i == lines.count - 1 ? politeEnding(at: t) : nil)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[i] = $0 }
                    .frame(maxWidth: maxBubbleWidth, alignment: side)
                    .scaleEffect(0.82 + 0.18 * a, anchor: corner)
                    .offset(y: 16 * (1 - a))
                    .blur(radius: 6 * (1 - a) + leaving)
                    .opacity(min(1, 1.8 * a))
                    .frame(maxWidth: .infinity, alignment: side)
                    .offset(y: -lift)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, Self.sidePadding)
        .padding(.bottom, ConversationChatView.bottomShadowRoom)
    }

    /// 8pt between one speaker's bubbles, 16 when the speaker changes
    private func gap(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return Demo.lines[index - 1].mine == Demo.lines[index].mine ? tuning.sameSpeakerGap : tuning.speakerChangeGap
    }

    /// My last line's 요: it rolls in on a settle (90% in 0.32 s), glowing as it lands
    private func politeEnding(at t: Double) -> PoliteEnding? {
        guard t >= Demo.Autopilot.flip, polite.isMeasured else { return nil }
        let s = t - Demo.Autopilot.roll
        let roll = Demo.settle(s, 12)
        let glow = s <= 0 ? 0 : roll * exp(-max(0, s - 0.1) / 0.35)
        return PoliteEnding(roll: roll, glow: glow, metrics: polite)
    }

    /// The widths the 요 needs: my last English line, my last Korean line before and after, the 요's line
    private var measurements: some View {
        let line = Demo.lines[Demo.lines.count - 1]
        let politeLine = String(line.translated.dropLast()) + Demo.politeEnding + "?"
        let translationFont = ChatFonts.translation(for: line.translated)
        return ZStack {
            Text(verbatim: line.said)
                .font(ChatFonts.original(for: line.said))
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { polite.original = $0 }
            Text(verbatim: line.translated)
                .font(translationFont)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { polite.before = $0 }
            Text(verbatim: politeLine)
                .font(translationFont)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                    polite.after = $0.width
                    polite.lineHeight = $0.height
                }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Measured in the app's fonts
struct PoliteMetrics {
    var original: CGFloat = 0
    var before: CGFloat = 0
    var after: CGFloat = 0
    var lineHeight: CGFloat = 0

    var isMeasured: Bool { original > 0 && before > 0 && after > before }
    /// The slot the 요 opens
    var slot: CGFloat { after - before }
    /// The bubble's text width before and after (the wider of its two rows)
    var contentBefore: CGFloat { max(original, before) }
    var contentAfter: CGFloat { max(original, after) }
}

struct PoliteEnding {
    let roll: Double
    let glow: Double
    let metrics: PoliteMetrics
}

/// One bubble (ChatBubble's layout and glass), its rows revealed word by word on the demo's clock.
/// `t` is seconds since it appeared.
private struct LiveDemoBubble: View {
    let line: LiveRecordingDemo.Line
    let t: Double
    /// My last line once Honorifics is on
    let polite: PoliteEnding?

    private var tuning: ChatLayoutTuning { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: tuning.rowSpacing) {
            revealed(line.said, color: AppColors.secondaryText, start: LiveRecordingDemo.originalStart)
                .font(ChatFonts.original(for: line.said))
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            translationRow
        }
        // The bubble widens with the 요 on its own curve
        .frame(width: polite.map { p in
            p.metrics.contentBefore + (p.metrics.contentAfter - p.metrics.contentBefore) * p.roll
        }, alignment: .leading)
        .padding(.vertical, tuning.verticalPadding)
        .padding(.leading, tuning.horizontalPadding + (line.mine ? 0 : ChatBubbleShape.tailWidth))
        .padding(.trailing, tuning.horizontalPadding + (line.mine ? ChatBubbleShape.tailWidth : 0))
        .background {
            ChatBubbleBackground(isMine: line.mine, cornerRadius: tuning.cornerRadius)
        }
    }

    @ViewBuilder
    private var translationRow: some View {
        let font = ChatFonts.translation(for: line.translated)
        let start = line.translationStart
        if let polite {
            // 먹을래 [요] ?: a slot opens before the question mark and the 요 rolls up into it from a line
            // below, unblurring, in Claude orange, with a glow that blooms as it lands
            let words = line.translated.split(separator: " ").count
            let lastWord = clamp((t - start - Double(words - 1) * LiveRecordingDemo.wordStep) / LiveRecordingDemo.wordStep)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                revealed(String(line.translated.dropLast()), color: AppColors.primaryText, start: start)
                Text(verbatim: LiveRecordingDemo.politeEnding)
                    .foregroundStyle(AppColors.claudeOrange)
                    .fixedSize()
                    .offset(y: (polite.metrics.lineHeight + 1) * (1 - polite.roll))
                    .frame(width: polite.metrics.slot * polite.roll, alignment: .leading)
                    .clipped()
                    .blur(radius: 1.5 * (1 - polite.roll))
                    .shadow(color: AppColors.claudeOrange.opacity(0.9 * polite.glow), radius: 2 + 6 * polite.glow)
                Text(verbatim: "?")
                    .foregroundStyle(AppColors.primaryText.opacity(lastWord))
            }
            .font(font)
            .fixedSize()
        } else {
            revealed(line.translated, color: AppColors.primaryText, start: start)
                .font(font)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `text` with each word fading in over a word step, a step after the one before, from `start`
    private func revealed(_ text: String, color: Color, start: Double) -> Text {
        let words = text.split(separator: " ")
        var result = Text(verbatim: "")
        for (k, word) in words.enumerated() {
            let shown = clamp((t - start - Double(k) * LiveRecordingDemo.wordStep) / LiveRecordingDemo.wordStep)
            let piece = Text(verbatim: k < words.count - 1 ? word + " " : String(word))
                .foregroundStyle(color.opacity(shown))
            result = Text("\(result)\(piece)")
        }
        return result
    }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
#endif
