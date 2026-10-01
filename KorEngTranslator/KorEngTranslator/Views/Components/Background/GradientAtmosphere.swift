import SwiftUI

// MARK: - Gradient atmosphere
//
// The home gradient is still the classic three blurred ellipses (ClassicGradientOrb in
// WelcomeScreenLangSelect.swift), easing exactly as before, in the same coral / amber / peach.
// This wraps them with more life:
//   - three more pools in the same palette, each drifting on a slow figure-8 with its own
//     period, so the pattern never visibly repeats
//   - a liquid warp, a swirl toward the rim and an edge speckle (Metal distortion shader in
//     GradientAtmosphere.metal)
//   - film grain mixed into the orb's colour, and a page-wide grain overlay (GrainOverlay)
// Every number lives here so the look can be tuned in one place. Debug builds can switch back
// to the classic orb from the BACKGROUND picker in the debug card.

enum GradientAtmosphere {
    static let storageKey = "debugGradientAtmosphere"

    static var isEnabled: Bool {
        return true
    }

    /// The marigold pool above the cards: AppColors.gradientAmber turned 4% toward the original
    /// orange (hue 35 to 31 degrees, a touch more saturated) so it reads orange, not yellow, under
    /// the orb's saturation setting.
    static let marigold = Color(hex: "EC9C46")

    // The extra pools: same palette, drifting on figure-8s
    struct Pool {
        var color: Color
        var opacity: Double
        var size: CGSize
        var blur: CGFloat
        var home: CGPoint          // where the figure-8 is centered, in orb coordinates
        var sweep: CGSize          // half-width / half-height of the figure-8
        var period: Double         // seconds for one loop; all different, none a multiple of another
        var tilt: Double           // degrees the figure-8 is rotated
        var phase: Double          // where on the loop it starts
    }

    // Orb coordinates: the call site turns the orb -80 degrees, so local +x is screen-up and
    // local -y is screen-left. Opacities are 20% under their first cut.
    static let pools: [Pool] = [
        Pool(color: AppColors.gradientCoral, opacity: 0.44, size: CGSize(width: 280, height: 210),
             blur: 95, home: CGPoint(x: -70, y: 40), sweep: CGSize(width: 90, height: 55),
             period: 31, tilt: 20, phase: 0.15),
        Pool(color: AppColors.gradientAmber, opacity: 0.56, size: CGSize(width: 190, height: 130),
             blur: 70, home: CGPoint(x: 110, y: -30), sweep: CGSize(width: 75, height: 60),
             period: 47, tilt: -35, phase: 0.6),
        Pool(color: AppColors.gradientPeach, opacity: 0.64, size: CGSize(width: 150, height: 110),
             blur: 48, home: CGPoint(x: 20, y: -90), sweep: CGSize(width: 65, height: 45),
             period: 71, tilt: 70, phase: 0.35),
        // Two more above the cards: the brightest orange, then the middle orange
        Pool(color: AppColors.gradientPeach, opacity: 0.64, size: CGSize(width: 180, height: 125),
             blur: 58, home: CGPoint(x: 165, y: -35), sweep: CGSize(width: 70, height: 50),
             period: 41, tilt: -60, phase: 0.8),
        Pool(color: marigold, opacity: 0.56, size: CGSize(width: 200, height: 140),
             blur: 72, home: CGPoint(x: 135, y: -100), sweep: CGSize(width: 80, height: 55),
             period: 59, tilt: 15, phase: 0.45),
    ]

    // Motion, 1 = the first cut: `speed` runs every clock faster (the classic orb's swings, the
    // pools' loops and the warp); `movement` widens how far the classic orb and the pools travel
    static let speed: Double = 1.1
    static let movement: Double = 1.1

    // Warp / swirl / speckle (see liquidWarp in the .metal file)
    static let canvas: CGFloat = 960           // the orb is rasterised on this square, blur tails included
    static let distortion: Double = 0.8        // liquid warp strength
    static let swirlDegrees: Double = 18       // twist at the canvas rim; none at the center
    static let speckle: Double = 0.15          // sample-point jitter at colour edges
    static let colorGrain: Double = 0.10       // film grain mixed into the orb colour

    // Page grain (GrainOverlay). The gradient lab runs its overlay grain at 0.4, so this is
    // meant to be seen, not guessed at.
    static let pageGrainOpacity: Double = 0.15
    static let pageGrainSize: Double = 0.34    // points; about one device pixel

    // Colour: the palette stays coral / amber / peach, pulled toward the gradient lab's muted
    // oranges and reds (1 = the colours as defined in AppColors)
    static let saturation: Double = 0.76

    // Debug builds tune these three live from the BACKGROUND section of the debug card
    // (GradientAtmosphereDebugPicker); the values above are the defaults and what Release uses.
    static let grainOpacityKey = "debugGrainOpacity"
    static let grainSizeKey = "debugGrainSize"
    static let saturationKey = "debugGradientSaturation"

    /// The furthest any pixel of the orb is sampled from, so the shader gets enough of the layer
    static var maxSampleOffset: CGSize {
        let radius = canvas / 2
        let swirl = radius * swirlDegrees * .pi / 180
        let warp = distortion * radius * 0.06 * 1.6
        let jitter = speckle * radius * 0.02
        let reach = ceil(swirl + warp + jitter)
        return CGSize(width: reach, height: reach)
    }
}

// MARK: - Orb

/// The home gradient: the classic orb wrapped in the atmosphere (or on its own, from the Debug picker).
struct GradientOrb: View {
    private let atmosphere = true

    var body: some View {
        if atmosphere {
            AtmosphereGradientOrb()
        } else {
            ClassicGradientOrb()
        }
    }
}

struct AtmosphereGradientOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    private let saturation = GradientAtmosphere.saturation

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSince(start)
            let motionTime = t * GradientAtmosphere.speed   // the grain keeps real time
            let side = GradientAtmosphere.canvas
            ZStack {
                ClassicGradientOrb(speed: GradientAtmosphere.speed, movement: GradientAtmosphere.movement)
                ForEach(GradientAtmosphere.pools.indices, id: \.self) { i in
                    DriftingPool(pool: GradientAtmosphere.pools[i], time: motionTime)
                }
            }
            .frame(width: side, height: side)
            .distortionEffect(
                ShaderLibrary.liquidWarp(
                    .float(Float(motionTime)),
                    .float2(CGSize(width: side, height: side)),
                    .float(Float(GradientAtmosphere.distortion)),
                    .float(Float(GradientAtmosphere.swirlDegrees * .pi / 180)),
                    .float(Float(GradientAtmosphere.speckle))
                ),
                maxSampleOffset: GradientAtmosphere.maxSampleOffset
            )
            .colorEffect(
                ShaderLibrary.colorGrain(.float(Float(t)), .float(Float(GradientAtmosphere.colorGrain)))
            )
            .saturation(saturation)
        }
    }
}

/// One extra pool of colour, looping on a tilted figure-8
private struct DriftingPool: View {
    let pool: GradientAtmosphere.Pool
    let time: Double

    var body: some View {
        let theta = (time / pool.period + pool.phase) * 2 * .pi
        let x = pool.sweep.width * GradientAtmosphere.movement * sin(theta)
        let y = pool.sweep.height * GradientAtmosphere.movement * sin(2 * theta)
        let tilt = pool.tilt * .pi / 180
        let dx = x * cos(tilt) - y * sin(tilt)
        let dy = x * sin(tilt) + y * cos(tilt)
        // The pool also breathes a little, in step with its loop
        let scale = 1 + 0.08 * sin(theta * 1.5 + pool.phase)

        Ellipse()
            .fill(pool.color)
            .opacity(pool.opacity)
            .frame(width: pool.size.width, height: pool.size.height)
            .scaleEffect(scale)
            .rotationEffect(.degrees(pool.tilt + 12 * sin(theta)))
            .offset(x: pool.home.x + dx, y: pool.home.y + dy)
            .blur(radius: pool.blur)
    }
}

// MARK: - Page grain

/// Film grain over the whole page, blended with overlay so it only textures what is under it.
/// Sits on the background layers, under the content, so text, cards and buttons stay clean.
struct GrainOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    private let grainOpacity = GradientAtmosphere.pageGrainOpacity
    private let grainSize = GradientAtmosphere.pageGrainSize

    var body: some View {
        TimelineView(.periodic(from: start, by: reduceMotion ? 3600 : 1.0 / 24)) { context in
            Rectangle()
                .fill(.gray)
                .colorEffect(
                    ShaderLibrary.pageGrain(
                        .float(Float(context.date.timeIntervalSince(start))),
                        .float(Float(max(0.1, grainSize)))
                    )
                )
        }
        .blendMode(.overlay)
        .opacity(grainOpacity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
