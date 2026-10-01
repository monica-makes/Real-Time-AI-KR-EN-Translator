import SwiftUI

// MARK: - Bubble Style Enum

enum BubbleStyle: Int, CaseIterable {
    case organic = 1
    case glass = 2
    case combination = 3
    #if DEBUG
    /// Combination with its colors flowing like the reel's orb (OrbFlowStyle.swift)
    case flow = 4
    #endif

    var displayName: String {
        switch self {
        case .organic: return "Organic"
        case .glass: return "Glass"
        case .combination: return "Combination"
        #if DEBUG
        case .flow: return "Flow (reel)"
        #endif
        }
    }
}

// MARK: - Orb State
// What the orb is doing right now. Drives the Siri-glass motion language.

enum OrbState: String, CaseIterable, Identifiable {
    case idle        // Nobody is talking to us, or the other person is talking
    case listening   // Our mic is live and the user is speaking
    case responding  // Translated speech is playing back

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .responding: return "Responding"
        }
    }
}

// MARK: - Main Bubble View
// Classic styles animate continuously on appear with no audio binding.
// The Siri-glass variant is driven by `orbState` / `audioLevel`.

struct OrganicBubble: View {
    var style: BubbleStyle = .combination

    /// When true, renders the Siri-inspired glass variant instead of `style`.
    /// The classic styles keep their original constant animation.
    var useSiriGlass: Bool = false

    /// Only the Siri-glass variant reacts to these.
    var orbState: OrbState = .idle
    var audioLevel: CGFloat = 0

    var body: some View {
        if useSiriGlass {
            SiriGlassBubble(state: orbState, audioLevel: audioLevel)
        } else {
            switch style {
            case .organic:
                OrganicOnlyBubble()
            case .glass:
                GlassOnlyBubble()
            case .combination:
                CombinationBubble()
            #if DEBUG
            case .flow:
                CombinationBubble(flow: .launch)
            #endif
            }
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

#Preview("Siri Glass - Listening") {
    ZStack {
        AppColors.background.ignoresSafeArea()
        OrganicBubble(useSiriGlass: true, orbState: .listening, audioLevel: 0.6)
    }
}
