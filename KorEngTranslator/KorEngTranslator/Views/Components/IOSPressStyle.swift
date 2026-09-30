import SwiftUI

/// iOS 26's own press response, for our custom-drawn buttons. Measured on 2026-09-30 from native
/// controls on the iOS 27 simulator (60fps recordings of long presses):
/// - Small Liquid Glass controls (a 44pt `.glass` button, a 72pt `.interactive()` circle) grow by
///   a fixed 16pt overall within about 130ms of touch-down, with a slight overshoot, and brighten:
///   the black circle to about 40% white. On release they spring back with a visible bounce,
///   undershooting by about a quarter of the travel, then overshooting a little, settled in ~0.5s.
/// - Large glass surfaces (a 175 x 216 card) don't react at all. iOS's large tappable cards (App
///   Store, widgets) press in instead, so `.card` shrinks 3% on the same springs.
/// - Plain text and icon buttons drop to about 30% opacity at once and fade back over ~450ms;
///   that's the default button style, so those keep it rather than use this.
enum IOSPress {
    /// Touch-down: peaks in ~130ms with ~8% overshoot
    static let press = Animation.spring(response: 0.19, dampingFraction: 0.63)
    /// Release: undershoots ~25% of the travel, then ~6% the other way, settled in ~0.5s
    static let release = Animation.spring(response: 0.3, dampingFraction: 0.4)
    /// How much a small control grows while pressed, whatever its size (8pt a side)
    static let controlGrowth: CGFloat = 16
    /// How far a card presses in
    static let cardScale: CGFloat = 0.97

    static func animation(pressed: Bool) -> Animation {
        pressed ? press : release
    }
}

enum IOSPressKind {
    /// Buttons and small controls: grow 16pt overall and brighten, like Liquid Glass
    case control
    /// Large cards: press in to 97% and brighten
    case card
}

/// iOS's press response for a custom-drawn button: `shape` outlines the button for the white
/// layer it gets while pressed. Reduce Motion keeps the white layer and drops the movement.
///
///     .buttonStyle(IOSPressStyle(.card, in: RoundedRectangle(cornerRadius: AppStyle.cornerRadius)))
struct IOSPressStyle<S: Shape>: ButtonStyle {
    let kind: IOSPressKind
    let shape: S
    /// White layer while pressed: 12% on the light surfaces, about 40% on a dark one (iOS's own)
    var highlight: Double

    init(_ kind: IOSPressKind, in shape: S, highlight: Double = 0.12) {
        self.kind = kind
        self.shape = shape
        self.highlight = highlight
    }

    func makeBody(configuration: Configuration) -> some View {
        IOSPressBody(label: configuration.label, isPressed: configuration.isPressed,
                     kind: kind, shape: shape, highlight: highlight)
    }
}

private struct IOSPressBody<Label: View, S: Shape>: View {
    let label: Label
    let isPressed: Bool
    let kind: IOSPressKind
    let shape: S
    let highlight: Double

    /// The button's size, so a control grows by the same 16pt at any size
    @State private var size: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pressedScale: CGFloat {
        switch kind {
        case .card:
            return IOSPress.cardScale
        case .control:
            let side = max(size.width, size.height)
            return side > 0 ? 1 + IOSPress.controlGrowth / side : 1
        }
    }

    var body: some View {
        label
            .overlay {
                shape
                    .fill(Color.white.opacity(isPressed ? highlight : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(isPressed && !reduceMotion ? pressedScale : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : IOSPress.animation(pressed: isPressed),
                       value: isPressed)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                size = newSize
            }
    }
}
