import SwiftUI

// MARK: - Combination Bubble (Style 3)
// Sophisticated 6-layer animated glass orb with voice reactivity simulation
// Layers: Gradient Blur Background, Glass Middle, Main Orb, Top Glass Blur, Stroke, Shine

struct CombinationBubble: View {

    // MARK: - Animation States

    // Main orb group
    @State private var orbRotation: Double = 0
    /// The gradient halo turns on its own, slower clock
    @State private var haloRotation: Double = 0
    @State private var orbScale: CGFloat = 1.0
    @State private var topBulge: CGFloat = 0
    @State private var rightBulge: CGFloat = 0
    @State private var bottomBulge: CGFloat = 0
    @State private var leftBulge: CGFloat = 0

    // Internal gradient (animating stop positions)
    @State private var gradientStop1: CGFloat = 0.14
    @State private var gradientStop2: CGFloat = 0.31
    @State private var gradientStop3: CGFloat = 0.45
    @State private var gradientStop4: CGFloat = 0.68

    // Shine (independent)
    @State private var shineScale: CGFloat = 1.0
    @State private var shineMorph: CGFloat = 0
    @State private var shineGradientIntensity: CGFloat = 0.80

    // MARK: - Constants

    private let backgroundSize: CGFloat = 360   // halo diameter (10% under the original 400)
    private let orbSize: CGFloat = 200
    private let containerSize: CGFloat = 450

    // Colors
    private let deepCoral = AppColors.gradientCoral          // #FF7158
    private let goldenAmber = AppColors.gradientAmber        // #E8A84C
    private let warmPeach = AppColors.gradientPeach          // #FFC068
    private let coralOrange = Color(hex: "F38D52")           // Mid-tone
    private let white = Color(hex: "FEFEFE")                 // Slightly off-white

    // MARK: - Body

    var body: some View {
        ZStack {
            classicLayers

            // Layer 6: Shine (independent)
            shineLayer
                .scaleEffect(shineScale)
        }
        .frame(width: containerSize, height: containerSize)
        .drawingGroup()
        .onAppear {
            startAnimations()
        }
    }

    /// Where each turn's repeating animation ends: one full turn past where it starts
    private var orbTurnEnd: Double {
        return 360
    }

    private var haloTurnEnd: Double {
        return 360
    }

    /// Layers 1-5
    @ViewBuilder
    private var classicLayers: some View {
        // Layer 1: Gradient Blur Background - breathes with the orb, turns on its own clock
        gradientBlurBackground
            .rotationEffect(.degrees(haloRotation))
            .scaleEffect(orbScale)

        // Layers 2-5: Main Orb Group
        mainOrbGroup
            .rotationEffect(.degrees(orbRotation))
            .scaleEffect(orbScale)
    }

    // MARK: - Layer 1: Gradient Blur Background

    private var gradientBlurBackground: some View {
        ZStack {
            // Colored gradient
            LinearGradient(
                stops: [
                    .init(color: AppColors.gradientCoral, location: 0.0),
                    .init(color: AppColors.gradientPeach, location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.80)
        }
        .frame(width: backgroundSize, height: backgroundSize)
        .mask(
            // Radial gradient mask for fade-out effect
            RadialGradient(
                stops: [
                    .init(color: white.opacity(1.0), location: 0.0),
                    .init(color: white.opacity(0.70), location: 0.35),
                    .init(color: white.opacity(0.40), location: 0.59),
                    .init(color: white.opacity(0.30), location: 0.72),
                    .init(color: white.opacity(0.10), location: 0.87),
                    .init(color: white.opacity(0.0), location: 1.0)
                ],
                center: .center,
                startRadius: 0,
                endRadius: backgroundSize / 2
            )
        )
    }

    // MARK: - Layers 2-5: Main Orb Group

    private var mainOrbGroup: some View {
        ZStack {
            // Layer 2: Glass Middle Layer
            glassMiddleLayer

            // Layer 3: Main Orb
            mainOrbLayer

            // Layer 4: Top Glass Blur
            topGlassBlurLayer

            // Layer 5: Stroke
            strokeLayer
        }
    }

    // MARK: - Layer 2: Glass Middle Layer

    private var glassMiddleLayer: some View {
        AnimatableOrganicBlob(
            topBulge: topBulge,
            rightBulge: rightBulge,
            bottomBulge: bottomBulge,
            leftBulge: leftBulge
        )
        .fill(white.opacity(0.20))
        .frame(width: orbSize, height: orbSize)
        .shadow(color: Color(hex: "121212").opacity(0.005), radius: 2, x: 0, y: 0)
        .shadow(color: Color(hex: "FF7158").opacity(0.05), radius: 20, x: 0, y: 0)
        .blur(radius: 5)
    }

    // MARK: - Layer 3: Main Orb (Masked Gradient)

    private var mainOrbLayer: some View {
        AnimatableOrganicBlob(
            topBulge: topBulge,
            rightBulge: rightBulge,
            bottomBulge: bottomBulge,
            leftBulge: leftBulge
        )
        .fill(animatingLinearGradient)
        .frame(width: orbSize, height: orbSize)
        .opacity(0.80)
        .mask(
            RadialGradient(
                stops: [
                    .init(color: white.opacity(1.0), location: 0.0),
                    .init(color: white.opacity(0.70), location: 0.35),
                    .init(color: white.opacity(0.40), location: 0.59),
                    .init(color: white.opacity(0.30), location: 0.72),
                    .init(color: white.opacity(0.10), location: 0.87),
                    .init(color: white.opacity(0.0), location: 1.0)
                ],
                center: .center,
                startRadius: 0,
                endRadius: orbSize / 2
            )
        )
    }

    private var animatingLinearGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: warmPeach.opacity(1.0), location: gradientStop1),
                .init(color: goldenAmber.opacity(0.50), location: gradientStop2),
                .init(color: coralOrange.opacity(0.75), location: gradientStop3),
                .init(color: deepCoral.opacity(1.0), location: gradientStop4)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Layer 4: Top Glass Blur Layer

    private var topGlassBlurLayer: some View {
        AnimatableOrganicBlob(
            topBulge: topBulge,
            rightBulge: rightBulge,
            bottomBulge: bottomBulge,
            leftBulge: leftBulge
        )
        .fill(white.opacity(0.05))
        .frame(width: orbSize, height: orbSize)
        // TODO: Add noise texture overlay (use tileable noise PNG with .blendMode(.overlay) at ~3% opacity)
    }

    // MARK: - Layer 5: Stroke (Outside position per Figma)

    private var strokeLayer: some View {
        AnimatableOrganicBlob(
            topBulge: topBulge,
            rightBulge: rightBulge,
            bottomBulge: bottomBulge,
            leftBulge: leftBulge
        )
        .stroke(
            LinearGradient(
                stops: [
                    .init(color: white.opacity(1.0), location: 0.0),
                    .init(color: white.opacity(0.75), location: 0.5),
                    .init(color: white.opacity(0.40), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 1
        )
        .frame(width: orbSize + 1, height: orbSize + 1)  // Slightly larger to simulate outside stroke
        .opacity(0.50)
    }

    // MARK: - Layer 6: Shine (Independent - does NOT rotate with orb)

    private var shineLayer: some View {
        ShineShape(morphAmount: shineMorph)
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: white.opacity(shineGradientIntensity), location: 0.0),
                        .init(color: white.opacity(shineGradientIntensity * 0.5), location: 0.40),
                        .init(color: white.opacity(0.0), location: 1.0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 30
                )
            )
            .frame(width: 60, height: 28)
            .blur(radius: 10)
            .rotationEffect(.degrees(140.59))  // Shine's own fixed rotation
            .offset(x: -orbSize * 0.20, y: -orbSize * 0.28)  // Upper-left quadrant (adjust to match Figma)
    }

    // MARK: - Animation Functions

    private func startAnimations() {
        // Stagger animation starts slightly to avoid SwiftUI batching issues

        // 1. Orb rotation, and the halo's own slower one (slow, continuous)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                orbRotation = orbTurnEnd
            }
            withAnimation(.linear(duration: 44).repeatForever(autoreverses: false)) {
                haloRotation = haloTurnEnd
            }
        }

        // 2. Smooth Blob Morphing (each point independent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            startSmoothBlobAnimation()
        }

        // 3. Smooth Scale Breathing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startScaleBreathing()
        }

        // 4. Internal Gradient Stop Animation (slow, constant shift)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            startGradientAnimation()
        }

        // 5. Shine Animations (independent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            startShineAnimations()
        }
    }

    private func startSmoothBlobAnimation() {
        // Each control point animates at a DIFFERENT speed
        // This creates organic, never-repeating patterns
        // Durations based on reference video timing (~2-4 second cycles)

        // Top bulge
        withAnimation(
            Animation.easeInOut(duration: 3.2)
                .repeatForever(autoreverses: true)
        ) {
            topBulge = 0.08
        }

        // Right bulge - slightly faster
        withAnimation(
            Animation.easeInOut(duration: 2.7)
                .repeatForever(autoreverses: true)
        ) {
            rightBulge = 0.10
        }

        // Bottom bulge
        withAnimation(
            Animation.easeInOut(duration: 3.5)
                .repeatForever(autoreverses: true)
        ) {
            bottomBulge = 0.07
        }

        // Left bulge - different timing
        withAnimation(
            Animation.easeInOut(duration: 2.9)
                .repeatForever(autoreverses: true)
        ) {
            leftBulge = 0.09
        }
    }

    private func startScaleBreathing() {
        // Gentle breathing scale - synced for orb and shine
        withAnimation(
            Animation.easeInOut(duration: 4.0)
                .repeatForever(autoreverses: true)
        ) {
            orbScale = 1.04
        }

        // Shine scale follows but with slight variation
        withAnimation(
            Animation.easeInOut(duration: 4.2)
                .repeatForever(autoreverses: true)
        ) {
            shineScale = 1.04
        }
    }

    private func startGradientAnimation() {
        // Linear gradient stops shift slowly and continuously
        // This makes the colors appear to "flow" inside the orb
        withAnimation(
            Animation.easeInOut(duration: 8.0)
                .repeatForever(autoreverses: true)
        ) {
            gradientStop1 = 0.25
            gradientStop2 = 0.42
            gradientStop3 = 0.63
            gradientStop4 = 0.88
        }
    }

    private func startShineAnimations() {
        // Gentle shape morphing
        withAnimation(
            Animation.easeInOut(duration: 5.0)
                .repeatForever(autoreverses: true)
        ) {
            shineMorph = 1.0
        }

        // Subtle gradient intensity shift
        withAnimation(
            Animation.easeInOut(duration: 6.0)
                .repeatForever(autoreverses: true)
        ) {
            shineGradientIntensity = 0.95
        }
    }
}

// MARK: - Animatable Organic Blob Shape

struct AnimatableOrganicBlob: Shape {
    // 4 control points for cardinal directions
    var topBulge: CGFloat      // How far top point extends (negative = inward)
    var rightBulge: CGFloat
    var bottomBulge: CGFloat
    var leftBulge: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(topBulge, rightBulge),
                AnimatablePair(bottomBulge, leftBulge)
            )
        }
        set {
            topBulge = newValue.first.first
            rightBulge = newValue.first.second
            bottomBulge = newValue.second.first
            leftBulge = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let centerX = rect.midX
        let centerY = rect.midY
        let baseRadius = min(rect.width, rect.height) / 2

        // Cardinal points with bulge
        let topPoint = CGPoint(x: centerX, y: centerY - baseRadius * (1 + topBulge))
        let rightPoint = CGPoint(x: centerX + baseRadius * (1 + rightBulge), y: centerY)
        let bottomPoint = CGPoint(x: centerX, y: centerY + baseRadius * (1 + bottomBulge))
        let leftPoint = CGPoint(x: centerX - baseRadius * (1 + leftBulge), y: centerY)

        // Circular bezier magic number for smooth curves
        let k: CGFloat = 0.552284749831

        var path = Path()
        path.move(to: topPoint)

        // Top to Right
        let tr_cp1 = CGPoint(x: topPoint.x + baseRadius * k, y: topPoint.y)
        let tr_cp2 = CGPoint(x: rightPoint.x, y: rightPoint.y - baseRadius * k)
        path.addCurve(to: rightPoint, control1: tr_cp1, control2: tr_cp2)

        // Right to Bottom
        let rb_cp1 = CGPoint(x: rightPoint.x, y: rightPoint.y + baseRadius * k)
        let rb_cp2 = CGPoint(x: bottomPoint.x + baseRadius * k, y: bottomPoint.y)
        path.addCurve(to: bottomPoint, control1: rb_cp1, control2: rb_cp2)

        // Bottom to Left
        let bl_cp1 = CGPoint(x: bottomPoint.x - baseRadius * k, y: bottomPoint.y)
        let bl_cp2 = CGPoint(x: leftPoint.x, y: leftPoint.y + baseRadius * k)
        path.addCurve(to: leftPoint, control1: bl_cp1, control2: bl_cp2)

        // Left to Top
        let lt_cp1 = CGPoint(x: leftPoint.x, y: leftPoint.y - baseRadius * k)
        let lt_cp2 = CGPoint(x: topPoint.x - baseRadius * k, y: topPoint.y)
        path.addCurve(to: topPoint, control1: lt_cp1, control2: lt_cp2)

        return path
    }
}

// MARK: - Shine Shape

struct ShineShape: Shape {
    var morphAmount: CGFloat

    var animatableData: CGFloat {
        get { morphAmount }
        set { morphAmount = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let width = rect.width
        let height = rect.height

        // Create organic curved kidney-bean/crescent shape
        // Morph amount affects the curvature subtly
        let morphOffset = morphAmount * 3

        // Start from left side
        path.move(to: CGPoint(x: width * 0.1, y: height * 0.5))

        // Upper curve (left to top-middle)
        path.addQuadCurve(
            to: CGPoint(x: width * 0.5, y: height * 0.15 - morphOffset),
            control: CGPoint(x: width * 0.2, y: height * 0.1)
        )

        // Upper curve (top-middle to right)
        path.addQuadCurve(
            to: CGPoint(x: width * 0.9, y: height * 0.4),
            control: CGPoint(x: width * 0.8, y: height * 0.1 + morphOffset)
        )

        // Lower curve (right to bottom-middle)
        path.addQuadCurve(
            to: CGPoint(x: width * 0.5, y: height * 0.85 + morphOffset),
            control: CGPoint(x: width * 0.85, y: height * 0.75)
        )

        // Lower curve (bottom-middle back to left)
        path.addQuadCurve(
            to: CGPoint(x: width * 0.1, y: height * 0.5),
            control: CGPoint(x: width * 0.15, y: height * 0.8 - morphOffset)
        )

        return path
    }
}

// MARK: - Preview

#Preview("Combination Bubble - 6 Layer") {
    ZStack {
        AppColors.background.ignoresSafeArea()
        CombinationBubble()
    }
}
