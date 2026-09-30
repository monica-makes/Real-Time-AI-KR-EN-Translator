import SwiftUI

/// Transitions.dev "Text states swap": when `text` changes, the old text slides up 4pt, blurs 2pt and
/// fades out over 150ms, then the new text starts 4pt below, blurred and clear, and eases back in
/// over 150ms. Same ease-in-out curve as IconSwap, so the two can run together. Reduce Motion swaps
/// with no movement.
///
///     SwappingText(isConnected ? "Headphones connected" : "No headphones connected") {
///         Text($0).font(AppTypography.b1)
///     }
struct SwappingText<Content: View>: View {
    private let text: String
    private let content: (String) -> Content

    static var duration: TimeInterval { 0.15 }
    static var animation: Animation { .timingCurve(0.42, 0, 0.58, 1, duration: duration) }  // CSS ease-in-out
    private static var travel: CGFloat { 4 }
    private static var blur: CGFloat { 2 }

    private enum Phase { case shown, exiting, entering }

    @State private var shownText: String
    @State private var phase = Phase.shown
    /// Only the latest change finishes its swap
    @State private var swapID = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String, @ViewBuilder content: @escaping (String) -> Content) {
        self.text = text
        self.content = content
        _shownText = State(initialValue: text)
    }

    var body: some View {
        content(shownText)
            .offset(y: phase == .exiting ? -Self.travel : phase == .entering ? Self.travel : 0)
            .blur(radius: phase == .shown ? 0 : Self.blur)
            .opacity(phase == .shown ? 1 : 0)
            .onChange(of: text) { _, newText in
                swap(to: newText)
            }
    }

    private func swap(to newText: String) {
        guard !reduceMotion else {
            shownText = newText
            return
        }
        swapID += 1
        let id = swapID
        withAnimation(Self.animation) { phase = .exiting }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) {
            guard id == swapID else { return }
            // Jump below with no animation, then come back up
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) {
                shownText = newText
                phase = .entering
            }
            DispatchQueue.main.async {
                guard id == swapID else { return }
                withAnimation(Self.animation) { phase = .shown }
            }
        }
    }
}
