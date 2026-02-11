import SwiftUI

// MARK: - Glass Only Bubble (Style 2) - ACTIVE PROTOTYPE
// Elegant glass orb with outer ring, gradient border, internal color patches,
// realistic non-uniform pulsing, and glass highlight
// Updated with Figma specs: smoother blending, brighter whites, gradient strokes

struct GlassOnlyBubble: View {

    // MARK: - Colors

    private let deepCoral = AppColors.gradientCoral      // #FF7158
    private let goldenAmber = AppColors.gradientAmber    // #E8A84C
    private let warmPeach = AppColors.gradientPeach      // #FFC068
    private let borderWhite = Color(red: 254/255, green: 254/255, blue: 254/255)  // #FEFEFE

    // Outer ring stroke colors (from Figma)
    private let outerStrokeStart = Color(hex: "CA7464")  // warm terracotta
    private let outerStrokeMid = Color(hex: "E5A196")    // dusty rose
    private let outerStrokeEnd = Color(hex: "FFEAE6")    // pale peach

    // MARK: - Animation States

    // Non-uniform pulse (simulates varied audio input)
    @State private var pulseScale: CGFloat = 1.0

    // Internal gradient movement (constant, smooth)
    @State private var gradientRotation: Double = 0
    @State private var coralOffset1: CGSize = .zero
    @State private var coralOffset2: CGSize = .zero
    @State private var coralOffset3: CGSize = .zero
    @State private var amberOffset1: CGSize = .zero
    @State private var amberOffset2: CGSize = .zero
    @State private var peachOffset1: CGSize = .zero

    // MARK: - Constants

    private let glassOrbSize: CGFloat = 240
    private var outerRingSize: CGFloat { glassOrbSize * 1.25 }  // 25% bigger
    private var containerSize: CGFloat { outerRingSize * 1.2 + 60 }  // account for larger bg

    // MARK: - Body

    var body: some View {
        ZStack {
            // Layer 0: Drop shadow
            dropShadowLayer

            // Layer 1: Outer background glow (20% larger, radial fade)
            outerRingLayer

            // Layer 2: Outer ring stroke (1.2x size, gradient)
            outerRingStroke

            // Layer 3: Main glass orb with gradient border
            glassOrbLayer
        }
        .frame(width: containerSize, height: containerSize)
        .onAppear {
            startGradientAnimations()
            triggerRandomPulse()
        }
    }

    // MARK: - Layer 0: Drop Shadow

    private var dropShadowLayer: some View {
        Circle()
            .fill(Color.black.opacity(0.08))
            .frame(width: glassOrbSize, height: glassOrbSize)
            .blur(radius: 4)
            .offset(x: 4, y: 4)
    }

    // MARK: - Layer 1: Outer Ring (Background Glow)
    // Updated: 20% larger, 15% less opacity, radial fade to lighter edges

    private var outerRingLayer: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        goldenAmber.opacity(0.25),      // center (was 0.30, now 15% less)
                        goldenAmber.opacity(0.15),      // mid fade
                        goldenAmber.opacity(0.05)       // edges lighter
                    ],
                    center: .center,
                    startRadius: 10,
                    endRadius: outerRingSize * 1.2 / 2  // 20% larger radius
                )
            )
            .frame(width: outerRingSize * 1.2, height: outerRingSize * 1.2)  // 20% larger
            .blur(radius: 25)  // slightly more blur for softness
    }

    // MARK: - Layer 2: Outer Ring Stroke (1.2x size)
    // NEW: Decorative gradient stroke per Figma specs

    private var outerRingStroke: some View {
        Circle()
            .stroke(
                LinearGradient(
                    stops: [
                        .init(color: outerStrokeStart.opacity(0.40), location: 0.0),
                        .init(color: outerStrokeMid.opacity(0.20), location: 0.5),
                        .init(color: outerStrokeEnd.opacity(0.80), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 2
            )
            .frame(width: glassOrbSize * 1.2, height: glassOrbSize * 1.2)
    }

    // MARK: - Layer 3: Glass Orb

    private var glassOrbLayer: some View {
        ZStack {
            // Base glass fill (very light, desaturated)
            glassBaseFill

            // Internal color patches (washing around)
            internalColorPatches

            // Glass highlight (upper area white glow)
            glassHighlight

            // Gradient border
            whiteBorder
        }
        .frame(width: glassOrbSize, height: glassOrbSize)
        .clipShape(Circle())
        .scaleEffect(pulseScale)
    }

    // MARK: - Glass Base Fill

    private var glassBaseFill: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        warmPeach.opacity(0.25),
                        goldenAmber.opacity(0.20),
                        deepCoral.opacity(0.15),
                        warmPeach.opacity(0.18)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.5),
                    startRadius: 10,
                    endRadius: glassOrbSize / 2
                )
            )
    }

    // MARK: - Internal Color Patches (Washing Around)
    // Updated: Increased blur radii by 4-6pt for smoother blending

    private var internalColorPatches: some View {
        ZStack {
            // Coral patch - upper left
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            deepCoral.opacity(0.35),
                            deepCoral.opacity(0.15),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 50
                    )
                )
                .frame(width: 80, height: 70)
                .offset(x: -glassOrbSize * 0.22, y: -glassOrbSize * 0.25)
                .offset(coralOffset1)
                .blur(radius: 18)  // was 12

            // Coral patch - upper right
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            deepCoral.opacity(0.30),
                            deepCoral.opacity(0.10),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 45
                    )
                )
                .frame(width: 65, height: 55)
                .offset(x: glassOrbSize * 0.20, y: -glassOrbSize * 0.18)
                .offset(coralOffset2)
                .blur(radius: 16)  // was 10

            // Coral patch - lower middle
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            deepCoral.opacity(0.28),
                            deepCoral.opacity(0.08),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 40
                    )
                )
                .frame(width: 70, height: 60)
                .offset(x: glassOrbSize * 0.05, y: glassOrbSize * 0.28)
                .offset(coralOffset3)
                .blur(radius: 17)  // was 11

            // Amber/Orange patch - left side
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            goldenAmber.opacity(0.40),
                            goldenAmber.opacity(0.18),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 55
                    )
                )
                .frame(width: 90, height: 75)
                .offset(x: -glassOrbSize * 0.28, y: glassOrbSize * 0.05)
                .offset(amberOffset1)
                .blur(radius: 20)  // was 14

            // Amber/Orange patch - upper middle right
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            goldenAmber.opacity(0.35),
                            goldenAmber.opacity(0.12),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 50
                    )
                )
                .frame(width: 75, height: 65)
                .offset(x: glassOrbSize * 0.18, y: -glassOrbSize * 0.02)
                .offset(amberOffset2)
                .blur(radius: 18)  // was 12

            // Peach/Marigold patch - center glow
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            warmPeach.opacity(0.45),
                            warmPeach.opacity(0.20),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 60
                    )
                )
                .frame(width: 100, height: 85)
                .offset(x: glassOrbSize * 0.02, y: glassOrbSize * 0.08)
                .offset(peachOffset1)
                .blur(radius: 22)  // was 16

            // White accent - upper left (BRIGHTER)
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.50),  // was 0.25
                            Color.white.opacity(0.20),  // was 0.08
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 35
                    )
                )
                .frame(width: 55, height: 50)  // slightly larger
                .offset(x: -glassOrbSize * 0.15, y: -glassOrbSize * 0.12)
                .offset(coralOffset1.applying(CGAffineTransform(scaleX: 0.5, y: 0.5)))
                .blur(radius: 6)  // was 8, sharper now

            // White accent - right side (BRIGHTER)
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.40),  // was 0.20
                            Color.white.opacity(0.15),  // was 0.05
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 30
                    )
                )
                .frame(width: 50, height: 45)  // slightly larger
                .offset(x: glassOrbSize * 0.25, y: glassOrbSize * 0.10)
                .offset(amberOffset2.applying(CGAffineTransform(scaleX: 0.4, y: 0.4)))
                .blur(radius: 5)  // was 7, sharper now
        }
        .rotationEffect(.degrees(gradientRotation * 0.3))  // Very subtle overall rotation
    }

    // MARK: - Glass Highlight (Upper White Glow)

    private var glassHighlight: some View {
        ZStack {
            // Main upper highlight - aggressive white glow
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.30),
                            Color.white.opacity(0.10),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .frame(width: glassOrbSize * 0.75, height: glassOrbSize * 0.45)
                .offset(y: -glassOrbSize * 0.20)
                .blur(radius: 6)

            // Secondary highlight arc
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.40),
                            Color.white.opacity(0.15),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
                .frame(width: glassOrbSize * 0.5, height: glassOrbSize * 0.3)
                .offset(x: -glassOrbSize * 0.12, y: -glassOrbSize * 0.28)
                .blur(radius: 4)

            // Bright spot
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 20, height: 20)
                .offset(x: -glassOrbSize * 0.18, y: -glassOrbSize * 0.32)
                .blur(radius: 5)
        }
    }

    // MARK: - White Border (Gradient Stroke)
    // Updated: Linear gradient stroke per Figma specs, 2pt weight

    private var whiteBorder: some View {
        Circle()
            .stroke(
                LinearGradient(
                    stops: [
                        .init(color: borderWhite.opacity(1.0), location: 0.0),
                        .init(color: borderWhite.opacity(0.75), location: 0.5),
                        .init(color: borderWhite.opacity(0.40), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 2  // was 6
            )
            .frame(width: glassOrbSize, height: glassOrbSize)
    }

    // MARK: - Animations

    // Constant, smooth gradient movement
    private func startGradientAnimations() {
        // Slow overall rotation
        withAnimation(
            .linear(duration: 20)
            .repeatForever(autoreverses: false)
        ) {
            gradientRotation = 360
        }

        // Coral patches washing
        withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
            coralOffset1 = CGSize(width: 18, height: 12)
        }

        withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true)) {
            coralOffset2 = CGSize(width: -14, height: 16)
        }

        withAnimation(.easeInOut(duration: 3.8).repeatForever(autoreverses: true)) {
            coralOffset3 = CGSize(width: 12, height: -10)
        }

        // Amber patches washing
        withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
            amberOffset1 = CGSize(width: 15, height: -14)
        }

        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
            amberOffset2 = CGSize(width: -16, height: 10)
        }

        // Peach patch washing
        withAnimation(.easeInOut(duration: 5.0).repeatForever(autoreverses: true)) {
            peachOffset1 = CGSize(width: -12, height: 14)
        }
    }

    // Non-uniform pulse (simulates varied audio)
    private func triggerRandomPulse() {
        // Random scale between 1.02 and 1.12 (varied intensity)
        let targetScale = CGFloat.random(in: 1.02...1.12)

        // Random duration between 0.3 and 0.8 (varied word lengths)
        let pulseDuration = Double.random(in: 0.3...0.8)

        // Random pause between pulses (0.1 to 0.5 seconds)
        let pauseDuration = Double.random(in: 0.1...0.5)

        // Animate to target scale
        withAnimation(.easeOut(duration: pulseDuration * 0.4)) {
            pulseScale = targetScale
        }

        // Animate back to base
        DispatchQueue.main.asyncAfter(deadline: .now() + pulseDuration * 0.4) {
            withAnimation(.easeIn(duration: pulseDuration * 0.6)) {
                self.pulseScale = 1.0
            }
        }

        // Schedule next pulse
        DispatchQueue.main.asyncAfter(deadline: .now() + pulseDuration + pauseDuration) {
            self.triggerRandomPulse()
        }
    }
}

// MARK: - Preview

#Preview("Glass Bubble - Active") {
    ZStack {
        AppColors.background.ignoresSafeArea()
        GlassOnlyBubble()
    }
}
