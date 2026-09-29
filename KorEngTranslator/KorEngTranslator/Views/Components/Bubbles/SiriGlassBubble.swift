import SwiftUI

// MARK: - Siri Glass Bubble
//
// A warm, translucent "glass marble" take on the translator orb. It borrows the
// specular language of Apple's 2026 Siri orb (bright horizontal lens band, crisp
// rim light with dispersion, frosty upper hemisphere, blooming core + scalloped
// ripples while listening) but keeps OUR amorphous `AnimatableOrganicBlob`
// silhouette and OUR coral / amber / peach palette on the beige background.
// Siri's rainbow dispersion is mapped to coral (warm side) -> peach / white (cool side).
//
// Layer stack (bottom -> top), everything inside a 400x400 container:
//   1. Ripples + sparkles   Canvas: 4 scalloped (6-lobe) rings emanating from the rim (listening),
//                           one shared blur pass for all rings
//   2. Outer glow           1.7x blurred blob, radial coral -> peach, registers on beige, pulses with state
//   3. Body                 blob filled with a slowly rotating peach -> amber -> coral gradient
//   4. Inner colour flow    two blurred "lava" blobs drifting inside the body (masked)
//   5. Fresnel depth        multiply radial: rim darker / more saturated
//   6. Interior light       radial white, lighter towards the centre (glass depth)
//   7. Hemisphere sheen     frosty top, deeper bottom
//   8. Bloom core           white-peach radial that blooms while listening
//   9. Specular lens band   Canvas (screen blend): horizontal, slightly bowed band, widest at
//                           centre, tapering to a hairline where it meets the (bulged) rim
//  10. Rim light            angular-gradient strokes, brightest upper-left, second at lower-right,
//                           over a coral-left / amber-right dispersion fringe
//  11. Gloss                top-left highlight (ShineShape) + small lower-right counter gloss
//
// Motion: a single TimelineView(.animation), capped at 60 Hz, drives a phase engine. Every oscillator
// ACCUMULATES phase (phase += rate * dt) and the per-state parameter set is
// interpolated over 0.5 s on state change, so a change of state never snaps:
// speeds, amplitudes and intensities glide to their new targets while the phases
// stay continuous. audioLevel only adds amplitude on top of the always-alive base.

struct SiriGlassBubble: View {
    var state: OrbState = .idle
    var audioLevel: CGFloat = 0

    @State private var engine = SiriGlassEngine()

    // 570 (not 400) so the 1.7x halo's blur never meets the raster edge even at the listening
    // state's 1.35x peak scale (374pt halo + 44pt blur, x1.35 = 564); the host's 400pt
    // frame does not clip, exactly like CombinationBubble's 450pt container.
    private let containerSize: CGFloat = 570
    private let orbSize: CGFloat = 220

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            SiriGlassRenderer(
                frame: engine.advance(
                    to: timeline.date.timeIntervalSinceReferenceDate,
                    state: state,
                    level: audioLevel
                ),
                orbSize: orbSize,
                containerSize: containerSize
            )
        }
        .frame(width: containerSize, height: containerSize)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Per-state parameter set

/// Everything that differs between idle / listening / responding.
/// All fields are plain Doubles so the whole set can be linearly interpolated.
private struct SiriGlassParams {
    // Breathing scale
    var breathAmp: Double          // peak-to-peak scale added on top of 1.0
    var breathRate: Double         // rad/s
    // Blob morph
    var morphAmp: Double           // bulge amplitude (fraction of radius)
    var morphRate: Double          // rad/s
    var morphLevelGain: Double     // extra morph amplitude per unit of audio level
    // Internal colour flow
    var flowRate: Double           // rad/s
    // Specular band
    var bandRate: Double           // rad/s for drift / tilt / width breathing
    var bandDrift: Double          // vertical drift amplitude (fraction of radius)
    var bandTiltAmp: Double        // degrees
    var bandBaseWidth: Double      // thickness multiplier
    var bandWidthBreath: Double    // +- fraction of thickness breathing
    var bandPulse: Double          // 0...1: speech-cadence width / intensity pulsing
    var bandSweep: Double          // 0...1: hotspot sweeps along the band
    var bandIntensity: Double      // 0...1
    // Rim light
    var rimRate: Double            // rad/s
    var rimIntensity: Double       // 0...1
    // Outer glow
    var glowBase: Double
    var glowPulse: Double
    var glowLevelGain: Double
    // Listening bloom + ripples + sparkles
    var bloom: Double
    var bloomLevelGain: Double
    var ripple: Double
    var sparkle: Double
    // Scale reactions
    var scaleLevelGain: Double     // scale += gain * level
    var jitter: Double             // live jitter amplitude
    var pulseAmp: Double           // rhythmic responding pulses
    var pulseLevelGain: Double     // pulse amplitude grows with level
    var pulseRate: Double          // rad/s of the cadence oscillator
    // Glass look
    var interiorLight: Double
    var edgeDepth: Double
    var gloss: Double

    static func preset(for state: OrbState) -> SiriGlassParams {
        switch state {
        case .idle:
            // Calm: 1.00-1.03 breathing over ~4 s, slow morph, band drifts, rim shimmers.
            return SiriGlassParams(
                breathAmp: 0.03, breathRate: 2 * .pi / 4.0,
                morphAmp: 0.055, morphRate: 0.9, morphLevelGain: 0,
                flowRate: 0.55,
                bandRate: 1.3, bandDrift: 0.07, bandTiltAmp: 3, bandBaseWidth: 1.0,
                bandWidthBreath: 0.12, bandPulse: 0, bandSweep: 0, bandIntensity: 0.85,
                rimRate: 0.6, rimIntensity: 0.9,
                glowBase: 0.55, glowPulse: 0.2, glowLevelGain: 0,
                bloom: 0, bloomLevelGain: 0, ripple: 0, sparkle: 0,
                scaleLevelGain: 0, jitter: 0, pulseAmp: 0, pulseLevelGain: 0, pulseRate: 5.2,
                interiorLight: 0.42, edgeDepth: 1.0, gloss: 0.85
            )
        case .listening:
            // Blooms bright, rings emanate, faster + larger morph, scale follows the mic.
            return SiriGlassParams(
                breathAmp: 0.012, breathRate: 2.9,
                morphAmp: 0.13, morphRate: 2.8, morphLevelGain: 0.6,
                flowRate: 1.3,
                bandRate: 1.6, bandDrift: 0.05, bandTiltAmp: 6, bandBaseWidth: 0.9,
                bandWidthBreath: 0.2, bandPulse: 0, bandSweep: 0.4, bandIntensity: 0.7,
                rimRate: 1.45, rimIntensity: 1.0,
                glowBase: 0.85, glowPulse: 0.12, glowLevelGain: 0.25,
                bloom: 0.6, bloomLevelGain: 0.35, ripple: 1.0, sparkle: 1.0,
                // 0.34 puts the orb at ~1.18x at a typical gated speaking level (~0.5), ~1.35x at full level.
                scaleLevelGain: 0.34, jitter: 0.012, pulseAmp: 0, pulseLevelGain: 0, pulseRate: 6.2,
                interiorLight: 0.6, edgeDepth: 0.8, gloss: 0.95
            )
        case .responding:
            // Band pulses + sweeps with a speech-like cadence, rhythmic scale pulses, faster colour flow.
            return SiriGlassParams(
                breathAmp: 0.01, breathRate: 2.4,
                morphAmp: 0.095, morphRate: 1.9, morphLevelGain: 0.4,
                flowRate: 1.8,
                bandRate: 2.2, bandDrift: 0.08, bandTiltAmp: 7, bandBaseWidth: 1.15,
                bandWidthBreath: 0.12, bandPulse: 1, bandSweep: 1, bandIntensity: 0.78,
                rimRate: 1.2, rimIntensity: 0.95,
                glowBase: 0.65, glowPulse: 0.2, glowLevelGain: 0.15,
                bloom: 0.18, bloomLevelGain: 0.15, ripple: 0.12, sparkle: 0,
                scaleLevelGain: 0, jitter: 0.005, pulseAmp: 0.05, pulseLevelGain: 1.0, pulseRate: 6.2,
                interiorLight: 0.5, edgeDepth: 1.0, gloss: 0.9
            )
        }
    }

    private static let fields: [WritableKeyPath<SiriGlassParams, Double>] = [
        \.breathAmp, \.breathRate,
        \.morphAmp, \.morphRate, \.morphLevelGain,
        \.flowRate,
        \.bandRate, \.bandDrift, \.bandTiltAmp, \.bandBaseWidth,
        \.bandWidthBreath, \.bandPulse, \.bandSweep, \.bandIntensity,
        \.rimRate, \.rimIntensity,
        \.glowBase, \.glowPulse, \.glowLevelGain,
        \.bloom, \.bloomLevelGain, \.ripple, \.sparkle,
        \.scaleLevelGain, \.jitter, \.pulseAmp, \.pulseLevelGain, \.pulseRate,
        \.interiorLight, \.edgeDepth, \.gloss
    ]

    static func lerp(_ a: SiriGlassParams, _ b: SiriGlassParams, _ t: Double) -> SiriGlassParams {
        if t <= 0 { return a }
        if t >= 1 { return b }
        var out = a
        for field in fields {
            out[keyPath: field] = a[keyPath: field] + (b[keyPath: field] - a[keyPath: field]) * t
        }
        return out
    }
}

// MARK: - Per-frame render values

/// The fully evaluated, per-frame numbers the renderer draws from.
private struct SiriGlassFrame {
    var scale: Double = 1
    var top: Double = 0
    var right: Double = 0
    var bottom: Double = 0
    var left: Double = 0
    var flowAngle: Double = 0
    var lava1: CGPoint = .zero          // fraction of radius
    var lava2: CGPoint = .zero
    var bandOffsetY: Double = 0         // fraction of radius
    var bandTilt: Double = 0            // degrees
    var bandSway: Double = 0            // S-curve amount, fraction of radius
    var bandBow: Double = 0             // upward arc of the band middle, fraction of radius
    var bandWidth: Double = 1
    var bandIntensity: Double = 0.85
    var bandHot: Double = 0             // -1...1 hotspot position along the band
    var rimAngle: Double = 225          // degrees, where the rim is brightest
    var rimIntensity: Double = 0.9
    var glow: Double = 0.5
    var bloom: Double = 0
    var ripplePhase: Double = 0         // 0...2pi
    var rippleAmount: Double = 0
    var sparkleAmount: Double = 0
    var twinkle: Double = 0
    var interiorLight: Double = 0.45
    var edgeDepth: Double = 1
    var gloss: Double = 0.85
    var glossMorph: Double = 0
}

// MARK: - Phase engine

/// Owns the accumulated oscillator phases and the state cross-fade.
/// Mutated once per frame from inside the TimelineView closure; it is a reference
/// type on purpose so the per-frame update does not invalidate SwiftUI state.
private final class SiriGlassEngine {
    private let transitionDuration: TimeInterval = 0.5

    private var lastTime: TimeInterval?
    private var targetState: OrbState?
    private var fromParams = SiriGlassParams.preset(for: .idle)
    private var lastParams = SiriGlassParams.preset(for: .idle)
    private var transitionStart: TimeInterval = -1_000_000

    private var level: Double = 0
    private var breath: Double = 0
    private var morph: Double = 0
    private var flow: Double = 0
    private var band: Double = 0
    private var rim: Double = 0
    private var ripple: Double = 0
    private var pulse: Double = 0
    private var twinkle: Double = 0
    private var jitter: Double = 0

    func advance(to now: TimeInterval, state: OrbState, level rawLevel: CGFloat) -> SiriGlassFrame {
        // Clamp dt so a paused tab does not fast-forward every oscillator.
        let dt: Double
        if let last = lastTime {
            dt = min(max(now - last, 0), 1.0 / 20.0)
        } else {
            dt = 0
        }
        lastTime = now

        // Retarget: snapshot whatever we are currently showing and glide from there.
        if targetState != state {
            if targetState == nil {
                fromParams = .preset(for: state)
                transitionStart = -1_000_000
            } else {
                fromParams = lastParams
                transitionStart = now
            }
            targetState = state
        }
        let raw = min(max((now - transitionStart) / transitionDuration, 0), 1)
        let eased = raw * raw * (3 - 2 * raw)
        let p = SiriGlassParams.lerp(fromParams, .preset(for: state), eased)
        lastParams = p

        // Audio level: fast attack, slower release, so speech reads as energy not noise.
        let meter = Double(rawLevel)
        let target = meter.isFinite ? min(max(meter, 0), 1) : 0   // reject NaN/inf from the meter
        let smoothing = target > level ? 1 - exp(-dt * 20) : 1 - exp(-dt * 7)
        level += (target - level) * smoothing

        // Accumulate phases (rates may change every frame, phases never jump).
        breath += p.breathRate * dt
        morph += p.morphRate * dt
        flow += p.flowRate * dt
        band += p.bandRate * dt
        rim += p.rimRate * dt
        ripple = (ripple + (2 * .pi / 1.15) * dt).truncatingRemainder(dividingBy: 2 * .pi)
        pulse += p.pulseRate * dt
        twinkle += 3.8 * dt
        jitter += 21 * dt

        // Speech-like cadence: two incommensurate sines, half-wave rectified -> irregular 0.4-0.8 s pulses.
        // A 0.15 floor keeps the band from fully relaxing to the idle look between pulses.
        let cadence = 0.15 + 0.85 * max(0, 0.55 * sin(pulse) + 0.45 * sin(pulse * 1.71 + 0.9))

        var f = SiriGlassFrame()

        // Scale
        let breathScale = p.breathAmp * (0.5 + 0.5 * sin(breath))
        let levelScale = p.scaleLevelGain * level
        let jitterScale = p.jitter * (0.35 + 0.65 * level) * (0.5 * sin(jitter) + 0.5 * sin(jitter * 1.37 + 0.4))
        let pulseScale = p.pulseAmp * (1 + p.pulseLevelGain * level) * cadence
        f.scale = 1 + breathScale + levelScale + jitterScale + pulseScale

        // Blob morph: four independent oscillators with a touch of second harmonic.
        let a = p.morphAmp * (1 + p.morphLevelGain * level)
        f.top = a * (0.85 * sin(morph) + 0.25 * sin(morph * 2.3 + 1.0))
        f.right = a * (0.85 * sin(morph * 0.83 + 1.7) + 0.25 * sin(morph * 1.9 + 0.3))
        f.bottom = a * (0.85 * sin(morph * 1.13 + 3.1) + 0.25 * sin(morph * 2.1 + 2.2))
        f.left = a * (0.85 * sin(morph * 0.91 + 4.6) + 0.25 * sin(morph * 1.7 + 3.9))

        // Colour flow
        f.flowAngle = flow * 0.35
        f.lava1 = CGPoint(x: cos(flow * 0.5) * 0.32, y: sin(flow * 0.37 + 0.8) * 0.28)
        f.lava2 = CGPoint(x: cos(flow * 0.43 + 2.5) * 0.30, y: sin(flow * 0.61 + 1.9) * 0.30)

        // Specular band
        f.bandOffsetY = p.bandDrift * sin(band * 0.7 + 0.3)
        f.bandTilt = p.bandTiltAmp * sin(band * 0.53 + 1.2)
        f.bandSway = 0.015 * sin(band * 0.45 + 2.0)
        f.bandBow = 0.07 + 0.02 * sin(band * 0.5 + 0.7)
        let widthBreath = 1 + p.bandWidthBreath * sin(band * 0.9 + 2.0)
        let widthPulse = 1 + p.bandPulse * 0.8 * cadence * (0.6 + 0.4 * level)
        f.bandWidth = p.bandBaseWidth * widthBreath * widthPulse
        f.bandIntensity = min(1, p.bandIntensity * (1 + p.bandPulse * 0.5 * cadence))
        f.bandHot = p.bandSweep * 0.5 * sin(pulse * 0.61 + 0.5) * (0.6 + 0.4 * level)

        // Rim light
        f.rimAngle = 225 + 14 * sin(rim * 0.8)
        f.rimIntensity = min(1, p.rimIntensity * (0.85 + 0.15 * sin(rim * 1.9 + 0.7)) + p.bandPulse * 0.1 * cadence)

        // Glow / bloom
        f.glow = min(1, p.glowBase + p.glowPulse * (0.5 + 0.5 * sin(breath + 0.5)) + p.glowLevelGain * level + p.bandPulse * 0.2 * cadence)
        f.bloom = min(1, p.bloom * (0.9 + 0.1 * sin(breath * 2.5)) + p.bloomLevelGain * level)

        // Ripples / sparkles
        f.ripplePhase = ripple
        f.rippleAmount = p.ripple * (0.8 + 0.2 * level)
        f.sparkleAmount = p.sparkle * (0.6 + 0.4 * level)
        f.twinkle = twinkle

        // Glass look
        f.interiorLight = p.interiorLight + p.bloom * 0.1 * level
        f.edgeDepth = p.edgeDepth
        f.gloss = p.gloss
        f.glossMorph = 0.5 + 0.5 * sin(breath * 0.8 + 1.0)

        return f
    }
}

// MARK: - Renderer

private struct SiriGlassRenderer: View {
    let frame: SiriGlassFrame
    let orbSize: CGFloat
    let containerSize: CGFloat

    private let coral = AppColors.gradientCoral      // #FF7158
    private let amber = AppColors.gradientAmber      // #E8A84C
    private let peach = AppColors.gradientPeach      // #FFC068
    private let white = Color.white

    private var radius: CGFloat { orbSize / 2 }

    private var blob: AnimatableOrganicBlob {
        AnimatableOrganicBlob(
            topBulge: frame.top,
            rightBulge: frame.right,
            bottomBulge: frame.bottom,
            leftBulge: frame.left
        )
    }

    var body: some View {
        ZStack {
            // 1. Ripples + sparkles (not scaled with the orb; they spawn at the scaled rim)
            if frame.rippleAmount > 0.004 || frame.sparkleAmount > 0.004 {
                SiriGlassRippleCanvas(frame: frame, orbRadius: radius)
                    .frame(width: containerSize, height: containerSize)
            }

            ZStack {
                outerGlow              // 2
                bodyLayer              // 3
                colourFlowLayer        // 4
                fresnelEdgeLayer       // 5
                interiorLightLayer     // 6
                hemisphereSheenLayer   // 7
                if frame.bloom > 0.004 {
                    bloomLayer         // 8
                }
                specularBandLayer      // 9
                rimLightLayer          // 10
                glossLayer             // 11
            }
            .frame(width: containerSize, height: containerSize)
            .scaleEffect(frame.scale)
        }
        .frame(width: containerSize, height: containerSize)
        .drawingGroup()
    }

    // MARK: 2. Outer glow

    private var outerGlow: some View {
        // 1.7x silhouette-shaped halo with real alpha in the 1.0-1.5R band, so it
        // registers on beige (the 1.32x version was hidden under the body).
        let glowSize = orbSize * 1.7
        return blob
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: coral.opacity(0.55), location: 0.0),
                        .init(color: coral.opacity(0.50), location: 0.50),
                        .init(color: coral.mix(with: peach, by: 0.5).opacity(0.32), location: 0.68),
                        .init(color: peach.opacity(0.14), location: 0.84),
                        .init(color: peach.opacity(0.0), location: 1.0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: glowSize / 2
                )
            )
            .frame(width: glowSize, height: glowSize)
            .blur(radius: 22)
            .opacity(frame.glow)
    }

    // MARK: 3. Body

    private var bodyLayer: some View {
        let angle = frame.flowAngle + .pi / 4
        let dx = cos(angle) * 0.62
        let dy = sin(angle) * 0.62
        return blob
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: peach, location: 0.0),
                        .init(color: amber, location: 0.48),
                        .init(color: coral, location: 1.0)
                    ],
                    startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
                    endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
                )
            )
            .frame(width: orbSize, height: orbSize)
            .opacity(0.92)
    }

    // MARK: 4. Inner colour flow

    private var colourFlowLayer: some View {
        // Both lava lobes share one blur and one blob mask (one offscreen pass, not two).
        ZStack {
            Circle()
                .fill(coral)
                .frame(width: orbSize * 0.85, height: orbSize * 0.85)
                .offset(x: frame.lava1.x * radius, y: frame.lava1.y * radius)
                .opacity(0.8)

            Circle()
                .fill(peach)
                .frame(width: orbSize * 0.7, height: orbSize * 0.7)
                .offset(x: frame.lava2.x * radius, y: frame.lava2.y * radius)
                .opacity(0.85)
                .blendMode(.screen)
        }
        .frame(width: orbSize, height: orbSize)
        .blur(radius: 18)
        .mask { blob.frame(width: orbSize, height: orbSize) }
    }

    // MARK: 5. Fresnel edge (darker / more saturated rim)

    private var fresnelEdgeLayer: some View {
        let d = frame.edgeDepth
        return blob
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: coral.opacity(0.0), location: 0.0),
                        .init(color: coral.opacity(0.0), location: 0.58),
                        .init(color: coral.opacity(0.32 * d), location: 0.86),
                        .init(color: coral.opacity(0.64 * d), location: 1.0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius * 1.06
                )
            )
            .frame(width: orbSize, height: orbSize)
            .blendMode(.multiply)
    }

    // MARK: 6. Interior light (glass depth)

    private var interiorLightLayer: some View {
        let il = frame.interiorLight
        return blob
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: white.opacity(il), location: 0.0),
                        .init(color: white.opacity(il * 0.55), location: 0.33),
                        .init(color: white.opacity(0.0), location: 0.74)
                    ],
                    center: UnitPoint(x: 0.44, y: 0.42),
                    startRadius: 0,
                    endRadius: radius
                )
            )
            .frame(width: orbSize, height: orbSize)
    }

    // MARK: 7. Hemisphere sheen (frosty top, deeper bottom)

    private var hemisphereSheenLayer: some View {
        ZStack {
            blob
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: white.opacity(0.36), location: 0.0),
                            .init(color: white.opacity(0.14), location: 0.4),
                            .init(color: white.opacity(0.0), location: 0.56)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            blob
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: coral.opacity(0.0), location: 0.5),
                            .init(color: coral.opacity(0.24), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.multiply)
            // Refraction caustic: light passing through the marble pools at the lower rim.
            blob
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: white.opacity(0.42), location: 0.0),
                            .init(color: white.opacity(0.26), location: 0.45),
                            .init(color: white.opacity(0.0), location: 1.0)
                        ],
                        center: UnitPoint(x: 0.5, y: 1.12),
                        startRadius: 0,
                        endRadius: orbSize * 0.42
                    )
                )
        }
        .frame(width: orbSize, height: orbSize)
    }

    // MARK: 8. Bloom core (listening)

    private var bloomLayer: some View {
        let bloomSize = radius * 1.32
        return Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: white, location: 0.0),
                        .init(color: white.opacity(0.96), location: 0.38),
                        .init(color: peach.opacity(0.8), location: 0.62),
                        .init(color: coral.opacity(0.35), location: 0.82),
                        .init(color: coral.opacity(0.0), location: 1.0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: bloomSize / 2
                )
            )
            .frame(width: bloomSize, height: bloomSize)
            .blur(radius: 9)
            .opacity(frame.bloom)
            .frame(width: orbSize, height: orbSize)
            .mask { blob.frame(width: orbSize, height: orbSize) }
    }

    // MARK: 9. Specular lens band

    private var specularBandLayer: some View {
        SiriGlassBandCanvas(frame: frame, orbRadius: radius)
            .frame(width: orbSize * 1.3, height: orbSize * 1.3)
            .mask { blob.frame(width: orbSize, height: orbSize) }
            .blendMode(.screen)
    }

    // MARK: 10. Rim light

    private var rimGradient: AngularGradient {
        // Location 0 sits at `rimAngle` (upper-left) and runs clockwise:
        // top -> upper-right -> right -> lower-right -> bottom -> lower-left -> left.
        // Dispersion in our palette: coral-white on the left, peach-white on the right.
        let coralWhite = coral.mix(with: white, by: 0.55)
        let peachWhite = peach.mix(with: white, by: 0.5)
        return AngularGradient(
            stops: [
                .init(color: white.opacity(1.0), location: 0.0),          // upper-left: brightest
                .init(color: white.opacity(0.62), location: 0.125),       // top
                .init(color: peachWhite.opacity(0.42), location: 0.25),   // upper-right
                .init(color: peachWhite.opacity(0.62), location: 0.375),  // right: "cool" fringe -> peach-white
                .init(color: white.opacity(0.9), location: 0.5),          // lower-right: second highlight
                .init(color: peach.opacity(0.4), location: 0.625),        // bottom
                .init(color: coralWhite.opacity(0.45), location: 0.75),   // lower-left
                .init(color: coralWhite.opacity(0.8), location: 0.875),   // left: warm fringe -> coral-white
                .init(color: white.opacity(1.0), location: 1.0)
            ],
            center: .center,
            angle: .degrees(frame.rimAngle)
        )
    }

    /// Chromatic fringe under the white hairline: amber at 3 o'clock, coral at
    /// 9 o'clock, transparent top and bottom (same coral-left / amber-right split as
    /// the band). It strokes the same `blob` at the same frame, so it cannot misregister.
    private var dispersionGradient: AngularGradient {
        AngularGradient(
            stops: [
                .init(color: amber.opacity(0.85), location: 0.0),
                .init(color: amber.opacity(0), location: 0.14),
                .init(color: coral.opacity(0), location: 0.36),
                .init(color: coral.opacity(1.0), location: 0.5),
                .init(color: coral.opacity(0), location: 0.64),
                .init(color: amber.opacity(0), location: 0.86),
                .init(color: amber.opacity(0.85), location: 1.0)
            ],
            center: .center,
            angle: .degrees(6 * sin(frame.rimAngle * .pi / 180))
        )
    }

    private var rimLightLayer: some View {
        ZStack {
            blob
                .stroke(rimGradient, lineWidth: 3.6)
                .blur(radius: 2.4)
                .opacity(0.7)
            // Coloured fringe: the 1.4pt white hairline sits centred on this 3.2pt
            // stroke, so colour shows on both sides of it as a chromatic edge.
            // Normal blend on purpose: additive coral over beige clamps to white.
            blob
                .stroke(dispersionGradient, lineWidth: 3.2)
                .blur(radius: 1.0)
                .opacity(0.85)
            blob
                .stroke(rimGradient, lineWidth: 1.4)
                .blendMode(.plusLighter)
        }
        .frame(width: orbSize, height: orbSize)
        .opacity(frame.rimIntensity)
    }

    // MARK: 11. Gloss

    private var glossLayer: some View {
        ZStack {
            ShineShape(morphAmount: frame.glossMorph)
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: white.opacity(0.95), location: 0.0),
                            .init(color: white.opacity(0.5), location: 0.4),
                            .init(color: white.opacity(0.0), location: 1.0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 34
                    )
                )
                .frame(width: 68, height: 32)
                .blur(radius: 7)
                .rotationEffect(.degrees(140.59))
                .offset(x: -radius * 0.42, y: -radius * 0.56)
                .opacity(frame.gloss)

            // Small counter gloss at the lower-right rim: the second bright point of the Siri orb.
            Ellipse()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: white.opacity(0.55), location: 0),
                            .init(color: white.opacity(0), location: 1)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: radius * 0.12
                    )
                )
                .frame(width: radius * 0.22, height: radius * 0.07)
                .blur(radius: 3)
                .rotationEffect(.degrees(-38))
                .offset(x: radius * 0.40, y: radius * 0.50)
                .opacity(frame.gloss * 0.8)
        }
    }
}

// MARK: - Specular band canvas

/// Draws the horizontal lens band: a soft warm halo, a crisper lens body and a
/// white hairline, all sharing one horizontal gradient whose hotspot can sweep.
/// The lens is slightly wider than the orb and is masked by the blob afterwards,
/// so its tapering ends always meet the rim as a hairline.
private struct SiriGlassBandCanvas: View {
    let frame: SiriGlassFrame
    let orbRadius: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let intensity = frame.bandIntensity
            guard intensity > 0.002 else { return }

            let coral = AppColors.gradientCoral
            let amber = AppColors.gradientAmber
            let peach = AppColors.gradientPeach
            let white = Color.white

            let radius = orbRadius
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + frame.bandOffsetY * radius)
            // Reach past the bulged rim on each side (AnimatableOrganicBlob puts its side
            // points at R*(1+bulge)) so the blob mask always cuts the tips at the silhouette.
            let leftLength = radius * (1 + max(frame.left, 0) + 0.05)
            let rightLength = radius * (1 + max(frame.right, 0) + 0.05)
            let halfHeight = radius * 0.15 * frame.bandWidth
            let sway = frame.bandSway * radius
            let bowY = radius * frame.bandBow
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: frame.bandTilt * .pi / 180)

            let start = CGPoint(x: -leftLength, y: 0).applying(transform)
            let end = CGPoint(x: rightLength, y: 0).applying(transform)

            // Lens: two cubic arcs meeting at the ends. The middle bows upward by bowY
            // (tips stay on the midline so they still meet the rim as a hairline) with a
            // subtle S-sway. All three passes share this path so they bow together.
            func lens(_ h: CGFloat) -> Path {
                let c = h * 4 / 3   // cubic with both controls at -c peaks at 0.75c = h
                let x0 = -leftLength
                let x1 = rightLength
                var path = Path()
                path.move(to: CGPoint(x: x0, y: 0))
                path.addCurve(
                    to: CGPoint(x: x1, y: 0),
                    control1: CGPoint(x: x0 * 0.36, y: -c + sway - bowY),
                    control2: CGPoint(x: x1 * 0.36, y: -c - sway - bowY)
                )
                path.addCurve(
                    to: CGPoint(x: x0, y: 0),
                    control1: CGPoint(x: x1 * 0.36, y: c - sway - bowY),
                    control2: CGPoint(x: x0 * 0.36, y: c + sway - bowY)
                )
                path.closeSubpath()
                return path.applying(transform)
            }

            // Dispersion mapped to our palette: coral on the warm (left) end,
            // amber on the far end, peach shoulders, white hotspot in the middle.
            let hot = 0.5 + frame.bandHot * 0.16
            let warm = Gradient(stops: [
                .init(color: coral.opacity(0.0), location: 0.0),
                .init(color: coral.opacity(0.7), location: 0.06),
                .init(color: peach.opacity(0.9), location: 0.22),
                .init(color: white.opacity(0.95), location: hot - 0.09),
                .init(color: white, location: hot),
                .init(color: white.opacity(0.95), location: hot + 0.09),
                .init(color: peach.opacity(0.9), location: 0.78),
                .init(color: amber.opacity(0.45), location: 0.94),
                .init(color: amber.opacity(0.0), location: 1.0)
            ])
            let core = Gradient(stops: [
                .init(color: white.opacity(0.0), location: 0.0),
                .init(color: white.opacity(0.7), location: hot - 0.3),
                .init(color: white, location: hot),
                .init(color: white.opacity(0.7), location: hot + 0.3),
                .init(color: white.opacity(0.0), location: 1.0)
            ])

            // Soft halo
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 7))
                layer.opacity = 0.7 * intensity
                layer.fill(lens(halfHeight * 1.25), with: .linearGradient(warm, startPoint: start, endPoint: end))
            }
            // Lens body (crisp)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 1.6))
                layer.opacity = 0.92 * intensity
                layer.fill(lens(halfHeight * 0.68), with: .linearGradient(warm, startPoint: start, endPoint: end))
            }
            // Hairline sheen
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 0.8))
                layer.opacity = 0.88 * intensity
                layer.fill(lens(halfHeight * 0.2), with: .linearGradient(core, startPoint: start, endPoint: end))
            }
        }
    }
}

// MARK: - Ripple + sparkle canvas

private struct SiriGlassSparkle {
    let angle: Double
    let radius: Double    // fraction of orb radius
    let phase: Double
    let speed: Double
    let size: Double
}

/// Four scalloped (6-lobe) rings emanate from the (scaled) rim out to ~1.7x the
/// orb radius (capped 12pt inside the container) and fade; sparse warm sparkles
/// twinkle around them while listening.
private struct SiriGlassRippleCanvas: View {
    let frame: SiriGlassFrame
    let orbRadius: CGFloat

    private static let ringCount = 4
    private static let segments = 96

    /// Deterministic pseudo-random sparkle field (same every launch).
    private static let sparkles: [SiriGlassSparkle] = {
        var seed: UInt32 = 0x9E37_79B9
        func next() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed >> 8) / Double(1 << 24)
        }
        return (0..<28).map { _ in
            SiriGlassSparkle(
                angle: next() * 2 * .pi,
                radius: 1.08 + next() * 0.54,
                phase: next() * 2 * .pi,
                speed: 0.6 + next() * 1.2,
                size: 0.6 + next() * 0.9
            )
        }
    }()

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = orbRadius
            let coral = AppColors.gradientCoral
            let peach = AppColors.gradientPeach

            // Rings
            let amount = frame.rippleAmount
            if amount > 0.003 {
                let startRadius = radius * frame.scale
                let endRadius = radius * 1.7
                // Lobes never reach the container edge: 12pt margin leaves room for the
                // 7pt blurred glow stroke (+3pt blur) so nothing is cut by the container clip.
                let maxR = min(size.width, size.height) / 2 - 12
                let cycle = frame.ripplePhase / (2 * .pi)
                var rings: [(path: Path, color: Color, alpha: Double, width: CGFloat)] = []
                rings.reserveCapacity(Self.ringCount)
                for i in 0..<Self.ringCount {
                    let progress = (cycle + Double(i) / Double(Self.ringCount)).truncatingRemainder(dividingBy: 1)
                    let fadeIn = min(1, progress / 0.1)
                    let fadeOut = pow(1 - progress, 1.5)
                    let alpha = amount * fadeIn * fadeOut
                    if alpha < 0.005 { continue }

                    let travel = 1 - pow(1 - progress, 1.3)
                    let lobeAmp = 0.03 + 0.05 * progress
                    let ringRadius = min(startRadius + (endRadius - startRadius) * travel, maxR / (1 + lobeAmp))
                    let rotation = progress * 1.2 + Double(i) * 0.9
                    let path = Self.scallopedRing(center: center, radius: ringRadius, lobeAmp: lobeAmp, rotation: rotation)
                    rings.append((path, coral.mix(with: peach, by: progress), alpha, CGFloat(2.2 - 1.1 * progress)))
                }
                if !rings.isEmpty {
                    // One blurred glow pass for every ring, then one crisp pass
                    // (Canvas antialiasing is enough; no per-ring layers).
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 3))
                        for r in rings {
                            layer.stroke(r.path, with: .color(r.color.opacity(r.alpha * 0.28)), lineWidth: 7)
                        }
                    }
                    for r in rings {
                        context.stroke(r.path, with: .color(r.color.opacity(r.alpha * 0.6)), lineWidth: r.width)
                    }
                }
            }

            // Sparkles
            let sparkleAmount = frame.sparkleAmount
            if sparkleAmount > 0.003 {
                for sparkle in Self.sparkles {
                    let tw = max(0, sin(frame.twinkle * sparkle.speed + sparkle.phase))
                    let alpha = sparkleAmount * tw * tw * tw
                    if alpha < 0.02 { continue }
                    let drift = 1 + 0.05 * sin(frame.twinkle * 0.25 + sparkle.phase)
                    let r = radius * sparkle.radius * drift
                    let point = CGPoint(x: center.x + cos(sparkle.angle) * r, y: center.y + sin(sparkle.angle) * r)
                    let halo = sparkle.size * 3
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2)),
                        with: .color(peach.opacity(alpha * 0.3))
                    )
                    let s = sparkle.size
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - s, y: point.y - s, width: s * 2, height: s * 2)),
                        with: .color(coral.opacity(alpha))
                    )
                }
            }
        }
    }

    /// r(theta) = radius * (1 + lobeAmp * cos(6 theta + rotation))
    private static func scallopedRing(center: CGPoint, radius: CGFloat, lobeAmp: Double, rotation: Double) -> Path {
        var points: [CGPoint] = []
        points.reserveCapacity(segments + 1)
        for i in 0...segments {
            let theta = Double(i) / Double(segments) * 2 * .pi
            let r = radius * (1 + lobeAmp * cos(6 * theta + rotation))
            points.append(CGPoint(x: center.x + cos(theta) * r, y: center.y + sin(theta) * r))
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

// MARK: - Previews

#Preview("Siri Glass - Idle") {
    ZStack {
        AppColors.background.ignoresSafeArea()
        SiriGlassBubble(state: .idle)
    }
}

#Preview("Siri Glass - Listening") {
    ZStack {
        AppColors.background.ignoresSafeArea()
        SiriGlassBubble(state: .listening, audioLevel: 0.6)
    }
}

#Preview("Siri Glass - Responding") {
    ZStack {
        AppColors.background.ignoresSafeArea()
        SiriGlassBubble(state: .responding, audioLevel: 0.5)
    }
}

#Preview("Siri Glass - Interactive") {
    @Previewable @State var state: OrbState = .idle
    @Previewable @State var level: CGFloat = 0

    ZStack {
        AppColors.background.ignoresSafeArea()
        VStack(spacing: 24) {
            SiriGlassBubble(state: state, audioLevel: level)
                .frame(width: 400, height: 400)
            Picker("State", selection: $state) {
                ForEach(OrbState.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 32)
            Slider(value: $level, in: 0...1) {
                Text("Level")
            }
            .padding(.horizontal, 32)
        }
    }
}
