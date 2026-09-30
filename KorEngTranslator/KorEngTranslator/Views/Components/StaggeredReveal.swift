import SwiftUI

/// Transitions.dev "Texts reveal", letter by letter: on appear, each letter rises 8pt from below,
/// unblurs from 3pt and fades in over 500ms on cubic-bezier(0.22, 1, 0.36, 1), starting 18ms after
/// the one to its left, so the text rolls in from left to right (a quieter take on the website's
/// roll-in). Until it starts, the text can't be tapped or read out. Reduce Motion shows the text
/// at once (after the delay).
///
///     Text("Can't find your partner?").staggeredReveal(delay: 0.4)
struct StaggeredReveal: ViewModifier {
    var delay: TimeInterval = 0

    static let duration: TimeInterval = 0.5
    static let stagger: TimeInterval = 0.018
    /// Long enough for about 80 letters to finish
    private static let runTime: TimeInterval = 2

    @State private var elapsed: TimeInterval = 0
    @State private var hasStarted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .textRenderer(StaggeredRevealRenderer(elapsed: elapsed))
            .allowsHitTesting(hasStarted)
            .accessibilityHidden(!hasStarted)
            .task {
                elapsed = 0
                hasStarted = false
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                hasStarted = true
                if reduceMotion {
                    elapsed = Self.runTime
                } else {
                    withAnimation(.linear(duration: Self.runTime)) { elapsed = Self.runTime }
                }
            }
    }
}

extension View {
    func staggeredReveal(delay: TimeInterval = 0) -> some View {
        modifier(StaggeredReveal(delay: delay))
    }
}

/// Draws each letter at its own point in the reveal; `elapsed` runs linearly and each letter eases
/// its own 500ms
private struct StaggeredRevealRenderer: TextRenderer, Animatable {
    var elapsed: TimeInterval

    var animatableData: TimeInterval {
        get { elapsed }
        set { elapsed = newValue }
    }

    private static let distance: CGFloat = 8
    private static let blur: CGFloat = 3
    private static let curve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.22, y: 1),
        endControlPoint: UnitPoint(x: 0.36, y: 1)
    )

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let start = Double(index) * StaggeredReveal.stagger
                    let linear = min(max((elapsed - start) / StaggeredReveal.duration, 0), 1)
                    index += 1
                    guard linear > 0 else { continue }
                    guard linear < 1 else {
                        context.draw(slice)
                        continue
                    }
                    let p = Self.curve.value(at: linear)
                    var letter = context
                    letter.opacity = p
                    letter.translateBy(x: 0, y: Self.distance * (1 - p))
                    letter.addFilter(.blur(radius: Self.blur * (1 - p)))
                    letter.draw(slice)
                }
            }
        }
    }
}
