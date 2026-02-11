import SwiftUI

// MARK: - Color Extension for Hex Support
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Basic Animated Orb
struct AnimatedOrb: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            // Outer glow layer
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.blue.opacity(0.3), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .blur(radius: 30)

            // Middle layer
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.purple.opacity(0.5), Color.blue.opacity(0.2)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .blur(radius: 20)
                .offset(x: animate ? 10 : -10, y: animate ? -10 : 10)

            // Core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.8), Color.purple.opacity(0.6)],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 80
                    )
                )
                .frame(width: 120, height: 120)
                .blur(radius: 10)
                .offset(x: animate ? -5 : 5, y: animate ? 5 : -5)
        }
        .onAppear {
            withAnimation(
                Animation.easeInOut(duration: 3)
                    .repeatForever(autoreverses: true)
            ) {
                animate = true
            }
        }
    }
}

// MARK: - Translation Orb (Orange/Blue Color Scheme)
struct TranslationOrb: View {
    @State private var animate = false
    let isListening: Bool // true = orange (Korean), false = blue (English)

    var primaryColor: Color {
        isListening ? Color(hex: "E8923A") : Color(hex: "5B9BD5")
    }

    var body: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [primaryColor.opacity(0.4), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 180
                    )
                )
                .frame(width: 350, height: 350)
                .blur(radius: 40)
                .scaleEffect(animate ? 1.1 : 0.9)

            // Inner core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [primaryColor.opacity(0.8), primaryColor.opacity(0.2)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .blur(radius: 25)
                .scaleEffect(animate ? 1.05 : 0.95)
        }
        .onAppear {
            withAnimation(
                Animation.easeInOut(duration: 2.5)
                    .repeatForever(autoreverses: true)
            ) {
                animate = true
            }
        }
    }
}

// MARK: - Audio Reactive Orb
struct AudioReactiveOrb: View {
    @Binding var audioLevel: CGFloat // 0.0 to 1.0 from your audio capture
    let primaryColor: Color

    var body: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [primaryColor.opacity(0.4), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 180
                    )
                )
                .frame(width: 350, height: 350)
                .blur(radius: 40 + (audioLevel * 20))
                .scaleEffect(1 + (audioLevel * 0.2))

            // Inner core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [primaryColor.opacity(0.8), primaryColor.opacity(0.2)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .blur(radius: 20 + (audioLevel * 10))
                .scaleEffect(1 + (audioLevel * 0.3))
        }
        .animation(.easeOut(duration: 0.1), value: audioLevel)
    }
}

// MARK: - Full Featured Floating Orb (with wobble effect)
struct FloatingOrb: View {
    @State private var animate = false
    @State private var pulse = false
    let isListening: Bool

    var primaryColor: Color {
        isListening ? Color(hex: "E8923A") : Color(hex: "5B9BD5")
    }

    var secondaryColor: Color {
        isListening ? Color(hex: "F4A460") : Color(hex: "87CEEB")
    }

    var body: some View {
        ZStack {
            // Ambient glow (largest, most diffuse)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [primaryColor.opacity(0.2), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .blur(radius: 50)
                .scaleEffect(pulse ? 1.15 : 0.95)

            // Outer glow layer
            Circle()
                .fill(
                    RadialGradient(
                        colors: [primaryColor.opacity(0.4), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .blur(radius: 35)
                .scaleEffect(animate ? 1.1 : 0.9)
                .offset(x: animate ? 8 : -8, y: animate ? -5 : 5)
                .rotationEffect(.degrees(animate ? 3 : -3))

            // Middle layer
            Circle()
                .fill(
                    RadialGradient(
                        colors: [secondaryColor.opacity(0.5), primaryColor.opacity(0.3)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .blur(radius: 25)
                .offset(x: animate ? -6 : 6, y: animate ? 4 : -4)
                .scaleEffect(animate ? 1.08 : 0.92)

            // Core (brightest center)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.9), primaryColor.opacity(0.7)],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 60
                    )
                )
                .frame(width: 100, height: 100)
                .blur(radius: 15)
                .offset(x: animate ? 4 : -4, y: animate ? -3 : 3)
                .scaleEffect(pulse ? 1.05 : 0.95)
        }
        .onAppear {
            // Main floating animation
            withAnimation(
                Animation.easeInOut(duration: 3)
                    .repeatForever(autoreverses: true)
            ) {
                animate = true
            }

            // Separate pulse animation (different timing)
            withAnimation(
                Animation.easeInOut(duration: 2)
                    .repeatForever(autoreverses: true)
            ) {
                pulse = true
            }
        }
    }
}

// MARK: - Demo View with Audio Simulation
struct AudioSimulationDemo: View {
    @State private var simulatedAudioLevel: CGFloat = 0.0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AudioReactiveOrb(
                audioLevel: $simulatedAudioLevel,
                primaryColor: Color(hex: "E8923A")
            )
        }
        .onAppear {
            // Simulate audio levels
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                withAnimation(.easeOut(duration: 0.05)) {
                    simulatedAudioLevel = CGFloat.random(in: 0...1)
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
}

// MARK: - Preview Provider
struct AnimatedOrb_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Basic Orb
            ZStack {
                Color.black.ignoresSafeArea()
                AnimatedOrb()
            }
            .previewDisplayName("Basic Orb")

            // Translation Orb - Korean (Orange)
            ZStack {
                Color.black.ignoresSafeArea()
                TranslationOrb(isListening: true)
            }
            .previewDisplayName("Korean Mode (Orange)")

            // Translation Orb - English (Blue)
            ZStack {
                Color.black.ignoresSafeArea()
                TranslationOrb(isListening: false)
            }
            .previewDisplayName("English Mode (Blue)")

            // Floating Orb with Wobble
            ZStack {
                Color.black.ignoresSafeArea()
                FloatingOrb(isListening: true)
            }
            .previewDisplayName("Floating Orb (Orange)")

            // Audio Reactive Demo
            AudioSimulationDemo()
                .previewDisplayName("Audio Reactive Demo")
        }
    }
}

// MARK: - App Entry Point (for standalone testing)
@main
struct OrbDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.black.ignoresSafeArea()
                FloatingOrb(isListening: true)
            }
        }
    }
}
