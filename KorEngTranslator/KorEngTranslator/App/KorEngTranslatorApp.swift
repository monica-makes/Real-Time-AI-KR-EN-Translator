import SwiftUI

#if DEBUG
extension Notification.Name {
    /// Posted by debug panels to tear down the current flow and start over on the welcome screen
    static let debugRestartToHome = Notification.Name("debugRestartToHome")
}
#endif

@main
struct KorEngTranslatorApp: App {
    #if DEBUG
    // Changing the root id rebuilds the whole view tree (screens disconnect in onDisappear)
    @State private var rootID = UUID()
    @State private var hasRestartedToHome = false
    #endif

    init() {
        // Print all available font names to verify custom fonts are loaded
        AppTypography.printAllFontNames()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            Group {
                if (ProcessInfo.processInfo.arguments.contains("-orbPreview") || LiveRecordingDemo.isOn) && !hasRestartedToHome {
                    // Screenshot / preview harness: jump straight to the translator screen.
                    // Combine with -siriGlass 1 -orbState listening -orbLevel 0.6
                    // (-liveDemo: the reel's screen recording, LiveRecordingDemo.swift)
                    LiveTranslationScreen(roomId: "ORB-PREVIEW", language: "en")
                } else {
                    WelcomeScreenLangSelect()
                }
            }
            .id(rootID)
            .onReceive(NotificationCenter.default.publisher(for: .debugRestartToHome)) { _ in
                hasRestartedToHome = true
                rootID = UUID()
            }
            // Website pairing videos: -pairingDemo en|ko, -cleanRecording, -showTouches
            .pairingRecordingDemo()
            #else
            WelcomeScreenLangSelect()
            #endif
        }
    }
}
