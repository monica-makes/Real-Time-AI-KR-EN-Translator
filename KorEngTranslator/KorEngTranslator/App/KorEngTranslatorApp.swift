import SwiftUI

@main
struct KorEngTranslatorApp: App {
    init() {
        // Print all available font names to verify custom fonts are loaded
        AppTypography.printAllFontNames()
    }

    var body: some Scene {
        WindowGroup {
            WelcomeScreenLangSelect()
        }
    }
}
