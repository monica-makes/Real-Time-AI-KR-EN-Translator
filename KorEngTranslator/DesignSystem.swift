import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Typography from Figma

/// Which typography the app renders with. Classic is the shipping look; Söhne is a debug-only
/// trial and the Debug-build default (switch in Debug Controls > TYPOGRAPHY, or launch with
/// `-debugTypographyStyle classic`). Release builds always use Classic.
enum TypographyStyle: String, CaseIterable {
    case classic
    case sohne

    static let storageKey = "debugTypographyStyle"
    /// What Debug builds use until TYPOGRAPHY is switched
    static let debugDefault: TypographyStyle = .sohne

    static var current: TypographyStyle {
        #if DEBUG
        return TypographyStyle(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? debugDefault
        #else
        return .classic
        #endif
    }

    var label: String {
        switch self {
        case .classic: return "Classic"
        case .sohne: return "Söhne"
        }
    }
}

struct AppTypography {
    private static var isSohne: Bool { TypographyStyle.current == .sohne }

    // Headings
    static var h1: Font { isSohne ? Sohne.h1 : Classic.h1 }  // line height 44, tracking 2.6%
    static var h2: Font { isSohne ? Sohne.h2 : Classic.h2 }  // line height 39, tracking 2.4%
    static var h3: Font { isSohne ? Sohne.h3 : Classic.h3 }  // line height 28, tracking 2.4%

    // Body
    static var b1: Font { isSohne ? Sohne.b1 : Classic.b1 }  // line height 24, tracking 2.4%
    static var b2: Font { isSohne ? Sohne.b2 : Classic.b2 }  // line height 22, tracking 2.2%
    static var b3: Font { isSohne ? Sohne.b3 : Classic.b3 }  // line height 21, tracking 2.2%

    // Korean Headings
    static var h1Korean: Font { isSohne ? Sohne.h1Korean : Classic.h1Korean }  // line height 52, tracking 2.4%
    static var h2Korean: Font { isSohne ? Sohne.h2Korean : Classic.h2Korean }  // line height 38, tracking 2.4%
    static var h3Korean: Font { isSohne ? Sohne.h3Korean : Classic.h3Korean }  // line height 31, tracking 2.2%

    // Korean Body
    static var b1Korean: Font { isSohne ? Sohne.b1Korean : Classic.b1Korean }  // line height 24, tracking 2.4%
    static var b2Korean: Font { isSohne ? Sohne.b2Korean : Classic.b2Korean }  // line height 22, tracking 2.2%
    static var b3Korean: Font { isSohne ? Sohne.b3Korean : Classic.b3Korean }  // line height 21, tracking 2.2%

    // Korean Subtext
    static var subtextKorean: Font { isSohne ? Sohne.subtextKorean : Classic.subtextKorean }  // line height 19, tracking 2%

    // Code Entry
    static var codeEntry: Font { isSohne ? Sohne.codeEntry : Classic.codeEntry }  // line height 28, tracking 2.4%

    // Emoji
    static var emojiSize: Font { isSohne ? Sohne.emojiSize : Classic.emojiSize }  // line height 32, tracking 2.2%

    // Subtext
    static var subtext: Font { isSohne ? Sohne.subtext : Classic.subtext }  // line height 19, tracking 2%

    // Language card name/abbreviation and Get Started card subtitle: SF in Classic (as originally
    // built), the matching Söhne body styles in Söhne
    static var cardName: Font { isSohne ? Sohne.b1 : .system(size: 20, weight: .medium) }
    static var cardCaption: Font { isSohne ? Sohne.b3 : .system(size: 15, weight: .regular) }

    // Mic menu cards (voice, honorifics): Figma's 16pt label, line height 20
    static var optionLabel: Font { isSohne ? Sohne.optionLabel : Classic.optionLabel }
    static var optionLabelKorean: Font { isSohne ? Sohne.optionLabelKorean : Classic.optionLabelKorean }

    /// PP Editorial New headings, Geist body, Noto Serif KR Korean headings, Pretendard Korean body
    private enum Classic {
        static let h1 = Font.custom("PPEditorialNew-Bold", size: 34)
        static let h2 = Font.custom("PPEditorialNew-Regular", size: 28)
        static let h3 = Font.custom("PPEditorialNew-Regular", size: 20)
        static let b1 = Font.custom("Geist-Medium", size: 20)
        static let b2 = Font.custom("Geist-Medium", size: 17)
        static let b3 = Font.custom("Geist-Regular", size: 15)
        static let h1Korean = Font.custom("NotoSerifKR-SemiBold", size: 32)
        static let h2Korean = Font.custom("NotoSerifKR-SemiBold", size: 28)
        static let h3Korean = Font.custom("NotoSerifKR-Medium", size: 20)
        static let b1Korean = Font.custom("Pretendard-Medium", size: 20)
        static let b2Korean = Font.custom("Pretendard-Medium", size: 17)
        static let b3Korean = Font.custom("Pretendard-Regular", size: 14)
        static let subtextKorean = Font.custom("Pretendard-Regular", size: 13)
        static let codeEntry = Font.custom("Geist-SemiBold", size: 26)
        static let emojiSize = Font.custom("Geist-Medium", size: 48)
        static let subtext = Font.custom("Geist-Regular", size: 13)
        static let optionLabel = Font.custom("Geist-Regular", size: 16)
        static let optionLabelKorean = Font.custom("Pretendard-Regular", size: 16)
    }

    /// English is Söhne with PP Neue Montreal punctuation; Korean is Pretendard with Favorit punctuation.
    /// Söhne (the website's trial cut) has only letters and digits; anything else it lacks falls
    /// back to Geist, and Korean inside an English style falls through to Pretendard.
    /// The Söhne and Pretendard files carry the line metrics of the Classic fonts they replace
    /// (body: Geist, headings: PP Editorial, Korean headings: Noto Serif KR), so every line box
    /// and everything laid out around it stays put. Regenerate with build_fonts.py in Fonts/.
    /// The Söhne, Favorit and PP Neue Montreal files live in the git-ignored Fonts/Local folder (they
    /// can't be redistributed); without them this style renders in fallback fonts.
    private enum Sohne {
        // Headings - Söhne Kräftig
        static let h1 = english(.medium, size: 34, heading: true)
        static let h2 = english(.medium, size: 28, heading: true)
        static let h3 = english(.medium, size: 20, heading: true)

        // Body - Söhne Buch, small body Leicht (website-style)
        static let b1 = english(.regular, size: 20)
        static let b2 = english(.regular, size: 17)
        static let b3 = english(.light, size: 15)

        // Korean - Pretendard
        static let h1Korean = korean(.semibold, size: 32, heading: true)
        static let h2Korean = korean(.semibold, size: 28, heading: true)
        static let h3Korean = korean(.medium, size: 20, heading: true)
        static let b1Korean = korean(.medium, size: 20)
        static let b2Korean = korean(.medium, size: 17)
        static let b3Korean = korean(.regular, size: 14)
        static let subtextKorean = korean(.regular, size: 13)

        static let codeEntry = english(.semibold, size: 26)
        static let emojiSize = english(.medium, size: 48)
        static let subtext = english(.light, size: 13)
        static let optionLabel = english(.regular, size: 16)
        static let optionLabelKorean = korean(.regular, size: 16)

        enum Weight {
            case light, regular, medium, semibold

            var names: (sohne: String, pretendard: String, neue: String, favorit: String, geist: String) {
                switch self {
                case .light: return ("Leicht", "Regular", "NeueMontrealPunct-Light", "FavoritPunct-Light", "Geist-Regular")
                case .regular: return ("Buch", "Regular", "NeueMontrealPunct-Regular", "FavoritPunct-Regular", "Geist-Regular")
                case .medium: return ("Kraftig", "Medium", "NeueMontrealPunct-Medium", "FavoritPunct-Medium", "Geist-Medium")
                case .semibold: return ("Halbfett", "SemiBold", "NeueMontrealPunct-Semibold", "FavoritPunct-Bold", "Geist-SemiBold")
                }
            }
        }

        /// Söhne, with PP Neue Montreal for punctuation, Geist for anything else Söhne lacks, then Pretendard for Korean.
        /// `heading` picks the cut with PP Editorial's line box instead of Geist's.
        static func english(_ weight: Weight, size: CGFloat, heading: Bool = false) -> Font {
            let n = weight.names
            let primary = (heading ? "TestSohneHeading-" : "TestSohne-") + n.sohne
            return cascade(primary, size: size, fallbacks: [n.neue, n.geist, "PretendardText-" + n.pretendard])
        }

        /// Pretendard, with Favorit for punctuation. `heading` picks the cut with Noto Serif KR's line box.
        static func korean(_ weight: Weight, size: CGFloat, heading: Bool = false) -> Font {
            let n = weight.names
            let primary = (heading ? "PretendardHeading-" : "PretendardText-") + n.pretendard
            return cascade(primary, size: size, fallbacks: [n.favorit, n.geist])
        }

        /// Sized once at first use for the current Dynamic Type setting, like Font.custom's default scaling.
        static func cascade(_ primary: String, size: CGFloat, fallbacks: [String]) -> Font {
            #if canImport(UIKit)
            let scaled = UIFontMetrics.default.scaledValue(for: size)
            let descriptor = UIFontDescriptor(name: primary, size: scaled).addingAttributes([
                .cascadeList: fallbacks.map { UIFontDescriptor(name: $0, size: scaled) }
            ])
            return Font(UIFont(descriptor: descriptor, size: scaled) as CTFont)
            #else
            return Font.custom(primary, size: size)
            #endif
        }
    }

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
    /// Corner radius of every card and box. The language cards set it (Card radius in the home
    /// screen's Debug layout panel) and everything else follows.
    static var cornerRadius: CGFloat { HomeLayoutTuning.shared.cardRadius }
    /// The smaller boxes keep 12pt corners: the code entry boxes, the share-code box and the live
    /// screen's language boxes
    static let smallCornerRadius: CGFloat = 12
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
                RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
                    .stroke(Color(hex: "ACACAC"), lineWidth: 4)
                    .blur(radius: 2)
                    .offset(x: 4, y: 4)
                    .mask(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
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
    var cornerRadius: CGFloat = AppStyle.cornerRadius

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

// MARK: - Glass Card Background

/// The glassmorphism surface the language cards introduced: a white gradient over a pink / peach
/// tint, the glass rim, a hairline gradient outline, a soft shadow and an inner glow. Boxes that
/// should look like those cards put it behind their content.
struct GlassCardBackground: View {
    var cornerRadius: CGFloat = AppStyle.cornerRadius

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.9),
                            Color.white.opacity(0.7),
                            Color.white.opacity(0.4)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 0.98, green: 0.43, blue: 0.85).opacity(0.4),
                                    Color(red: 1.0, green: 0.71, blue: 0.45).opacity(0.3)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(GlassEdgeRim(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.white.opacity(0.6), Color.white.opacity(0.2)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)

            // Inner glow
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [Color(red: 0.45, green: 0.55, blue: 0.96).opacity(0.3), Color.clear]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .blur(radius: 4)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
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
    var cornerRadius: CGFloat = AppStyle.cornerRadius

    static let drawDuration: Double = 0.4

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
    /// Started, but the mic is paused: Play shows, and More and Stop stay out
    var isPaused: Bool = false
    /// The voice & honorifics menu is open: More turns into an X
    var isMenuOpen: Bool = false
    /// Points the control is raised to uncover the menu cards; it moves with a liquid bend
    var lift: CGFloat = 0
    var onMicTapped: () -> Void
    var onMoreTapped: (() -> Void)?
    var onStopTapped: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // More and Stop move on their own clock, frame by frame, so each one's strand can stretch, neck
    // and snap on time behind it. The pill stretches with More.
    @State private var gooMotion = GooMotion()
    @State private var isGooing = false
    @State private var gooMoveID = 0

    // The lift rides the animation that changed it; a clock keeps the pill's bend going until it settles
    @State private var liftBend = LiquidLift()
    @State private var isLifting = false
    @State private var liftMoveID = 0

    // Secondary button offset from center (72/2 + 24 + 52/2 = 36 + 24 + 26 = 86)
    private let secondaryButtonOffset: CGFloat = 86

    private enum PrimaryIcon { case mic, mute, play }

    private var primaryIcon: PrimaryIcon {
        #if DEBUG
        if LiveRecordingDemo.keepsMicIcon { return .mic }  // the live screen's recording demo
        #endif
        if isSessionActive { return .mute }
        return isPaused ? .play : .mic
    }

    /// More and Stop are out while the mic listens and while it's paused
    private var showsSecondaryButtons: Bool { isSessionActive || isPaused }

    var body: some View {
        TimelineView(.animation(paused: !isLifting && !isGooing)) { timeline in
            LiftedMicControl(lift: lift, tick: timeline.date, bend: liftBend, bends: !reduceMotion) { bend in
                control(bend: bend, goo: gooMotion.frames(at: .now))
            }
        }
        .frame(width: 252, height: 80)  // Fixed frame to prevent layout jumps
        .onAppear {
            // Screen rebuilt mid-session: start with the buttons already out
            if showsSecondaryButtons {
                gooMotion.move(out: true, animated: false)
            }
        }
        .onChange(of: showsSecondaryButtons) { _, out in
            moveSecondaryButtons(out: out)
        }
        .onChange(of: lift) {
            keepBendClockRunning()
        }
    }

    private func control(bend: CGFloat, goo: (more: GooFrame, stop: GooFrame)) -> some View {
        ZStack {
            // Container - glass pill, 80 when idle, 252 when active
            MicButtonPill(progress: goo.more.progress, bend: bend)
                // Driven frame by frame; an animation around isSessionActive mustn't smear it
                .transaction { $0.animation = nil }

            // Secondary buttons (More left, Stop right) - squeezed out of the mic like goo
            GooeySecondaryButton(
                goo: goo.more,
                offset: -secondaryButtonOffset,
                iconName: "ellipsis",
                iconSize: 22,
                // More turns into an X while the menu is open
                alternateIcon: (name: "xmark", size: 18),
                showsAlternate: isMenuOpen,
                accessibilityLabel: isMenuOpen ? "Close voice and honorific settings" : "Voice and honorific settings",
                action: { onMoreTapped?() }
            )
            GooeySecondaryButton(
                goo: goo.stop,
                offset: secondaryButtonOffset,
                iconName: "stop.fill",
                iconSize: 18,
                accessibilityLabel: "End session",
                action: { onStopTapped?() }
            )

            // Primary button (Mic/Pause/Play)
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

                    // Icon (44x44) - Mic before the first start and after Stop, a coral slashed mic
                    // (tap to pause) while listening, Play while paused; each change is an icon swap
                    ForEach([PrimaryIcon.mic, .mute, .play], id: \.self) { icon in
                        primaryIconImage(icon)
                            .iconSwapShown(icon == primaryIcon)
                    }
                }
                .animation(reduceMotion ? nil : IconSwap.animation, value: primaryIcon)
            }
            // iOS's press for an interactive glass circle: grows 16pt, 40% white, bounces back
            .buttonStyle(IOSPressStyle(.control, in: Circle(), highlight: 0.4))
            #if DEBUG
            .recordingPressID("mic")  // the live recording demo holds it down
            #endif
            .accessibilityLabel(primaryIcon == .mute ? "Pause" : primaryIcon == .play ? "Resume" : "Start")
        }
    }

    @ViewBuilder
    private func primaryIconImage(_ icon: PrimaryIcon) -> some View {
        switch icon {
        case .mic:
            Image(systemName: "mic.fill")
                .font(.system(size: 24))
                .foregroundColor(AppColors.whiteIcon)
                .frame(width: 44, height: 44)
        case .mute:
            // SF Symbols, at the resting mic's size, so every state reads the same size
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 24))
                .foregroundColor(Color(hex: "FC757B"))
                .frame(width: 44, height: 44)
        case .play:
            Image(systemName: "play.fill")
                .font(.system(size: 24))
                .foregroundColor(AppColors.whiteIcon)
                .frame(width: 44, height: 44)
        }
    }

    private func moveSecondaryButtons(out: Bool) {
        // Reduce Motion snaps them, with no strand
        gooMotion.move(out: out, animated: !reduceMotion)

        // Run the clock until both buttons, and both strands, have settled
        gooMoveID += 1
        let moveID = gooMoveID
        isGooing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + GooMotion.settleTime) {
            if gooMoveID == moveID { isGooing = false }
        }
    }

    /// Runs the clock past the lift's own animation, until the spring's wobble and the bend have settled
    private func keepBendClockRunning() {
        liftMoveID += 1
        let moveID = liftMoveID
        isLifting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + LiquidLift.settleTime) {
            if liftMoveID == moveID { isLifting = false }
        }
    }
}

/// The mic control raised by `lift`, which is animatable so the lift rides the same animation as the
/// menu cards, with its pill bent by `bend` (see LiquidLift). `tick` only forces a redraw while the bend
/// settles after the lift's animation has ended.
private struct LiftedMicControl<Content: View>: View, Animatable {
    var lift: CGFloat
    let tick: Date
    let bend: LiquidLift
    let bends: Bool
    @ViewBuilder let content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { lift }
        set { lift = newValue }
    }

    var body: some View {
        content(bend.follow(lift: lift, at: .now, height: 80, enabled: bends))
            .offset(y: -lift)
    }
}

// MARK: - Liquid Lift

/// The pill's bow while the mic control lifts to uncover the menu cards: liquid-gooey's Bend at half
/// its default strength (`vertical: 0.3` instead of 0.6). As in the library, the pill's outline rides a
/// stiff spring behind the control (Bend's springiness 1: k = 380·√10 ≈ 1202, c = 18·10^¼ ≈ 32, so it
/// wobbles a little as it lands), and its top and bottom edges bow by that spring's velocity × 0.05,
/// capped at half the pill's height and eased in at 9/s. Rising, the middle of the pill leads and its
/// ends lag; the buttons stay straight.
private final class LiquidLift {
    /// Covers the lift's 400ms animation plus the spring's wobble and the bend dying out
    static let settleTime: TimeInterval = 1.0

    private static let stiffness = 380 * pow(10, 0.5)
    private static let damping = 18 * pow(10, 0.25)
    private static let bendPerVelocity = 0.05
    private static let bendStrength = 0.3
    private static let bendEaseRate = 9.0

    // The outline's spring in the control's y (down = positive), and its current bow
    private var y: Double?
    private var velocity: Double = 0
    private var bend: Double = 0
    private var lastDate: Date?

    /// Steps the outline toward the control's current `lift` (points up) and returns how far the pill's
    /// long edges bow (points, negative = up)
    func follow(lift: CGFloat, at date: Date, height: CGFloat, enabled: Bool) -> CGFloat {
        let target = -Double(lift)
        let dt = min(max(date.timeIntervalSince(lastDate ?? date), 0), 0.1)
        lastDate = date
        guard enabled, var y else {
            y = target
            velocity = 0
            bend = 0
            return 0
        }

        // Substepped at 1/60s or less like the library, so a long frame can't blow the spring up
        let steps = max(1, Int((dt * 60).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            velocity += (Self.stiffness * (target - y) - Self.damping * velocity) * h
            y += velocity * h
        }
        self.y = y
        let cap = Double(height) / 2
        let bow = min(max(velocity * Self.bendPerVelocity, -cap), cap) * Self.bendStrength
        bend += (bow - bend) * min(1, dt * Self.bendEaseRate)
        return CGFloat(bend)
    }
}

// MARK: - Mic Button Pill

/// The mic button's glass pill: an 80pt circle behind the mic at rest, 252pt wide with the buttons
/// out. `progress` is animatable and follows the More button, overshoot included; `bend` bows its
/// long edges while the control lifts.
private struct MicButtonPill: View, Animatable {
    var progress: CGFloat
    var bend: CGFloat = 0

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Color.clear
            // Never narrower than its resting circle
            .frame(width: 80 + 172 * max(progress, 0), height: 80)
            .glassEffect(.regular, in: BentCapsule(bend: bend))
    }
}

// MARK: - Bent Capsule

/// A capsule whose top and bottom edges bow by `bend` points at the middle (negative = up), drawn the
/// way liquid-gooey's Bend draws a moving pill: each long edge is a quadratic whose control point sits
/// 2 × bend off the edge, between quarter-circle caps.
struct BentCapsule: Shape {
    var bend: CGFloat

    var animatableData: CGFloat {
        get { bend }
        set { bend = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        // A circle has no long edges to bow
        guard abs(bend) > 0.05, rect.width - 2 * r > 1 else { return Capsule().path(in: rect) }

        let k = 0.5523 * r  // quarter circle as a cubic
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.minY),
                          control: CGPoint(x: rect.midX, y: rect.minY + 2 * bend))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                      control1: CGPoint(x: rect.maxX - r + k, y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.minY + r - k))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.maxY - r + k),
                      control2: CGPoint(x: rect.maxX - r + k, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: rect.maxY + 2 * bend))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                      control1: CGPoint(x: rect.minX + r - k, y: rect.maxY),
                      control2: CGPoint(x: rect.minX, y: rect.maxY - r + k))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + r - k),
                      control2: CGPoint(x: rect.minX + r - k, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Icon Swap

/// Transitions.dev "Icon swap": the new icon fades in while the old one fades out, each blurring by
/// 2pt and scaling to/from 25% over 250ms ease-in-out. Stack every state's icon, mark each with
/// `.iconSwapShown(isCurrent)`, and animate the stack with `.animation(IconSwap.animation, value:)`.
/// The icons stay mounted, so a fading icon keeps moving with its button.
enum IconSwap {
    static let animation = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.25)  // CSS ease-in-out
}

extension View {
    func iconSwapShown(_ isShown: Bool) -> some View {
        opacity(isShown ? 1 : 0)
            .blur(radius: isShown ? 0 : 2)
            .scaleEffect(isShown ? 1 : 0.25)
            .accessibilityHidden(!isShown)
    }
}

// MARK: - Goo Motion

/// One frame of a secondary button: how far out of the mic it is (0 = tucked under it, 1 = at its
/// spot, past 1 while it overshoots) and where its strand is in its life
struct GooFrame {
    var progress: CGFloat
    var strand: GooStrand
}

/// Moves More and Stop in and out of the mic frame by frame, on liquid-gooey's timing, so each
/// button's strand runs on the same clock as the button:
/// out 550ms cubic-bezier(0.34, 1.56, 0.64, 1), overshooting the spot, Stop 40ms behind More;
/// in 420ms cubic-bezier(0.5, 0, 0.3, 1), no overshoot, More 40ms behind Stop - so the pill,
/// which follows More, always covers both buttons.
final class GooMotion {
    static let revealDuration: TimeInterval = 0.55
    static let retractDuration: TimeInterval = 0.42
    static let stagger: TimeInterval = 0.04
    /// Long enough for the later button, and its strand, to finish, with room for the clock to start
    static let settleTime: TimeInterval = revealDuration + stagger + 0.25

    private static let revealCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.34, y: 1.56),
        endControlPoint: UnitPoint(x: 0.64, y: 1)
    )
    private static let retractCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.5, y: 0),
        endControlPoint: UnitPoint(x: 0.3, y: 1)
    )

    /// One button's move
    private struct Leg {
        var from: CGFloat = 0
        var to: CGFloat = 0
        var start = Date.distantPast
        var out = true
        var animated = false
        /// How far into its life a retract strand starts: past reaching for the button when the
        /// reveal's strand hadn't snapped yet
        var strandHead: TimeInterval = 0

        func frame(at date: Date) -> GooFrame {
            guard animated else { return GooFrame(progress: to, strand: .none) }
            let t = max(date.timeIntervalSince(start), 0)
            let duration = out ? GooMotion.revealDuration : GooMotion.retractDuration
            let curve = out ? GooMotion.revealCurve : GooMotion.retractCurve
            let progress = from + (to - from) * CGFloat(curve.value(at: min(t / duration, 1)))
            let strand: GooStrand
            if out {
                strand = t < GooStrand.revealLife ? .reveal(t) : .none
            } else {
                strand = t < duration ? .retract(t + strandHead) : .none
            }
            return GooFrame(progress: progress, strand: strand)
        }
    }

    /// Each button's current move, and the one before it, which carries on through the stagger
    private var more = (previous: Leg(), current: Leg())
    private var stop = (previous: Leg(), current: Leg())

    /// An animated move waiting for the next frame drawn, so its clock starts on screen and none of
    /// the squeeze out of the mic is skipped
    private var pendingMove: Bool?

    func move(out: Bool, animated: Bool) {
        pendingMove = nil
        if animated {
            pendingMove = out
        } else {
            start(out: out, at: .now, animated: false)
        }
    }

    func frames(at date: Date) -> (more: GooFrame, stop: GooFrame) {
        if let out = pendingMove {
            pendingMove = nil
            start(out: out, at: date, animated: true)
        }
        return (Self.frame(of: more, at: date), Self.frame(of: stop, at: date))
    }

    private func start(out: Bool, at date: Date, animated: Bool) {
        // More leads out, Stop leads in
        more = Self.legs(after: more, out: out, start: date + (out ? 0 : Self.stagger), now: date, animated: animated)
        stop = Self.legs(after: stop, out: out, start: date + (out ? Self.stagger : 0), now: date, animated: animated)
    }

    private static func frame(of legs: (previous: Leg, current: Leg), at date: Date) -> GooFrame {
        (date < legs.current.start ? legs.previous : legs.current).frame(at: date)
    }

    private static func legs(
        after legs: (previous: Leg, current: Leg), out: Bool, start: Date, now: Date, animated: Bool
    ) -> (previous: Leg, current: Leg) {
        let previous = now < legs.current.start ? legs.previous : legs.current
        let handover = previous.frame(at: start)
        var leg = Leg(from: handover.progress, to: out ? 1 : 0, start: start, out: out, animated: animated)
        // Already there: nothing to move, and no strand
        if abs(leg.to - leg.from) < 0.001 { leg.animated = false }
        // Pulled back in before the strand snapped: it's still attached, so it doesn't reach out again
        if !out, case .reveal(let t) = handover.strand, t < GooStrand.snap {
            leg.strandHead = GooStrand.reach + GooStrand.fill
        }
        return (previous, leg)
    }
}

// MARK: - Goo Strand

/// The white strand between the mic and a secondary button, by the seconds since the button started
/// moving (liquid-gooey's Move "liquid rubber": the strand lags the button, thins and snaps behind it).
///
/// Coming out, the button leaves on its own curve and the strand stretches behind it: a thick band
/// while the button clears the mic, thinning from 100ms to a thread, which snaps at 310ms - the
/// top of the button's overshoot, where it's stretched furthest - and whose ends recoil into the
/// mic and the button as droplets over 90ms, as the button bounces back. Going in, a strand reaches
/// out from the mic and from the button, joins in 70ms, fills out over 80ms and draws the button in.
enum GooStrand: Equatable {
    case none
    case reveal(TimeInterval)
    case retract(TimeInterval)

    static let thinStart: TimeInterval = 0.10
    static let snap: TimeInterval = 0.31
    static let recoil: TimeInterval = 0.12
    static let revealLife: TimeInterval = snap + recoil
    static let reach: TimeInterval = 0.09
    static let fill: TimeInterval = 0.08

    // Points along the button's axis, from the mic's center
    private static let micEdge: CGFloat = 36
    private static let buttonRadius: CGFloat = 26
    /// Where the strand meets the mic or the button (half its width)
    private static let rootHalfWidth: CGFloat = 13
    /// The waist as it starts to thin, and the thread it thins to - just thicker than the goo cut
    private static let startHalfWidth: CGFloat = 9
    private static let threadHalfWidth: CGFloat = 2.9
    /// How far the strand flares out into the mic and the button
    private static let filletLength: CGFloat = 8
    /// The drop a snapped end balls up into
    private static let dropletRadius: CGFloat = 6.5

    /// The button's outline is hidden while the strand joins it, since it would cut across it
    var strokeOpacity: Double {
        switch self {
        case .none: return 1
        case .reveal(let t): return Self.clamp((t - Self.snap) / Self.recoil)
        case .retract(let t): return Self.clamp(1 - t / Self.reach)
        }
    }

    /// The strand's silhouette, before the goo filter, for a button centered `x` points along +x from
    /// the mic's center (the origin). Its ends run under the mic and the button.
    func path(buttonX x: CGFloat) -> Path {
        let inner: CGFloat = 26
        let outer = x - 10
        guard outer > inner, self != .none else { return Path() }
        let g0 = Self.micEdge
        let g1 = x - Self.buttonRadius
        // Still overlapping the mic: a thick band joins them
        if g1 <= g0 + 1 {
            return Path(CGRect(x: inner, y: -Self.rootHalfWidth, width: outer - inner, height: 2 * Self.rootHalfWidth))
        }
        let neck = (g0 + g1) / 2

        switch self {
        case .none:
            return Path()
        case .reveal(let t):
            if t < Self.snap {
                let s = Self.easeOut((t - Self.thinStart) / (Self.snap - Self.thinStart))
                let waist = Self.startHalfWidth + (Self.threadHalfWidth - Self.startHalfWidth) * s
                return Self.band(from: inner, to: outer, g0: g0, g1: g1, waist: waist)
            }
            // Snapped: each end springs back into its body, balling up into a droplet as it goes
            let x = (t - Self.snap) / Self.recoil
            guard x < 1 else { return Path() }
            let r = Self.easeOut(x)
            let droplet = Self.threadHalfWidth + (Self.dropletRadius - Self.threadHalfWidth) * Self.easeOut(x * 3)
            return Self.ends(
                micTip: neck - 2.5 + (g0 - 2 - neck + 2.5) * r, buttonTip: neck + 2.5 + (g1 + 2 - neck - 2.5) * r,
                inner: inner, outer: outer, g0: g0, g1: g1, droplet: droplet
            )
        case .retract(let t):
            if t < Self.reach {
                let r = Self.easeOut(t / Self.reach)
                return Self.ends(
                    micTip: g0 - 2 + (neck - g0 + 2) * r, buttonTip: g1 + 2 + (neck - g1 - 2) * r,
                    inner: inner, outer: outer, g0: g0, g1: g1, droplet: Self.dropletRadius
                )
            }
            let s = Self.smoothstep((t - Self.reach) / Self.fill)
            let waist = Self.threadHalfWidth + (Self.rootHalfWidth - Self.threadHalfWidth) * s
            return Self.band(from: inner, to: outer, g0: g0, g1: g1, waist: waist)
        }
    }

    /// A band from the mic to the button: `waist` half-wide between them, flaring to the root width
    private static func band(from inner: CGFloat, to outer: CGFloat, g0: CGFloat, g1: CGFloat, waist: CGFloat) -> Path {
        ribbon(from: inner, to: outer) { halfWidth(at: $0, g0: g0, g1: g1, waist: waist, fillet: filletLength) }
    }

    /// A snapped strand: a thread from each body ending in a droplet at its tip
    private static func ends(
        micTip: CGFloat, buttonTip: CGFloat, inner: CGFloat, outer: CGFloat, g0: CGFloat, g1: CGFloat, droplet: CGFloat
    ) -> Path {
        var path = Path()
        let micLength = micTip - g0
        if micLength > 0 {
            let fillet = min(filletLength, micLength)
            path.addPath(ribbon(from: inner, to: micTip) {
                halfWidth(at: $0, g0: g0, g1: g0 + 2 * micLength, waist: threadHalfWidth, fillet: fillet)
            })
        }
        let buttonLength = g1 - buttonTip
        if buttonLength > 0 {
            let fillet = min(filletLength, buttonLength)
            path.addPath(ribbon(from: buttonTip, to: outer) {
                halfWidth(at: $0, g0: g1 - 2 * buttonLength, g1: g1, waist: threadHalfWidth, fillet: fillet)
            })
        }
        for tip in [micTip, buttonTip] {
            path.addEllipse(in: CGRect(x: tip - droplet, y: -droplet, width: 2 * droplet, height: 2 * droplet))
        }
        return path
    }

    /// Half the strand's width at `u`: the root width at and beyond the bodies' edges (g0, g1),
    /// easing down over `fillet` points to `waist` between them
    private static func halfWidth(at u: CGFloat, g0: CGFloat, g1: CGFloat, waist: CGFloat, fillet: CGFloat) -> CGFloat {
        if u <= g0 || u >= g1 { return rootHalfWidth }
        var a = g0 + fillet
        var b = g1 - fillet
        if b < a { a = (g0 + g1) / 2; b = a }
        let l: CGFloat = u < a ? (a - u) / (a - g0) : u > b ? (u - b) / (g1 - b) : 0
        return waist + (rootHalfWidth - waist) * l * l
    }

    /// A band along x from `u0` to `u1`, symmetric about the axis
    private static func ribbon(from u0: CGFloat, to u1: CGFloat, halfWidth: (CGFloat) -> CGFloat) -> Path {
        guard u1 > u0 else { return Path() }
        let count = max(2, Int((u1 - u0).rounded(.up)) + 1)
        let us = (0..<count).map { u0 + (u1 - u0) * CGFloat($0) / CGFloat(count - 1) }
        var path = Path()
        path.addLines(us.map { CGPoint(x: $0, y: -halfWidth($0)) } + us.reversed().map { CGPoint(x: $0, y: halfWidth($0)) })
        path.closeSubpath()
        return path
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    private static func easeOut(_ x: Double) -> CGFloat { let c = 1 - clamp(x); return CGFloat(1 - c * c * c) }
    private static func smoothstep(_ x: Double) -> CGFloat { let c = clamp(x); return CGFloat(c * c * (3 - 2 * c)) }
}

// MARK: - Gooey Secondary Button

/// A mic-button secondary button that comes out of the mic like goo: a disc hidden under the mic,
/// the button's disc and the strand between them (GooStrand) are blurred together and cut back to a
/// hard edge in the button's white, so the strand melts into both. The crisp button rides on top.
/// `goo` comes from GooMotion, frame by frame.
private struct GooeySecondaryButton: View {
    let goo: GooFrame
    let offset: CGFloat  // resting x offset from the mic's center, negative = left
    let iconName: String
    /// SF Symbol and its point size
    let iconSize: CGFloat
    var alternateIcon: (name: String, size: CGFloat)? = nil
    var showsAlternate: Bool = false
    let accessibilityLabel: String
    let action: () -> Void

    // Goo, in points: the blur melts the pieces together; the edge sits where the blurred silhouette
    // is 5/12 opaque, liquid-gooey's default (contrast 18)
    private static let gooBlur: CGFloat = 5
    private static let gooThreshold: Double = 5.0 / 12.0
    // Just inside the mic's 36pt radius, so the strand seems to come from beneath it
    private static let sourceRadius: CGFloat = 34
    // Blurred and cut back, this lands on the button's own 26pt edge
    private static let blobRadius: CGFloat = 25.5

    var body: some View {
        let x = offset * goo.progress

        ZStack {
            Canvas { context, size in
                // Only while there's a strand - the hidden disc would otherwise show through the mic
                // while it's pressed and dimmed
                guard goo.progress > 0.001, goo.strand != .none else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                // Filters run last-added first: melt the pieces together, cut the result back to a
                // hard edge in the button's white, then soften that edge by half a point
                context.addFilter(.blur(radius: 0.5))
                context.addFilter(.alphaThreshold(min: Self.gooThreshold, color: AppColors.secondaryButton))
                context.addFilter(.blur(radius: Self.gooBlur))
                context.drawLayer { layer in
                    layer.translateBy(x: center.x, y: center.y)
                    layer.fill(Self.disc(at: .zero, radius: Self.sourceRadius), with: .color(.black))
                    layer.fill(Self.disc(at: CGPoint(x: x, y: 0), radius: Self.blobRadius), with: .color(.black))
                    // The strand is laid out along +x; mirror it for the left button
                    layer.scaleBy(x: offset < 0 ? -1 : 1, y: 1)
                    layer.fill(goo.strand.path(buttonX: abs(x)), with: .color(.black))
                }
            }
            .frame(width: 300, height: 128)  // the 252 x 80 control plus room for the blur
            .allowsHitTesting(false)

            Button(action: action) {
                SecondaryRoundButton(
                    iconName: iconName,
                    iconSize: iconSize,
                    alternateIcon: alternateIcon,
                    showsAlternate: showsAlternate,
                    strokeOpacity: goo.strand.strokeOpacity
                )
            }
            .buttonStyle(IOSPressStyle(.control, in: Circle()))
            #if DEBUG
            .recordingPressID(iconName)  // the live recording demo holds it down
            #endif
            .accessibilityLabel(accessibilityLabel)
            .offset(x: x)
            // Hidden when tucked in, since the mic dims while pressed
            .opacity(goo.progress > 0.001 ? 1 : 0)
            .allowsHitTesting(goo.progress > 0.5)
            .accessibilityHidden(goo.progress < 0.5)
        }
        // Driven frame by frame; an animation around isSessionActive mustn't smear it
        .transaction { $0.animation = nil }
    }

    private static func disc(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

// MARK: - Secondary Round Button

struct SecondaryRoundButton: View {
    let iconName: String
    /// SF Symbol point size
    var iconSize: CGFloat = 20
    /// Swapped in (Transitions.dev icon swap) while `showsAlternate` is on, e.g. More to X
    var alternateIcon: (name: String, size: CGFloat)? = nil
    var showsAlternate: Bool = false
    var strokeOpacity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

            // Icon, and the icon it swaps to
            icon(iconName, size: iconSize)
                .iconSwapShown(!showsAlternate)
            if let alternateIcon {
                icon(alternateIcon.name, size: alternateIcon.size)
                    .iconSwapShown(showsAlternate)
            }
        }
        .animation(reduceMotion ? nil : IconSwap.animation, value: showsAlternate)
    }

    /// An SF Symbol, centered in a 44pt box
    private func icon(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(AppColors.primaryIcon)
            .frame(width: 44, height: 44)
    }
}

// MARK: - Mic Menu Cards

/// The voice & honorifics cards the mic control lifts to uncover (Figma "Korean AI Translator",
/// node 300:13161): two 88pt glass cards, each a 28pt Phosphor icon over a 16pt label. Figma's cards were
/// 168pt wide, 20pt from the screen's edges; each now reaches 5pt further on both sides (178pt on a
/// 402pt screen, 15pt from the edges), so the gap between them is the 16pt gap above them to the lifted
/// mic (lifted 96pt; the cards' tops sit 80pt above its resting bottom).
struct MicMenuCards: View {
    let isMaleVoice: Bool
    let isHonorificsOn: Bool
    let voiceTitle: String
    let honorificsTitle: String
    var isKorean: Bool = false
    var onVoiceTapped: () -> Void
    var onHonorificsTapped: () -> Void

    /// The cards come in (and go) over 400ms on the lift's ease-out
    static let revealAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.4)

    /// Between the cards: the same as the gap above them to the lifted mic
    static let cardGap: CGFloat = 16
    static let sideMargin: CGFloat = 15

    var body: some View {
        HStack(spacing: Self.cardGap) {
            MicMenuCard(iconName: "gender-female", alternateIconName: "gender-male", showsAlternate: isMaleVoice,
                        title: voiceTitle, isKorean: isKorean, action: onVoiceTapped)
                .frame(maxWidth: .infinity)
            MicMenuCard(iconName: "crown-simple", alternateIconName: "crown-simple-slash", showsAlternate: !isHonorificsOn,
                        title: honorificsTitle, isKorean: isKorean, action: onHonorificsTapped)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Self.sideMargin)
    }
}

private struct MicMenuCard: View {
    let iconName: String
    var alternateIconName: String? = nil
    var showsAlternate: Bool = false
    let title: String
    let isKorean: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.micMenuRevealBlur) private var revealBlur

    var body: some View {
        Button(action: action) {
            // The icon swap and the label's text swap start together on the tap
            VStack(spacing: 8) {
                ZStack {
                    icon(iconName)
                        .iconSwapShown(!showsAlternate)
                    if let alternateIconName {
                        icon(alternateIconName)
                            .iconSwapShown(showsAlternate)
                    }
                }
                .animation(reduceMotion ? nil : IconSwap.animation, value: showsAlternate)

                SwappingText(title) {
                    Text($0)
                        .font(isKorean ? AppTypography.optionLabelKorean : AppTypography.optionLabel)
                        .foregroundColor(AppColors.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: 20)
                }
            }
            .blur(radius: revealBlur)  // the reveal blurs the contents, never the glass
            .padding(.vertical, 9)  // the glass style adds 7pt a side → the 88pt card
            .frame(maxWidth: .infinity)
        }
        // System glass button style: iOS draws the glass and its press state, like every glass
        // button on the phone's iOS version
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: AppStyle.cornerRadius))
        #if DEBUG
        .recordingCardPress(iconName)  // the live recording demo taps it
        #endif
    }

    private func icon(_ name: String) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .frame(width: 28, height: 28)
            .foregroundColor(AppColors.secondaryIcon)
    }
}

/// The mic menu cards' reveal: in from 104% scale and transparent, their icons and labels from an 8pt
/// blur (and back out). Only the contents blur: blurring the glass itself flattens it to a bitmap,
/// and the 104% scale then left its corners jagged.
private struct MicMenuRevealEffect: ViewModifier, Animatable {
    /// 0 = hidden, 1 = shown
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.micMenuRevealBlur, 8 * (1 - progress))
            .opacity(progress)
            .scaleEffect(1 + 0.04 * (1 - progress))
    }
}

extension EnvironmentValues {
    /// How blurred the mic menu cards' contents are mid-reveal
    @Entry var micMenuRevealBlur: CGFloat = 0
}

extension AnyTransition {
    static var micMenuReveal: AnyTransition {
        .modifier(active: MicMenuRevealEffect(progress: 0), identity: MicMenuRevealEffect(progress: 1))
    }
}
