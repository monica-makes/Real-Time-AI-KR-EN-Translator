import SwiftUI

/// iMessage-style chat bubble (Figma "chat message" frame): a rounded rectangle whose bottom
/// corner curls out into a tail. The rect includes the tail, which takes `tailWidth` on its side.
struct ChatBubbleShape: Shape {
    /// My bubbles have the tail on the right, the partner's on the left
    var tailOnRight: Bool
    var cornerRadius: CGFloat = 18

    /// How far the tail reaches past the bubble's side
    static let tailWidth: CGFloat = 6.5

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let body = width - Self.tailWidth                       // the bubble's side the tail grows from
        let radius = min(cornerRadius, height / 2, body / 2)
        let tailRise = min(16, height / 2)                      // where the side starts curving into the tail

        // Drawn with the tail on the right, then mirrored for the left
        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: body - radius, y: 0))
        path.addArc(tangent1End: CGPoint(x: body, y: 0), tangent2End: CGPoint(x: body, y: radius), radius: radius)
        path.addLine(to: CGPoint(x: body, y: height - tailRise))
        // Outer edge of the tail, sweeping down to its tip
        path.addCurve(
            to: CGPoint(x: width, y: height),
            control1: CGPoint(x: body, y: height - 5.5),
            control2: CGPoint(x: width - 2.4, y: height - 0.9)
        )
        // Inner edge: a rounded hump up under the bubble, then back onto its bottom edge
        path.addCurve(
            to: CGPoint(x: body - 5.5, y: height - 4),
            control1: CGPoint(x: width - 3.4, y: height - 0.2),
            control2: CGPoint(x: body - 0.5, y: height - 4)
        )
        path.addCurve(
            to: CGPoint(x: body - 15, y: height),
            control1: CGPoint(x: body - 9, y: height - 4),
            control2: CGPoint(x: body - 11, y: height)
        )
        path.addLine(to: CGPoint(x: radius, y: height))
        path.addArc(tangent1End: CGPoint(x: 0, y: height), tangent2End: CGPoint(x: 0, y: height - radius), radius: radius)
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: radius, y: 0), radius: radius)
        path.closeSubpath()

        let mirror = tailOnRight ? .identity : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        return path
            .applying(mirror)
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
