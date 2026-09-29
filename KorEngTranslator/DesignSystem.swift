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

    // Selected card stroke - linear (top-left → bottom-right), D55B35 at 100% → 90% → 80% opacity
    static let selectedStrokeGradient = Gradient(stops: [
        .init(color: claudeDeepOrange, location: 0),
        .init(color: claudeDeepOrange.opacity(0.9), location: 0.5),
        .init(color: claudeDeepOrange.opacity(0.8), location: 1)
    ])

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

// MARK: - Style

struct AppStyle {
    // true = native Liquid Glass cards, false = original gradient "glassmorphism" cards
    static let liquidGlassCards = false
    // Original cards only: strength of the Liquid Glass-style rim (bright top-left and bottom-right corners).
    // 0 = off, 1 = full strength
    static let glassEdgeStrength: Double = 0.6
    // Delay between selecting a card and moving to the next screen: the selected outline
    // draws in, then the closed outline holds briefly before the transition
    static let cardSelectHold: Double = 0.1
    static let cardSelectNavigationDelay: Double = SelectedCardBorder.drawDuration + cardSelectHold
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

// MARK: - Glass Edge

/// Liquid Glass-style rim for the glassmorphism cards: specular highlights on the top-left and
/// bottom-right corners, fading out along the edges in between. Strength is
/// AppStyle.glassEdgeStrength. Sits under the selected outline so it can't cover the 2pt line.
struct GlassEdgeRim: View {
    var cornerRadius: CGFloat = 8

    private static let rimGradient = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(1.0), location: 0.0),
            .init(color: Color.white.opacity(0.3), location: 0.25),
            .init(color: Color.white.opacity(0.05), location: 0.5),
            .init(color: Color.white.opacity(0.3), location: 0.75),
            .init(color: Color.white.opacity(0.9), location: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            // Soft inner bloom behind the rim
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Self.rimGradient, lineWidth: 4)
                .blur(radius: 3)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            // Crisp rim
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Self.rimGradient, lineWidth: 1.5)
        }
        .opacity(AppStyle.glassEdgeStrength)
        .allowsHitTesting(false)
    }
}

// MARK: - Selected Card Border

/// Geometry for the selected-card outline: the same (continuous-corner) RoundedRectangle the
/// solid stroke used, split into two routes that start at the top-left corner and meet at the
/// bottom-right corner - one along the top and down the right side, one down the left side and
/// along the bottom.
struct CardBorderRoutes {
    /// The finished, closed outline (renders identically to the original solid stroke)
    let closed: Path
    /// The same outline as one continuous open path that starts at the bottom-right corner and runs
    /// clockwise, so the top-left corner sits exactly halfway (0.5) and both routes are contiguous
    private let loop: Path

    init(rect: CGRect, cornerRadius: CGFloat) {
        let outline = RoundedRectangle(cornerRadius: cornerRadius).path(in: rect)
        // SwiftUI's rounded-rect path starts at the middle of the right edge and runs clockwise:
        // right → bottom-right corner (f) → bottom → left → top-left corner (0.5 + f) → top.
        // Re-start it at the bottom-right corner by joining [f, 1] and [0, f] into one subpath.
        let f = Self.bottomRightCornerFraction(of: outline, in: rect)
        var loop = outline.trimmedPath(from: f, to: 1)
        outline.trimmedPath(from: 0, to: f).forEach { element in
            switch element {
            case .move, .closeSubpath: break  // continue the same subpath instead of starting a new one
            case .line(let to): loop.addLine(to: to)
            case .quadCurve(let to, let control): loop.addQuadCurve(to: to, control: control)
            case .curve(let to, let control1, let control2): loop.addCurve(to: to, control1: control1, control2: control2)
            }
        }
        self.loop = loop
        var closed = loop
        closed.closeSubpath()
        self.closed = closed
    }

    /// Both routes between `start` and `end`, measured along each route
    /// (0 = top-left corner, 1 = bottom-right corner)
    func segment(from start: CGFloat, to end: CGFloat) -> Path {
        let a = min(max(start, 0), 1) * 0.5
        let b = min(max(end, 0), 1) * 0.5
        guard b > a else { return Path() }
        // From the corner itself it's one continuous stroke, so there's no seam at the top-left
        if a == 0 { return loop.trimmedPath(from: 0.5 - b, to: 0.5 + b) }
        var path = loop.trimmedPath(from: 0.5 - b, to: 0.5 - a)  // left side then bottom
        path.addPath(loop.trimmedPath(from: 0.5 + a, to: 0.5 + b))  // top then right side
        return path
    }

    /// Fraction along the outline where it crosses the bottom-right corner's 45° line
    private static func bottomRightCornerFraction(of outline: Path, in rect: CGRect) -> CGFloat {
        var lo: CGFloat = 0
        var hi: CGFloat = 0.25
        for _ in 0..<16 {
            let mid = (lo + hi) / 2
            guard let point = outline.trimmedPath(from: 0, to: mid).currentPoint else { break }
            if rect.maxX - point.x < rect.maxY - point.y { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}

/// Selected-card stroke (2pt, Figma gradient) that draws itself in from the top-left corner
/// with feathered tips, closing solid at the bottom-right corner.
/// Pins its own easeOut timing - otherwise it inherits the tap's
/// default spring, which has a long tail and never visibly closes before the screen changes.
struct SelectedCardBorder: View {
    let isSelected: Bool
    var cornerRadius: CGFloat = 8

    static let drawDuration: Double = 0.36

    var body: some View {
        FeatheredCardBorder(cornerRadius: cornerRadius, progress: isSelected ? 1 : 0)
            .animation(.easeOut(duration: Self.drawDuration), value: isSelected)
            .allowsHitTesting(false)
    }
}

/// Canvas-drawn outline. `progress` is animatable, so the feathered tips are redrawn every frame.
private struct FeatheredCardBorder: View, Animatable {
    var cornerRadius: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private let lineWidth: CGFloat = 2
    private let featherLength: CGFloat = 0.15  // share of each route that fades out behind the tip
    private let featherSteps = 24

    var body: some View {
        Canvas { context, size in
            // The canvas is padded by the line width so the centered 2pt stroke isn't clipped
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth, dy: lineWidth)
            let routes = CardBorderRoutes(rect: rect, cornerRadius: cornerRadius)
            let p = min(max(progress, 0), 1)
            // The feather shrinks away as the tips meet, so the finished outline is fully solid
            let feather = min(featherLength, p, 1 - p)
            let solidEnd = p - feather

            // Build the line's coverage in opaque black, then color it with the gradient (sourceIn),
            // so overlapping strokes can't stack up the gradient's own transparency
            context.drawLayer { layer in
                if solidEnd >= 1 {
                    layer.stroke(routes.closed, with: .color(.black), lineWidth: lineWidth)
                } else if solidEnd > 0 {
                    layer.stroke(routes.segment(from: 0, to: solidEnd), with: .color(.black), lineWidth: lineWidth)
                }
                if feather > 0 {
                    // Soft tip: translucent strokes that all start just inside the solid part and end
                    // at staggered points. Layer j is covered by layers j...n, and these opacities make
                    // the combined coverage fall off linearly to nothing at the tip, with no seams.
                    let overlap = min(solidEnd, 0.5 / (rect.width + rect.height))  // ~0.5pt
                    let n = featherSteps
                    for j in 1...n {
                        layer.opacity = j == n ? 0.5 / Double(n) : 1 / (Double(j) + 0.5)
                        let end = solidEnd + feather * CGFloat(j) / CGFloat(n)
                        layer.stroke(routes.segment(from: solidEnd - overlap, to: end), with: .color(.black), lineWidth: lineWidth)
                    }
                    layer.opacity = 1
                }
                layer.blendMode = .sourceIn
                layer.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        AppColors.selectedStrokeGradient,
                        startPoint: CGPoint(x: rect.minX, y: rect.minY),
                        endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
                    )
                )
            }
        }
        .padding(-lineWidth)
    }
}

// MARK: - Glass Circle Button

struct GlassCircleButton: View {
    let icon: String
    var iconColor: Color = AppColors.primaryIcon
    let action: () -> Void

    var body: some View {
        // System glass button style: iOS draws the glass itself, so this matches the native
        // toolbar/back buttons on whatever iOS version the phone runs
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .imageScale(.large)
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)  // the glass style adds 7pt a side → 44pt circle, like the native back button
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

// MARK: - Mic Button

struct MicButton: View {
    @Binding var isSessionActive: Bool
    var onMicTapped: () -> Void
    var onMoreTapped: (() -> Void)?
    var onStopTapped: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // How far each secondary button is out of the mic: 0 = tucked under it, 1 = at its spot.
    // Separate so one can trail the other; the pill stretches with More.
    @State private var moreProgress: CGFloat = 0
    @State private var stopProgress: CGFloat = 0

    // Secondary button offset from center (72/2 + 24 + 52/2 = 36 + 24 + 26 = 86)
    private let secondaryButtonOffset: CGFloat = 86

    // Out: 550ms, cubic-bezier(0.34, 1.56, 0.64, 1) - liquid-gooey's bouncy reveal, overshooting the spot
    private static let revealAnimation = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.55)
    // In: 420ms, cubic-bezier(0.5, 0, 0.3, 1) - no overshoot, so the buttons are sucked back into the mic
    private static let retractAnimation = Animation.timingCurve(0.5, 0, 0.3, 1, duration: 0.42)
    // The second button trails the first by 40ms: Stop comes out last and goes back in first
    private static let stagger: Double = 0.04

    var body: some View {
        ZStack {
            // Container - gradient pill background, 80 when idle, 252 when active
            MicButtonPill(progress: moreProgress)

            // Secondary buttons (More left, Stop right) - squeezed out of the mic like goo
            GooeySecondaryButton(
                progress: moreProgress,
                offset: -secondaryButtonOffset,
                iconName: "more",
                iconSize: CGSize(width: 40, height: 40),
                action: { onMoreTapped?() }
            )
            GooeySecondaryButton(
                progress: stopProgress,
                offset: secondaryButtonOffset,
                iconName: "stop",
                iconSize: CGSize(width: 36, height: 36),
                action: { onStopTapped?() }
            )

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
        .onAppear {
            // Screen rebuilt mid-session: start with the buttons already out
            if isSessionActive {
                moreProgress = 1
                stopProgress = 1
            }
        }
        .onChange(of: isSessionActive) { _, isActive in
            moveSecondaryButtons(out: isActive)
        }
    }

    private func moveSecondaryButtons(out: Bool) {
        let target: CGFloat = out ? 1 : 0

        if reduceMotion {
            // Snap, without inheriting the animation that flipped isSessionActive
            withAnimation(nil) {
                moreProgress = target
                stopProgress = target
            }
            return
        }

        // More leads on the way out and Stop on the way back in, so the pill
        // (which follows More) always covers both buttons
        let animation = out ? Self.revealAnimation : Self.retractAnimation
        withAnimation(animation) {
            if out { moreProgress = target } else { stopProgress = target }
        }
        withAnimation(animation.delay(Self.stagger)) {
            if out { stopProgress = target } else { moreProgress = target }
        }
    }
}

// MARK: - Mic Button Pill

/// The mic button's translucent pill: an 80pt circle behind the mic at rest, 252pt wide with the
/// buttons out. `progress` is animatable and follows the More button, overshoot included.
private struct MicButtonPill: View, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
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
            // Never narrower than its resting circle
            .frame(width: 80 + 172 * max(progress, 0), height: 80)
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
    }
}

// MARK: - Gooey Secondary Button

/// A mic-button secondary button that comes out of the mic like goo (liquid-gooey's Morph effect):
/// the button's disc and a disc hidden under the mic are blurred together and cut back to a hard
/// edge in the button's white, so a strand stretches from under the mic, necks and snaps as the
/// button leaves, and forms again as it's pulled back in. The crisp button rides on top.
/// `progress` is animatable: 0 = hidden under the mic, 1 = at its spot.
private struct GooeySecondaryButton: View, Animatable {
    var progress: CGFloat
    let offset: CGFloat  // resting x offset from the mic's center, negative = left
    let iconName: String
    let iconSize: CGSize
    let action: () -> Void

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    // Goo, in points. Discs closer than about gooBlur bridge; the edge sits where the blurred
    // silhouette is 5/12 opaque, liquid-gooey's default (contrast 18).
    private static let gooBlur: CGFloat = 10
    private static let gooThreshold: Double = 5.0 / 12.0
    // Just inside the mic's 36pt radius, so the strand seems to come from beneath it
    private static let sourceRadius: CGFloat = 34
    // Blurred and cut back, this lands on the button's own 26pt edge
    private static let blobRadius: CGFloat = 25.5

    var body: some View {
        let x = offset * progress
        // Space between the two discs (negative while they overlap); the strand snaps near gooBlur
        let gap = abs(x) - Self.sourceRadius - Self.blobRadius

        ZStack {
            Canvas { context, size in
                // Nothing to draw while tucked in or once the strand has snapped - the hidden disc
                // would otherwise show through the mic while it's pressed and dimmed
                guard progress > 0.001, gap < 2 * Self.gooBlur else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                // Filters run last-added first: melt the two discs together, cut the result back to a
                // hard edge in the button's white, then soften that edge by half a point
                context.addFilter(.blur(radius: 0.5))
                context.addFilter(.alphaThreshold(min: Self.gooThreshold, color: AppColors.secondaryButton))
                context.addFilter(.blur(radius: Self.gooBlur))
                context.drawLayer { layer in
                    layer.fill(Self.disc(at: center, radius: Self.sourceRadius), with: .color(.black))
                    layer.fill(Self.disc(at: CGPoint(x: center.x + x, y: center.y), radius: Self.blobRadius), with: .color(.black))
                }
            }
            .frame(width: 300, height: 128)  // the 252 x 80 control plus room for the blur
            .allowsHitTesting(false)

            Button(action: action) {
                SecondaryRoundButton(
                    iconName: iconName,
                    iconSize: iconSize,
                    // The outline would cut across the strand, so it fades in as the strand snaps
                    strokeOpacity: Double(min(max((gap - 8) / 8, 0), 1))
                )
            }
            .buttonStyle(TapLightenButtonStyle())
            .offset(x: x)
            // Hidden when tucked in, since the mic dims while pressed
            .opacity(progress > 0.001 ? 1 : 0)
            .allowsHitTesting(progress > 0.5)
            .accessibilityHidden(progress < 0.5)
        }
    }

    private static func disc(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

// MARK: - Secondary Round Button

struct SecondaryRoundButton: View {
    let iconName: String
    var iconSize: CGSize = CGSize(width: 24, height: 24)
    var strokeOpacity: Double = 1

    var body: some View {
        ZStack {
            // Circle background (52x52)
            Circle()
                .fill(AppColors.secondaryButton)
                .frame(width: 52, height: 52)
                .overlay(
                    Circle()
                        .stroke(AppColors.buttonStroke, lineWidth: 0.2)
                        .opacity(strokeOpacity)
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
