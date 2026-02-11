import SwiftUI

// MARK: - Bubble Style Enum

enum BubbleStyle: Int, CaseIterable {
    case organic = 1
    case glass = 2
    case combination = 3

    var displayName: String {
        switch self {
        case .organic: return "Organic"
        case .glass: return "Glass"
        case .combination: return "Combination"
        }
    }
}

// MARK: - Main Bubble View
// Active prototype version - all bubbles animate continuously on appear
// No audio bindings needed for prototyping

struct OrganicBubble: View {
    var style: BubbleStyle = .combination

    var body: some View {
        switch style {
        case .organic:
            OrganicOnlyBubble()
        case .glass:
            GlassOnlyBubble()
        case .combination:
            CombinationBubble()
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        AppColors.background.ignoresSafeArea()
        OrganicBubble(style: .combination)
    }
}
