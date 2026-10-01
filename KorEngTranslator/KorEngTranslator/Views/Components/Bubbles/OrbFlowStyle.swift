import SwiftUI

#if DEBUG
extension BubbleStyle {
    /// The orb the live screen starts with: `-orbStyle flow|combination|organic|glass` (Release
    /// builds always start with Combination)
    static var launchDefault: BubbleStyle {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-orbStyle"), i + 1 < args.count,
           let style = allCases.first(where: { $0.launchName == args[i + 1].lowercased() }) {
            return style
        }
        return .combination
    }

    fileprivate var launchName: String {
        switch self {
        case .organic: return "organic"
        case .glass: return "glass"
        case .combination: return "combination"
        case .flow: return "flow"
        }
    }
}

// MARK: - Flow (reel) orb style
//
// The orb as the Remotion reel (~/Projects/dari-reel, FlowOrb) draws it: the app's own orb, motion
// and all, with its colors flowing inside it like a soft gradient field. The reel's big orb shrinks
// onto the phone's orb in a match cut, so the phone's recording must show this same orb. Back to
// front: the app's halo and inner gradient at 40%; a glow of the field (calmed toward its average
// color, blurred 30pt, under the halo's fade); the field itself inside the blob (blurred 10pt, under
// the inner fade); then the app's glass, rim and shine. CombinationBubble draws the layers.
//
//   -orbStyle flow          picks it at launch (also BUBBLE STYLE in the live screen's debug panel)
//   -orbFlowClock 24.8      the field's clock at t = 0 of the live demo (else when the orb appears):
//                           24.8 s continues the reel's orb from the phone's landing
//   -orbFlowAngle 199.2     the blob's turn at t = 0, in degrees: the reel's orb at the landing.
//   -orbHaloAngle 135.8     the same for the halo's own turn. Without them the orb starts its turn
//                           at 0 when it appears, as the app does

struct OrbFlowStyle {
    /// The field's clock, in seconds, at t = 0 (see OrbFlowClock)
    var clockAtStart: Double = 24.8
    /// The blob's and the halo's rotation at t = 0, in degrees; nil = the app's own start
    var orbAngleAtStart: Double?
    var haloAngleAtStart: Double?

    static let launch = OrbFlowStyle(arguments: ProcessInfo.processInfo.arguments)

    init(arguments args: [String]) {
        func number(after flag: String) -> Double? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return Double(args[i + 1])
        }
        if let clock = number(after: "-orbFlowClock") { clockAtStart = clock }
        orbAngleAtStart = number(after: "-orbFlowAngle")
        haloAngleAtStart = number(after: "-orbHaloAngle")
    }

    // The look, in the app's points for the 200pt blob

    /// Shader time per second of the field's clock
    static let speed = 1.92
    /// The domain warp, the swirl, and how sharply the colors meet (weights 1 / distance^1.6)
    static let warp: Float = 0.3
    static let swirl: Float = 0.12
    static let sharpness: Float = 1.6
    /// The square the colors roam: 75% of the blob, so they stay inside the ball
    static let roam: CGFloat = 150
    /// The app's colored layers underneath
    static let underlayOpacity = 0.4
    static let glowOpacity = 0.62
    static let glowBlur: CGFloat = 30
    /// The glow's colors are pulled this far toward their average
    static let glowCalm = 0.35
    static let bodyOpacity = 0.72
    static let bodyBlur: CGFloat = 10

    /// The reel's softened orb palette, sRGB (not through the app's P3 Color(hex:)): a pale light
    /// between the colors, then peach, amber, coral orange and coral
    static let palette: [UInt32] = [0xF6D7B6, 0xF0C280, 0xE2AC68, 0xE99469, 0xE57C69]
    static let light = srgb(palette[0]), peach = srgb(palette[1]), amber = srgb(palette[2])
    static let coralOrange = srgb(palette[3]), coral = srgb(palette[4])

    /// The field's colors as RGB triples for the shader, sRGB-encoded 0...1
    static let fieldColors: [Float] = palette.flatMap(channels).map { Float($0) / 255 }
    /// The glow's: each channel pulled `glowCalm` of the way to the palette's average, in 8-bit like the reel
    static let glowColors: [Float] = {
        let rgb = palette.map(channels)
        let mean = (0..<3).map { c in rgb.reduce(0) { $0 + $1[c] } / Double(rgb.count) }
        return rgb.flatMap { v in (0..<3).map { c in Float((v[c] + (mean[c] - v[c]) * glowCalm).rounded()) / 255 } }
    }()

    private static func channels(_ hex: UInt32) -> [Double] {
        [16, 8, 0].map { Double((hex >> UInt32($0)) & 0xFF) }
    }

    private static func srgb(_ hex: UInt32) -> Color {
        let c = channels(hex)
        return Color(.sRGB, red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255)
    }

    /// The app's radial fade (CombinationBubble's halo and inner masks) out to `radius`
    static func fade(radius: CGFloat) -> some View {
        RadialGradient(
            stops: [
                .init(color: .white.opacity(1.0), location: 0.0),
                .init(color: .white.opacity(0.70), location: 0.35),
                .init(color: .white.opacity(0.40), location: 0.59),
                .init(color: .white.opacity(0.30), location: 0.72),
                .init(color: .white.opacity(0.10), location: 0.87),
                .init(color: .white.opacity(0.0), location: 1.0)
            ],
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
        .frame(width: radius * 2, height: radius * 2)
    }

    /// Where a turn that runs `period` seconds per revolution should start `delay` from now, so it
    /// reads `angle` at t = 0. Nil without an angle; the angle itself when there's no t = 0 yet.
    @MainActor
    static func startAngle(_ angle: Double?, period: Double, startingIn delay: Double) -> Double? {
        guard let angle else { return nil }
        guard let t0 = OrbFlowClock.demoStart else { return angle }
        let startsAt = CACurrentMediaTime() + delay
        return angle - 360 * (t0.media - startsAt) / period
    }
}

// MARK: - Clock

/// The field's clock. In the live recording demo it reads `clockAtStart` at the take's t = 0
/// (LiveRecordingDemo); otherwise from when the first flowing orb appeared.
@MainActor
enum OrbFlowClock {
    /// Set by the live demo: t = 0 on both clocks
    static var demoStart: (media: CFTimeInterval, date: Date)? {
        LiveRecordingDemo.isOn ? LiveRecordingDemoState.shared.start : nil
    }
    private static var firstSeen: Date?

    /// Shader time at `date`
    static func time(at date: Date) -> Float {

        let start: Date
        if let demo = demoStart {
            start = demo.date
        } else {
            if firstSeen == nil { firstSeen = date }
            start = firstSeen ?? date
        }
        let seconds = OrbFlowStyle.launch.clockAtStart + date.timeIntervalSince(start)
        return Float(seconds * OrbFlowStyle.speed)
    }
}

// MARK: - Field

/// The flowing field filling a `side`-point square, its colors roaming the centered `roam` square
struct OrbFlowField: View {
    let side: CGFloat
    let colors: [Float]

    var body: some View {
        TimelineView(.animation) { context in
            Rectangle()
                .fill(.white)
                .colorEffect(ShaderLibrary.orbFlowField(
                    .float2(side, side),
                    .float(Float(OrbFlowStyle.roam)),
                    .float(OrbFlowClock.time(at: context.date)),
                    .float(OrbFlowStyle.warp),
                    .float(OrbFlowStyle.swirl),
                    .float(OrbFlowStyle.sharpness),
                    .floatArray(colors)
                ))
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }
}
#endif
