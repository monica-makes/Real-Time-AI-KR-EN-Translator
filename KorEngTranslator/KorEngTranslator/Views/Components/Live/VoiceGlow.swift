import SwiftUI
import Observation

// Light that shows who's talking on the live screen, alongside the orb:
// - My voice: a glow rising from the bottom edge and blooming with my mic level, after the
//   voice-glow library's "mobile" beam, in bright, full oranges.
// - The partner's voice: light running along the screen's rounded bottom edges (the bottom 40% of
//   the screen), after the border-beam library's sunset beam, in Claude orange and the orb's
//   rendered colors.
// - The orb grows a little with my voice and rests while the partner talks.

/// What the voice effects should show right now
struct VoiceActivity: Equatable {
    /// 0...1: how loud I'm speaking, for my light and the orb; 0 while the partner talks
    var myLevel: CGFloat
    var partnerSpeaking: Bool
    /// No meter behind `myLevel` (the demo chat, a preview): effects sway it like speech over time
    var mySpeechLike = false

    static let silent = VoiceActivity(myLevel: 0, partnerSpeaking: false)

    /// - Parameters:
    ///   - micLevel: the capture meter, dB-normalized ((dB + 60) / 60)
    ///   - iAmSpeaking: the screen's speaking gate (real voice energy, not room noise)
    ///   - micRunning: capture is on (or the debug menu is simulating it)
    ///   - myCaptionLive / partnerCaptionLive: a live caption is streaming for that side
    ///   - partnerAudioPlaying: the partner's translated speech is playing on this phone
    static func resolve(micLevel: CGFloat, iAmSpeaking: Bool, micRunning: Bool, myCaptionLive: Bool,
                        partnerCaptionLive: Bool, partnerAudioPlaying: Bool) -> VoiceActivity {
        #if DEBUG
        switch VoiceGlowTuning.shared.preview {
        case .auto: break
        case .me: return VoiceActivity(myLevel: 0.65, partnerSpeaking: false, mySpeechLike: true)
        case .partner: return VoiceActivity(myLevel: 0, partnerSpeaking: true)
        }
        #endif
        let partnerSpeaking = partnerCaptionLive || partnerAudioPlaying
        guard !partnerSpeaking else { return VoiceActivity(myLevel: 0, partnerSpeaking: true) }
        if micRunning {
            // Speech sits around -39 to -15 dBFS; below the speaking gate is room noise or the partner
            let level = iAmSpeaking ? min(max((micLevel - 0.3) / 0.45, 0), 1) : 0
            return VoiceActivity(myLevel: level, partnerSpeaking: false)
        }
        // No mic (the scripted demo chat): my live caption stands in for my voice
        return VoiceActivity(myLevel: myCaptionLive ? 0.65 : 0, partnerSpeaking: false, mySpeechLike: true)
    }

    /// A smooth, syllable-paced sway (about 0.55...1) for a level with no meter behind it
    static func speechSway(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return 0.78 + 0.14 * sin(t * 2 * .pi * 1.7) + 0.08 * sin(t * 2 * .pi * 2.9 + 1)
    }
}

/// Strengths of the voice effects. Debug builds tune them from the live screen's debug panel (GLOW).
@Observable
final class VoiceGlowTuning {
    static let shared = VoiceGlowTuning()

    static let defaultMineStrength: CGFloat = 100    // % of my bottom glow
    static let defaultTheirsStrength: CGFloat = 100  // % of the partner's edge light
    static let defaultOrbPulse: CGFloat = 12         // % the orb grows at full voice

    var mineStrength = defaultMineStrength
    var theirsStrength = defaultTheirsStrength
    var orbPulse = defaultOrbPulse

    /// Debug preview: force one side's effect on
    enum Preview { case auto, me, partner }
    var preview = Preview.auto

    var isDefault: Bool {
        mineStrength == Self.defaultMineStrength && theirsStrength == Self.defaultTheirsStrength
            && orbPulse == Self.defaultOrbPulse && preview == .auto
    }

    func reset() {
        mineStrength = Self.defaultMineStrength
        theirsStrength = Self.defaultTheirsStrength
        orbPulse = Self.defaultOrbPulse
        preview = .auto
    }
}

/// Both voice effects, full screen and untouchable; place it just above the background
struct LiveVoiceGlow: View {
    let activity: VoiceActivity
    private var tuning: VoiceGlowTuning { .shared }

    var body: some View {
        ZStack {
            // Me: the orange glow rising from the bottom, with my level
            BottomVoiceGlow(level: activity.myLevel, speechLike: activity.mySpeechLike,
                            strength: tuning.mineStrength / 100, palette: .brightOrange)
            // The partner: light along the bottom edges
            EdgeBeam(level: activity.partnerSpeaking ? 1 : 0, strength: tuning.theirsStrength / 100,
                     palette: .rim)
                .animation(.easeInOut(duration: 0.25), value: activity.partnerSpeaking)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The orb grows with my voice, eased frame by frame so it swells smoothly instead of jumping
    /// with every meter reading; `level` 0 rests it
    func voicePulse(_ level: CGFloat, speechLike: Bool = false) -> some View {
        modifier(VoicePulse(level: level, speechLike: speechLike))
    }
}

/// Scales its content with a smoothed voice level: rises over about 120ms, settles over 350ms
private struct VoicePulse: ViewModifier {
    let level: CGFloat
    let speechLike: Bool

    @State private var follower = GlowFollower(count: 1)
    @State private var running = false

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !running)) { timeline in
            let sway = speechLike ? VoiceActivity.speechSway(at: timeline.date) : 1
            let smoothed = follower.step(targets: [Double(level) * sway], rise: [0.12], fall: [0.35],
                                         at: timeline.date)[0]
            content.scaleEffect(1 + VoiceGlowTuning.shared.orbPulse / 100 * CGFloat(smoothed))
        }
        .modifier(EffectClock(isOn: level > 0, settle: 1.5, running: $running))
    }
}

// MARK: - Colors

/// An RGB color that can be mixed and desaturated frame by frame
private struct GlowRGB {
    var r, g, b: Double

    /// `saturation` scales the color's HSB saturation; `brightness` sets its HSB brightness, so a
    /// paler color stays luminous on the light background instead of going grey
    init(_ hex: UInt32, saturation: Double = 1, brightness: Double? = nil) {
        let channels = [16, 8, 0].map { Double((hex >> UInt32($0)) & 0xFF) / 255 }
        let high = channels.max() ?? 0, low = channels.min() ?? 0
        let value = brightness ?? high
        let s = high > 0 ? (high - low) / high * saturation : 0
        let mapped = channels.map { c in
            high > low ? value * (1 - s * (high - c) / (high - low)) : value
        }
        r = mapped[0]
        g = mapped[1]
        b = mapped[2]
    }

    private init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func mixed(with other: GlowRGB, _ t: Double) -> GlowRGB {
        GlowRGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

/// Colors a glow drifts through, like voice-glow's slow hue drift
private struct GlowPalette {
    let colors: [GlowRGB]

    /// `position` walks the palette, blending between neighbors
    func color(at position: Double) -> Color {
        let count = Double(colors.count)
        let p = position.truncatingRemainder(dividingBy: count) + (position < 0 ? count : 0)
        let i = Int(p) % colors.count
        return colors[i].mixed(with: colors[(i + 1) % colors.count], p - p.rounded(.down)).color
    }

    /// The partner's rim: Claude orange for the beams' heads, then the orb's own rendered core,
    /// middle and halo (hue 22-23°) trailing behind them
    static let rim = GlowPalette(colors: [
        GlowRGB(0xE8714E), GlowRGB(0xFDA068), GlowRGB(0xFDB88D), GlowRGB(0xFCD4BD)
    ])

    /// The orb's hues (18-26°) at fuller saturation, so they read brighter orange: my bottom glow
    static let brightOrange = GlowPalette(colors: [
        GlowRGB(0xFF9450), GlowRGB(0xFF8B4A), GlowRGB(0xFFA262), GlowRGB(0xFF8F5E)
    ])

    func rgb(_ index: Int) -> Color { colors[index % colors.count].color }
}

// MARK: - Clock

/// Keeps a TimelineView running while an effect is on, and for `settle` seconds after it turns off,
/// so it can fade out; then lets it pause
private struct EffectClock: ViewModifier {
    let isOn: Bool
    let settle: TimeInterval
    @Binding var running: Bool
    @State private var stopID = 0

    func body(content: Content) -> some View {
        content
            .onAppear { running = isOn }
            .onChange(of: isOn) { _, on in
                stopID += 1
                if on {
                    running = true
                } else {
                    let id = stopID
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                        if stopID == id { running = false }
                    }
                }
            }
    }
}

/// Eases values toward their targets: quick to rise, slower to fall, like a VU meter
private final class GlowFollower {
    private(set) var values: [Double]
    private var lastDate: Date?

    init(count: Int) {
        values = Array(repeating: 0, count: count)
    }

    func step(targets: [Double], rise: [Double], fall: [Double], at date: Date) -> [Double] {
        let dt = min(max(date.timeIntervalSince(lastDate ?? date), 0), 0.1)
        lastDate = date
        for i in values.indices {
            let tau = targets[i] > values[i] ? rise[i] : fall[i]
            values[i] += (targets[i] - values[i]) * (1 - exp(-dt / tau))
        }
        return values
    }
}

/// The screen's corner radius, for light that hugs the display's edge (iPhone 17: about 55pt)
private let displayCornerRadius: CGFloat = 55

// MARK: - Bottom Voice Glow

/// voice-glow's "mobile" beam: seven soft lobes across the bottom edge, the middle one tallest,
/// rising and blooming with `level` (the middle band reacts first, the outer bands follow), with a
/// slow sideways flow and hue drift, and a bright line along the bottom edge of the screen.
/// `speechLike` flickers the level like a voice, for a side we have no meter for.
private struct BottomVoiceGlow: View {
    let level: CGFloat
    var speechLike = false
    let strength: CGFloat
    let palette: GlowPalette

    @State private var follower = GlowFollower(count: 4)  // three bands, then overall presence
    @State private var running = false

    /// Tallest the glow reaches, as a share of the screen height
    private static let reach: CGFloat = 0.34

    /// x and width as shares of the screen width, height as a share of `reach`; band 0 is the middle
    private static let lobes: [(x: CGFloat, width: CGFloat, height: CGFloat, band: Int)] = [
        (0.50, 0.46, 1.00, 0),
        (0.32, 0.36, 0.84, 1), (0.68, 0.36, 0.84, 1),
        (0.14, 0.32, 0.66, 2), (0.86, 0.32, 0.66, 2),
        (-0.02, 0.30, 0.50, 1), (1.02, 0.30, 0.50, 1)
    ]

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: !running)) { timeline in
                Canvas { context, size in
                    draw(in: &context, size: size, screenHeight: proxy.size.height, date: timeline.date)
                }
            }
            .frame(height: proxy.size.height * (Self.reach + 0.08))
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .modifier(EffectClock(isOn: level > 0, settle: 1.2, running: $running))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, screenHeight: CGFloat, date: Date) {
        let now = date.timeIntervalSinceReferenceDate
        let flicker = speechLike ? 0.72 + 0.28 * sin(now * 7.3) * cos(now * 2.9) : 1
        let v = Double(level) * flicker
        let values = follower.step(
            targets: [v, v * 0.85, v * 0.7, v > 0 ? 1 : 0],
            rise: [0.06, 0.09, 0.12, 0.15],
            fall: [0.35, 0.45, 0.55, 0.6],
            at: date
        )
        let presence = values[3]
        guard presence > 0.003 else { return }

        let t = date.timeIntervalSinceReferenceDate
        let maxHeight = screenHeight * Self.reach
        let strength = Double(strength)

        // The lobes, blurred into one glow
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 30))
            for (i, lobe) in Self.lobes.enumerated() {
                let band = values[lobe.band]
                let wobble = 1 + 0.07 * sin(t * 1.6 + Double(i) * 1.3)
                let height = maxHeight * lobe.height * CGFloat((0.2 + 0.8 * band) * wobble * presence)
                let width = size.width * lobe.width
                let x = size.width * lobe.x + CGFloat(sin(t * 0.5 + Double(i) * 2.1) * 10)
                let rect = CGRect(x: x - width / 2, y: size.height - height, width: width, height: height * 2)
                let color = palette.color(at: t / 3.2 + Double(i) * 0.6)
                let alpha = strength * (0.35 + 0.65 * band) * presence
                layer.fill(
                    Ellipse().path(in: rect),
                    with: .radialGradient(
                        Gradient(colors: [color.opacity(alpha), color.opacity(alpha * 0.5), color.opacity(0)]),
                        center: CGPoint(x: rect.midX, y: rect.midY),
                        startRadius: 0,
                        endRadius: max(width / 2, height)
                    )
                )
            }
        }

        // A bright line along the screen's bottom edge, brightest in the middle
        let screen = CGRect(x: 0, y: size.height - screenHeight, width: size.width, height: screenHeight)
        let edge = RoundedRectangle(cornerRadius: displayCornerRadius, style: .continuous)
            .inset(by: 1.5)
            .path(in: screen)
        let lineAlpha = strength * presence * (0.3 + 0.7 * values[0])
        let lineColor = palette.color(at: t / 3.2)
        let lineShading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: lineColor.opacity(0), location: 0),
                .init(color: lineColor.opacity(lineAlpha * 0.8), location: 0.25),
                .init(color: Color.white.opacity(lineAlpha), location: 0.5),
                .init(color: lineColor.opacity(lineAlpha * 0.8), location: 0.75),
                .init(color: lineColor.opacity(0), location: 1)
            ]),
            startPoint: CGPoint(x: 0, y: size.height),
            endPoint: CGPoint(x: size.width, y: size.height)
        )
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: 0, y: size.height - displayCornerRadius * 1.6, width: size.width, height: displayCornerRadius * 1.6)))
            layer.addFilter(.blur(radius: 5))
            layer.stroke(edge, with: lineShading, lineWidth: 6)
        }
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: 0, y: size.height - displayCornerRadius * 1.6, width: size.width, height: displayCornerRadius * 1.6)))
            layer.addFilter(.blur(radius: 0.6))
            layer.stroke(edge, with: lineShading, lineWidth: 1.5)
        }
    }
}

// MARK: - Edge Beam

/// border-beam's sunset beam on the screen's own edge, only on the bottom 40%: a steady warm light
/// in the bottom corners with brighter beams sweeping around through it, as a soft inner bloom, a
/// glow and a thin bright core. On while `level` is above 0, brighter the louder it is.
private struct EdgeBeam: View {
    let level: CGFloat
    let strength: CGFloat
    let palette: GlowPalette

    private var isActive: Bool { level > 0 }

    @State private var running = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds for a beam to go once around
    private static let period: TimeInterval = 6

    /// Two beams half a turn apart: each a head in the palette's first color with a tail through
    /// the next three, fading out, and a soft leading edge
    private var beamStops: [Gradient.Stop] {
        let head = palette.rgb(0), trail1 = palette.rgb(1), trail2 = palette.rgb(2), trail3 = palette.rgb(3)
        var stops: [Gradient.Stop] = []
        for start in [0.0, 0.5] {
            stops += [
                .init(color: head, location: start),
                .init(color: trail1.opacity(0.85), location: start + 0.06),
                .init(color: trail2.opacity(0.6), location: start + 0.14),
                .init(color: trail3.opacity(0.35), location: start + 0.24),
                .init(color: trail3.opacity(0), location: start + 0.34)
            ]
        }
        stops.append(.init(color: head, location: 1))
        return stops
    }

    var body: some View {
        TimelineView(.animation(paused: !running || reduceMotion)) { timeline in
            let turns = timeline.date.timeIntervalSinceReferenceDate / Self.period
            let beam = AngularGradient(
                stops: beamStops,
                center: .center,
                angle: .degrees(turns.truncatingRemainder(dividingBy: 1) * 360)
            )
            // The steady light in the palette's second color (for the rim, the orb's core)
            let base = palette.rgb(1)
            let edge = RoundedRectangle(cornerRadius: displayCornerRadius, style: .continuous)

            ZStack {
                // Steady warm light, so the corners never go dark between beams
                edge.inset(by: 8).stroke(base.opacity(0.6), lineWidth: 34).blur(radius: 24)
                edge.inset(by: 1).stroke(base.opacity(0.85), lineWidth: 3).blur(radius: 1.5)
                // The moving beams: inner bloom, glow, core
                edge.inset(by: 10).stroke(beam, lineWidth: 44).blur(radius: 28).opacity(0.7)
                edge.inset(by: 3).stroke(beam, lineWidth: 12).blur(radius: 8).opacity(0.95)
                edge.inset(by: 1.5).stroke(beam, lineWidth: 3).blur(radius: 0.6)
            }
            // Only the bottom 40% of the screen, fading in above it
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.60),
                        .init(color: .black, location: 0.76),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        // Fades in and out over 450ms; brightens with the level on a quicker ease
        .opacity(Double(strength) * (0.45 + 0.55 * Double(level)))
        .animation(.easeOut(duration: 0.18), value: level)
        .opacity(isActive ? 1 : 0)
        .animation(.easeInOut(duration: 0.45), value: isActive)
        .modifier(EffectClock(isOn: isActive, settle: 0.6, running: $running))
    }
}

#if DEBUG
// MARK: - Debug

/// GLOW section for the live screen's debug panel: preview either side's light, and its strength
struct VoiceGlowDebugSection: View {
    private var tuning: VoiceGlowTuning { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GLOW")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Button("Reset") {
                    withAnimation(.easeInOut(duration: 0.25)) { tuning.reset() }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .disabled(tuning.isDefault)
                .opacity(tuning.isDefault ? 0.4 : 1)
            }
            HStack(spacing: 6) {
                chip("Auto", .auto)
                chip("Me talking", .me)
                chip("They talk", .partner)
            }
            LayoutTunerRow("Mine %", value: tuning.mineStrength, range: 0...200) { tuning.mineStrength = max(0, $0) }
            LayoutTunerRow("Theirs %", value: tuning.theirsStrength, range: 0...200) { tuning.theirsStrength = max(0, $0) }
            LayoutTunerRow("Orb pulse %", value: tuning.orbPulse, range: 0...40) { tuning.orbPulse = max(0, $0) }
        }
        .frame(width: 280)
    }

    private func chip(_ label: String, _ preview: VoiceGlowTuning.Preview) -> some View {
        let isSelected = tuning.preview == preview
        return Button {
            tuning.preview = preview
        } label: {
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
#endif
