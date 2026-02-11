import SwiftUI

// MARK: - Organic Only Bubble (Style 1) - ACTIVE PROTOTYPE
// Simulates the "speaking" state with constant animation for prototyping
// No audio binding needed - just shows how it feels when active

struct OrganicOnlyBubble: View {

    // MARK: - Colors (from DesignSystem)

    private let deepCoral = AppColors.gradientCoral      // #FF7158
    private let goldenAmber = AppColors.gradientAmber    // #E8A84C
    private let warmPeach = AppColors.gradientPeach      // #FFC068

    // MARK: - Animation States

    @State private var breatheScale: CGFloat = 1.0
    @State private var rotationAngle: Double = 0
    @State private var morphOffset1: CGSize = .zero
    @State private var morphOffset2: CGSize = .zero
    @State private var morphOffset3: CGSize = .zero
    @State private var morphOffset4: CGSize = .zero
    @State private var pulseScale: CGFloat = 1.0

    // MARK: - Constants

    private let baseSize: CGFloat = 266        // 5% smaller bubble
    private var containerSize: CGFloat { baseSize * 1.6 }  // larger container for breathing room

    // MARK: - Computed Properties

    private var currentScale: CGFloat {
        breatheScale * pulseScale
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Layer 1: Deep Coral blob (left-ish position)
            coralBlobLayer

            // Layer 2: Warm Peach blob (right-ish position)
            peachBlobLayer

            // Layer 3: Golden Amber blob (center blend)
            amberBlobLayer

            // Layer 4: Core highlight for depth
            coreHighlightLayer
        }
        .frame(width: containerSize, height: containerSize)
        .scaleEffect(currentScale)
        .rotationEffect(.degrees(rotationAngle))
        .drawingGroup()
        .onAppear {
            startActiveAnimations()
        }
    }

    // MARK: - Blob Layers

    // Deep Coral - #FF7158 - positioned left
    private var coralBlobLayer: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        deepCoral.opacity(0.85),
                        deepCoral.opacity(0.55),
                        deepCoral.opacity(0.15)
                    ],
                    center: .center,
                    startRadius: 15,
                    endRadius: baseSize / 2
                )
            )
            .frame(width: baseSize * 1.15, height: baseSize * 0.95)
            .offset(x: -baseSize * 0.12)
            .offset(morphOffset1)
            .blur(radius: 18)
    }

    // Warm Peach - #FFC068 - positioned right
    private var peachBlobLayer: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        warmPeach.opacity(0.9),
                        warmPeach.opacity(0.6),
                        warmPeach.opacity(0.15)
                    ],
                    center: .center,
                    startRadius: 15,
                    endRadius: baseSize / 2
                )
            )
            .frame(width: baseSize * 0.95, height: baseSize * 1.15)
            .offset(x: baseSize * 0.12)
            .offset(morphOffset2)
            .blur(radius: 16)
    }

    // Golden Amber - #E8A84C - center blend
    private var amberBlobLayer: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        goldenAmber.opacity(0.75),
                        goldenAmber.opacity(0.4),
                        goldenAmber.opacity(0.1)
                    ],
                    center: .center,
                    startRadius: 10,
                    endRadius: baseSize / 2.2
                )
            )
            .frame(width: baseSize * 0.9, height: baseSize)
            .offset(morphOffset3)
            .blur(radius: 15)
    }

    // Core highlight for inner depth
    private var coreHighlightLayer: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        warmPeach.opacity(0.6),
                        goldenAmber.opacity(0.35),
                        deepCoral.opacity(0.15),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.55, y: 0.45),
                    startRadius: 5,
                    endRadius: baseSize / 2.8
                )
            )
            .frame(width: baseSize * 0.75, height: baseSize * 0.75)
            .offset(morphOffset4)
            .blur(radius: 12)
    }

    // MARK: - Active State Animations

    private func startActiveAnimations() {
        // 1. Breathing scale - active feel
        withAnimation(
            .easeInOut(duration: 2.0)
            .repeatForever(autoreverses: true)
        ) {
            breatheScale = 1.08
        }

        // 2. Rapid pulse overlay - simulates audio reactivity
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = 1.06
        }

        // 3. Rotation - more noticeable when active
        withAnimation(
            .easeInOut(duration: 4)
            .repeatForever(autoreverses: true)
        ) {
            rotationAngle = 5
        }

        // 4. Morph offsets - faster, larger movement for active state

        // Coral blob movement
        withAnimation(
            .easeInOut(duration: 1.8)
            .repeatForever(autoreverses: true)
        ) {
            morphOffset1 = CGSize(width: 28, height: -22)
        }

        // Peach blob movement
        withAnimation(
            .easeInOut(duration: 2.0)
            .repeatForever(autoreverses: true)
        ) {
            morphOffset2 = CGSize(width: -24, height: 26)
        }

        // Amber blob movement
        withAnimation(
            .easeInOut(duration: 2.3)
            .repeatForever(autoreverses: true)
        ) {
            morphOffset3 = CGSize(width: 18, height: 20)
        }

        // Core highlight movement
        withAnimation(
            .easeInOut(duration: 2.6)
            .repeatForever(autoreverses: true)
        ) {
            morphOffset4 = CGSize(width: -14, height: -16)
        }
    }
}

// MARK: - Preview

#Preview("Organic Bubble - Active") {
    ZStack {
        AppColors.background.ignoresSafeArea()
        OrganicOnlyBubble()
    }
}
