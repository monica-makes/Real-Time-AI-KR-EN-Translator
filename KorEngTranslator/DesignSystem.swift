import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Typography from Figma

struct AppTypography {
    // Headings - PP Editorial New
    static let h1 = Font.custom("PPEditorialNew-Bold", size: 34)  // line height 44, tracking 2.6%
    static let h2 = Font.custom("PPEditorialNew-Regular", size: 28)  // line height 39, tracking 2.4%
    static let h3 = Font.custom("PPEditorialNew-Regular", size: 20)  // line height 28, tracking 2.4%

    // Body - Geist
    static let b1 = Font.custom("Geist-Medium", size: 20)  // line height 24, tracking 2.4%
    static let b2 = Font.custom("Geist-Medium", size: 17)  // line height 22, tracking 2.2%
    static let b3 = Font.custom("Geist-Regular", size: 15)  // line height 21, tracking 2.2%

    // Korean Headings - Noto Serif KR
    static let h1Korean = Font.custom("NotoSerifKR-SemiBold", size: 32)  // line height 52, tracking 2.4%
    static let h2Korean = Font.custom("NotoSerifKR-SemiBold", size: 28)  // line height 38, tracking 2.4%
    static let h3Korean = Font.custom("NotoSerifKR-Medium", size: 20)    // line height 31, tracking 2.2%

    // Korean Body - Pretendard
    static let b1Korean = Font.custom("Pretendard-Medium", size: 20)    // line height 24, tracking 2.4%
    static let b2Korean = Font.custom("Pretendard-Medium", size: 17)    // line height 22, tracking 2.2%
    static let b3Korean = Font.custom("Pretendard-Regular", size: 14)   // line height 21, tracking 2.2%

    // Korean Subtext - Pretendard
    static let subtextKorean = Font.custom("Pretendard-Regular", size: 13)  // line height 19, tracking 2%

    // Code Entry - Geist
    static let codeEntry = Font.custom("Geist-SemiBold", size: 26)  // line height 28, tracking 2.4%

    // Emoji
    static let emojiSize = Font.custom("Geist-Medium", size: 48)  // line height 32, tracking 2.2%

    // Subtext - Geist
    static let subtext = Font.custom("Geist-Regular", size: 13)  // line height 19, tracking 2%

    /// Prints all available font names to the console for debugging
    static func printAllFontNames() {
        #if canImport(UIKit)
        for family in UIFont.familyNames.sorted() {
            print("Family: \(family)")
            for name in UIFont.fontNames(forFamilyName: family).sorted() {
                print("  - \(name)")
            }
        }
        #endif
    }
}

// MARK: - Colors

struct AppColors {
    // Text
    static let primaryText = Color(hex: "1A1814")
    static let secondaryText = Color(hex: "1A1814").opacity(0.7)

    // Backgrounds
    static let cardFill = Color(hex: "FEFEFE")
    static let secondaryCardFill = Color(hex: "FEFEFE").opacity(0.8)
    static let languageDisplayBox = Color(hex: "FEFEFE").opacity(0.65)
    static let background = Color(hex: "F2E6DA")

    // Icons
    static let primaryIcon = Color(hex: "121212")
    static let secondaryIcon = Color(hex: "121212").opacity(0.7)
    static let primaryIconOnMedia = Color(hex: "C86243")
    static let whiteIcon = Color(hex: "FEFEFE")

    // Brand
    static let claudeDeepOrange = Color(hex: "D55B35")
    static let claudeOrange = Color(hex: "E8714E")
    static let terracotta = Color(hex: "B85C38")

    // Persistent States
    static let errorRed = Color(hex: "D9645A")
    static let warningOrange = Color(hex: "E8923A")
    static let successGreen = Color(hex: "5A9E6F")
    static let lightGreen = Color(hex: "A7D1B4")
    static let lightRed = Color(hex: "E8918A")
    static let lightOrange = Color(hex: "F2B572")

    // Stroke
    static let glassStroke = Color(hex: "FFFFFF").opacity(0.05)

    // Buttons
    static let primaryButton = Color(hex: "1A1814")
    static let secondaryButton = Color(hex: "FEFEFE")
    static let tertiaryButton = Color(hex: "FEFEFE").opacity(0.15)
    static let buttonStroke = Color(hex: "1A1814").opacity(0.20)
    static let tertiaryIcon = Color(hex: "1A1814").opacity(0.25)

    // Gradient Orb
    static let gradientCoral = Color(hex: "FF7158")
    static let gradientAmber = Color(hex: "E8A84C")
    static let gradientPeach = Color(hex: "FFC068")
}

// MARK: - Spacing

struct AppSpacing {
    static let headerBody: CGFloat = 8
    static let aboveCards: CGFloat = 40
    static let betweenCards: CGFloat = 17
    static let welcomeContentStart: CGFloat = 192
    static let cardsFromTop: CGFloat = 302
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            Color.RGBColorSpace.displayP3,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Shadow Styles

struct AppShadows {
    /// Selected card shadow - compound effect for selection state
    static func selectedCard() -> some ViewModifier {
        SelectedCardShadow()
    }

    /// Code box shadow - subtle depth for input fields and code containers
    static func codeBox() -> some ViewModifier {
        CodeBoxShadow()
    }
}

struct SelectedCardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Drop shadow 1: warm glow
            .shadow(color: Color(hex: "B85C38").opacity(0.15), radius: 10, x: 0, y: 0)
            // Drop shadow 2: orange glow
            .shadow(color: Color(hex: "E8714E").opacity(0.50), radius: 16, x: 0, y: 0)
            // Drop shadow 3: subtle depth
            .shadow(color: Color(hex: "0C0C0D").opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

struct CodeBoxShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Drop shadow
            .shadow(color: Color(hex: "0C0C0D").opacity(0.03), radius: 1, x: 0, y: 1)
            // Inner shadow
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: "ACACAC"), lineWidth: 4)
                    .blur(radius: 2)
                    .offset(x: 4, y: 4)
                    .mask(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    colors: [Color.black, Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .opacity(0.05)
                    .allowsHitTesting(false)
            )
    }
}

// Usage extension
extension View {
    func selectedCardShadow() -> some View {
        modifier(AppShadows.selectedCard())
    }

    func codeBoxShadow() -> some View {
        modifier(AppShadows.codeBox())
    }
}

// MARK: - Glass Circle Button

struct GlassCircleButton: View {
    let icon: String
    var iconColor: Color = AppColors.primaryIcon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(Color.white.opacity(0.2))
                        )
                )
                .overlay(
                    // Top-left highlight arc
                    Circle()
                        .trim(from: 0.6, to: 0.9)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1.0)
                        .blur(radius: 0.75)
                        .rotationEffect(.degrees(-45))
                )
                .overlay(
                    // Bottom-right highlight arc
                    Circle()
                        .trim(from: 0.1, to: 0.4)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1.0)
                        .blur(radius: 0.75)
                        .rotationEffect(.degrees(-45))
                )
                .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
        }
    }
}

// MARK: - Mic Button

struct MicButton: View {
    @Binding var isSessionActive: Bool
    var onMicTapped: () -> Void
    var onMoreTapped: (() -> Void)?
    var onStopTapped: (() -> Void)?

    // State for delayed secondary button appearance
    @State private var showSecondaryButtons: Bool = false

    // Container width: 80 when idle, 252 when active
    private var containerWidth: CGFloat {
        isSessionActive ? 252 : 80
    }

    // Secondary button offset from center (72/2 + 24 + 52/2 = 36 + 24 + 26 = 86)
    private let secondaryButtonOffset: CGFloat = 86

    // Animation timing
    private let containerAnimationDuration: Double = 0.55

    var body: some View {
        ZStack {
            // Container - gradient pill background
            Capsule()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: "FEFEFE").opacity(0.25), location: 0.0),
                            .init(color: Color(hex: "FEFEFE").opacity(0.20), location: 0.75),
                            .init(color: Color(hex: "FEFEFE").opacity(0.15), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: containerWidth, height: 80)
                .overlay(
                    Capsule()
                        .stroke(Color(hex: "1A1814").opacity(0.40), lineWidth: 0.21)
                )
                .shadow(
                    color: Color(hex: "0C0C0D").opacity(0.021),
                    radius: 10,
                    x: 0,
                    y: 0
                )
                .animation(.easeInOut(duration: containerAnimationDuration), value: isSessionActive)

            // Left secondary button (More) - fades in after container animation completes
            if showSecondaryButtons {
                Button(action: { onMoreTapped?() }) {
                    SecondaryRoundButton(
                        iconName: "more",
                        iconSize: CGSize(width: 40, height: 40)
                    )
                }
                .buttonStyle(TapLightenButtonStyle())
                .offset(x: -secondaryButtonOffset)
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // Right secondary button (Stop) - fades in after container animation completes
            if showSecondaryButtons {
                Button(action: { onStopTapped?() }) {
                    SecondaryRoundButton(
                        iconName: "stop",
                        iconSize: CGSize(width: 36, height: 36)
                    )
                }
                .buttonStyle(TapLightenButtonStyle())
                .offset(x: secondaryButtonOffset)
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // Primary button (Mic/Pause)
            Button(action: onMicTapped) {
                ZStack {
                    // Circle background (72x72)
                    Circle()
                        .fill(AppColors.primaryButton)
                        .frame(width: 72, height: 72)
                        // Inside stroke
                        .overlay(
                            Circle()
                                .stroke(AppColors.buttonStroke, lineWidth: 0.25)
                        )
                        // Inner shadow (simulated)
                        .overlay(
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [Color.white.opacity(0.05), Color.clear],
                                        center: .topLeading,
                                        startRadius: 0,
                                        endRadius: 50
                                    )
                                )
                                .offset(x: 4, y: 4)
                                .blur(radius: 4)
                        )
                        // Primary button drop shadow
                        .shadow(
                            color: Color(hex: "0C0C0D").opacity(0.15),
                            radius: 10,
                            x: 0,
                            y: 1
                        )

                    // Icon (44x44) - Mic when idle, Pause when active
                    if isSessionActive {
                        Image("pause")
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 44, height: 44)
                            .foregroundColor(AppColors.whiteIcon)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 24))
                            .foregroundColor(AppColors.whiteIcon)
                            .frame(width: 44, height: 44)
                    }
                }
            }
            .buttonStyle(TapLightenButtonStyle())
        }
        .frame(width: 252, height: 80)  // Fixed frame to prevent layout jumps
        .animation(.easeInOut(duration: containerAnimationDuration), value: isSessionActive)
        .onChange(of: isSessionActive) { _, newValue in
            if newValue {
                // Delay showing secondary buttons until after container animation completes
                DispatchQueue.main.asyncAfter(deadline: .now() + containerAnimationDuration) {
                    withAnimation {
                        showSecondaryButtons = true
                    }
                }
            } else {
                // Hide secondary buttons immediately when deactivating
                withAnimation(.easeInOut(duration: 0.15)) {
                    showSecondaryButtons = false
                }
            }
        }
    }
}

// MARK: - Secondary Round Button

struct SecondaryRoundButton: View {
    let iconName: String
    var iconSize: CGSize = CGSize(width: 24, height: 24)

    var body: some View {
        ZStack {
            // Circle background (52x52)
            Circle()
                .fill(AppColors.secondaryButton)
                .frame(width: 52, height: 52)
                .overlay(
                    Circle()
                        .stroke(AppColors.buttonStroke, lineWidth: 0.2)
                )

            // Icon
            Image(iconName)
                .renderingMode(.template)
                .resizable()
                .frame(width: iconSize.width, height: iconSize.height)
                .foregroundColor(AppColors.primaryIcon)
        }
    }
}

// MARK: - Tap Lighten Button Style

struct TapLightenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}
