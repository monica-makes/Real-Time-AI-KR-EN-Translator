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

// MARK: - Main Content View with Mode Toggle
struct ContentView: View {
    @State private var isKoreanMode = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                FloatingOrb(isListening: isKoreanMode)

                Spacer().frame(height: 50)

                HStack(spacing: 20) {
                    Button(action: { isKoreanMode = true }) {
                        Text("Korean (Orange)")
                            .foregroundColor(isKoreanMode ? .orange : .gray)
                            .padding()
                            .background(isKoreanMode ? Color.orange.opacity(0.2) : Color.clear)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    Button(action: { isKoreanMode = false }) {
                        Text("English (Blue)")
                            .foregroundColor(!isKoreanMode ? .blue : .gray)
                            .padding()
                            .background(!isKoreanMode ? Color.blue.opacity(0.2) : Color.clear)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }

                Text("Press K for Korean, E for English, Q to quit")
                    .foregroundColor(.gray)
                    .font(.caption)
                    .padding(.top, 20)
            }
        }
        .frame(minWidth: 600, minHeight: 700)
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "k":
                    isKoreanMode = true
                case "e":
                    isKoreanMode = false
                case "q":
                    NSApplication.shared.terminate(nil)
                default:
                    break
                }
                return event
            }
        }
    }
}

// MARK: - App Entry Point
@main
struct OrbDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}
