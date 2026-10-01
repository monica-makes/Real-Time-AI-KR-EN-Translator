import SwiftUI

/// The welcome heading's typing, softened: each letter comes in at its own start time (the typing
/// rhythm) and unblurs from 10pt while it fades in over 600ms, on a slow-in, long-settle curve in
/// the spirit of the iPhone's "hello". The whole heading is laid out from the start, so nothing
/// re-wraps or shifts while letters arrive.
///
///     Text("Welcome").textRenderer(BlurTypeRenderer(elapsed: elapsed, starts: starts))
///
/// Drive `elapsed` with a linear animation from 0 to `BlurTypeRenderer.totalDuration(starts:)`.
struct BlurTypeRenderer: TextRenderer, Animatable {
    /// Seconds since the reveal started
    var elapsed: TimeInterval
    /// Start time of each letter, in seconds from the reveal's start. Letters past the end of the
    /// array start with the last one.
    var starts: [TimeInterval]

    var animatableData: TimeInterval {
        get { elapsed }
        set { elapsed = newValue }
    }

    static let letterDuration: TimeInterval = 0.6
    private static let blur: CGFloat = 10
    /// Eases in gently, then takes its time settling, like the strokes of the iPhone's "hello"
    private static let curve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.45, y: 0),
        endControlPoint: UnitPoint(x: 0.2, y: 1)
    )

    /// When the last letter has fully settled
    static func totalDuration(starts: [TimeInterval]) -> TimeInterval {
        (starts.last ?? 0) + letterDuration
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let start = starts.isEmpty ? 0 : starts[min(index, starts.count - 1)]
                    let linear = min(max((elapsed - start) / Self.letterDuration, 0), 1)
                    index += 1
                    guard linear > 0 else { continue }
                    guard linear < 1 else {
                        context.draw(slice)
                        continue
                    }
                    let p = Self.curve.value(at: linear)
                    var letter = context
                    // Opacity leads the blur a little, so a letter reads as a soft shape, not a ghost
                    letter.opacity = min(1, p * 1.5)
                    letter.addFilter(.blur(radius: Self.blur * (1 - p)))
                    letter.draw(slice)
                }
            }
        }
    }
}
