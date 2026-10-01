import SwiftUI

/// How onboarding changes pages: only the page's UI moves, pushed in from the right (or from the left
/// going back) while the old page slides out the other way. The background (orb, grain) belongs to
/// the welcome screen underneath and stays put. Reduce Motion cross-fades instead.
///
///     @State private var pushEdge: Edge? = .trailing
///     page.onboardingPush(from: pushEdge)
///     OnboardingPush.go(.forward, edge: $pushEdge) { currentScreen = .success(roomId: id) }
enum OnboardingPush {
    enum Direction {
        case forward, back
        /// Cross-fade, for leaving onboarding (the live screen draws its own background)
        case fade

        var edge: Edge? {
            switch self {
            case .forward: .trailing
            case .back: .leading
            case .fade: nil
            }
        }

        var animation: Animation {
            switch self {
            case .forward, .back: OnboardingPush.animation
            case .fade: .easeInOut(duration: 0.4)
            }
        }
    }

    /// Quick and settling, like a navigation push
    static let animation: Animation = .spring(duration: 0.4, bounce: 0)

    /// Points `edge` the right way first, then changes page on the next run loop, so the outgoing
    /// page leaves in the new direction too (a removed view keeps the transition it last had)
    @MainActor static func go(_ direction: Direction, edge: Binding<Edge?>, _ change: @escaping () -> Void) {
        edge.wrappedValue = direction.edge
        DispatchQueue.main.async {
            withAnimation(direction.animation, change)
        }
    }
}

private struct OnboardingPushTransition: ViewModifier {
    let edge: Edge?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // One transition value, not an if/else, so a change of direction doesn't rebuild the page
    func body(content: Content) -> some View {
        content.transition(edge.map { reduceMotion ? AnyTransition.opacity : .push(from: $0) } ?? .opacity)
    }
}

extension View {
    /// A page in onboarding; `edge` is where pages come in from right now (nil cross-fades)
    func onboardingPush(from edge: Edge?) -> some View {
        modifier(OnboardingPushTransition(edge: edge))
    }
}
