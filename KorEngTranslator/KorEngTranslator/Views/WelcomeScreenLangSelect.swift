import SwiftUI
import AVFoundation

// MARK: - Headphone Detector

class HeadphoneDetector: ObservableObject {
    @Published var isConnected: Bool = false

    init() {
        checkHeadphones()
        setupRouteChangeNotification()
    }

    private func checkHeadphones() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        isConnected = outputs.contains { output in
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
                .contains(output.portType)
        }
        #endif
    }

    private func setupRouteChangeNotification() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        #endif
    }

    @objc private func handleRouteChange() {
        DispatchQueue.main.async {
            self.checkHeadphones()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Language Option

enum LanguageOption: String, CaseIterable {
    case english
    case korean

    var flag: String {
        switch self {
        case .english: return "🇺🇸"
        case .korean: return "🇰🇷"
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .korean: return "한국어"
        }
    }

    var abbreviation: String {
        switch self {
        case .english: return "EN"
        case .korean: return "가"
        }
    }
}

// MARK: - Welcome Screen Language Select

struct WelcomeScreenLangSelect: View {
    @StateObject private var onboardingState = OnboardingState()
    @State private var showNewScreen = false
    var onLanguageSelected: ((LanguageOption) -> Void)?

    private var selectedLanguage: LanguageOption? {
        get { onboardingState.selectedLanguage }
    }

    // Animation state
    @State private var isShowingEnglish = true
    @State private var displayedHeading = ""
    @State private var headingOpacity: Double = 1
    @State private var subtitleOpacity: Double = 0
    @State private var typewriterTimer: Timer?
    @State private var cycleTimer: Timer?
    @State private var hasShownEnglish = false
    @State private var hasShownKorean = false

    // Content
    private let englishHeading = "👋 Welcome to Dari!"
    private let koreanHeading = "👋 \"Dari\" 에 오세요!"
    private let englishSubtitle = "Speak your language, hear theirs.\nChoose your language to begin."
    private let koreanSubtitle = "내 언어로 말하고, 상대방의 언어로 들으세요.\n시작하려면 언어를 선택하세요."

    // Timing
    private let englishCharsPerSecond: Double = 15
    private let koreanCharsPerSecond: Double = 15 * 1.25  // 1.25x faster
    private let englishDisplayDuration: Double = 5
    private let koreanDisplayDuration: Double = 5 / 1.25  // 1.25x faster
    private let subtitleFadeInDuration: Double = 1.25  // Same for both languages

    private var charactersPerSecond: Double {
        isShowingEnglish ? englishCharsPerSecond : koreanCharsPerSecond
    }

    private var displayDuration: Double {
        isShowingEnglish ? englishDisplayDuration : koreanDisplayDuration
    }

    private var currentHeading: String {
        isShowingEnglish ? englishHeading : koreanHeading
    }

    private var currentSubtitle: String {
        isShowingEnglish ? englishSubtitle : koreanSubtitle
    }

    // Heading view for typewriter effect
    // Korean heading: "👋 "Dari"에 오세요!" with emoji and "Dari" (with quotes) in English H1
    @ViewBuilder
    private var welcomeHeadingView: some View {
        if isShowingEnglish {
            // English: simple single-font text
            Text(displayedHeading)
                .font(AppTypography.h1)
                .lineSpacing(44 - 34)
                .tracking(0.88)
                .foregroundColor(AppColors.primaryText)
        } else {
            // Korean: mixed fonts - "👋 "Dari" " (English H1) + "에 오세요!" (Korean H1)
            // Korean heading structure: "👋 "Dari" 에 오세요!"
            // Indices: 0-8 = "👋 space"Dari"space" (9 chars), 9+ = "에 오세요!"
            let revealed = displayedHeading
            let englishPartEnd = 9  // "👋 space"Dari"space" is 9 characters (includes trailing space)

            let englishPart = String(revealed.prefix(min(revealed.count, englishPartEnd)))
            let koreanPart: String = {
                if revealed.count <= englishPartEnd { return "" }
                let start = revealed.index(revealed.startIndex, offsetBy: englishPartEnd)
                return String(revealed[start...])
            }()

            (Text(englishPart)
                .font(AppTypography.h1)
             + Text(koreanPart)
                .font(AppTypography.h1Korean))
                .lineSpacing(44 - 32)  // Match English H1 line height (44) to prevent shifting during typewriter
                .tracking(0.88)
                .foregroundColor(AppColors.primaryText)
        }
    }

    var body: some View {
        ZStack {
            // Background - always visible
            AppColors.background
                .ignoresSafeArea()

            // Gradient orb decoration - always visible, fixed position (ignores keyboard)
            GradientOrb()
                .frame(width: 400, height: 350)
                .rotationEffect(.degrees(-80))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 20, y: -238)
                .ignoresSafeArea(.keyboard)

            // Welcome screen content - fades out
            if !showNewScreen {
                Group {
                    // Welcome heading with typewriter effect - fixed position from top
                    welcomeHeadingView
                        .opacity(headingOpacity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 20)
                        .padding(.top, AppSpacing.welcomeContentStart - 8)
                        .frame(maxHeight: .infinity, alignment: .top)

                    // Subtitle with fade effect - fixed position from top
                    Text(currentSubtitle)
                        .font(isShowingEnglish ? AppTypography.b2 : AppTypography.b2Korean)
                        .lineSpacing(22 - 17)  // line height 22, font size 17
                        .tracking(0.37)
                        .foregroundColor(AppColors.primaryText)
                        .opacity(subtitleOpacity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 20)
                        .padding(.top, 236)
                        .frame(maxHeight: .infinity, alignment: .top)

                    // Language cards - fixed position at 358pt from top
                    VStack {
                        HStack(spacing: AppSpacing.betweenCards) {
                            LanguageCard(
                                language: .english,
                                isSelected: selectedLanguage == .english
                            ) {
                                onboardingState.selectedLanguage = .english
                                onLanguageSelected?(.english)
                                // Navigate to new screen after short delay
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation(.easeInOut(duration: 0.4)) {
                                        showNewScreen = true
                                    }
                                }
                            }

                            LanguageCard(
                                language: .korean,
                                isSelected: selectedLanguage == .korean
                            ) {
                                onboardingState.selectedLanguage = .korean
                                onLanguageSelected?(.korean)
                                // Navigate to Korean flow after short delay
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation(.easeInOut(duration: 0.4)) {
                                        showNewScreen = true
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)

                        Spacer()
                    }
                    .padding(.top, AppSpacing.cardsFromTop)
                }
                .transition(.opacity)
            }

            // New screen content - fades in based on selected language
            if showNewScreen {
                if selectedLanguage == .korean {
                    KoreanSelectedScreen(onboardingState: onboardingState) {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            showNewScreen = false
                        }
                    }
                    .transition(.opacity)
                } else {
                    EnglishSelectedScreen(onboardingState: onboardingState) {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            showNewScreen = false
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            startAnimationCycle()
        }
        .onDisappear {
            stopTimers()
        }
    }

    // MARK: - Animation Methods

    private func startAnimationCycle() {
        typeHeading()
    }

    private func typeHeading() {
        let characters = Array(currentHeading)
        typewriterTimer?.invalidate()

        // Check if this is the first time showing this language
        let isFirstTime = isShowingEnglish ? !hasShownEnglish : !hasShownKorean

        // Mark as shown
        if isShowingEnglish {
            hasShownEnglish = true
        } else {
            hasShownKorean = true
        }

        if isFirstTime {
            // Reset for typewriter effect
            displayedHeading = ""
            headingOpacity = 1

            // Start fading in subtitle as heading types
            withAnimation(.easeInOut(duration: subtitleFadeInDuration)) {
                subtitleOpacity = 1
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.typeNextCharacter(characters: characters, index: 0)
            }
        } else {
            // Subsequent times: fade in both header and body at the exact same time
            // First, set both to hidden state immediately (no animation)
            displayedHeading = currentHeading
            headingOpacity = 0
            subtitleOpacity = 0

            // Then animate both together with same timing
            withAnimation(.easeInOut(duration: subtitleFadeInDuration)) {
                headingOpacity = 1
                subtitleOpacity = 1
            }
            scheduleHideAndSwitch()
        }
    }

    private func typeNextCharacter(characters: [Character], index: Int) {
        guard index < characters.count else {
            // Heading finished typing, schedule fade out after display duration
            scheduleHideAndSwitch()
            return
        }

        // Add slight random variation (±0.01s) for organic feel
        let baseInterval = 1.0 / charactersPerSecond
        let randomVariation = Double.random(in: -0.01...0.01)
        let interval = max(0.02, baseInterval + randomVariation)

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [self] in
            // Animate each character with ease-out for soft landing
            withAnimation(.easeOut(duration: 0.08)) {
                displayedHeading.append(characters[index])
            }
            typeNextCharacter(characters: characters, index: index + 1)
        }
    }

    private func scheduleHideAndSwitch() {
        // Wait for display duration (6 seconds total from start), then fade out both
        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: displayDuration, repeats: false) { _ in
            hideAndSwitch()
        }
    }

    private func hideAndSwitch() {
        // Fade out both heading and subtitle at the exact same time with same timing
        withAnimation(.easeInOut(duration: 0.4)) {
            headingOpacity = 0
            subtitleOpacity = 0
        }

        // Switch language and restart after fade out completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            displayedHeading = ""
            isShowingEnglish.toggle()
            typeHeading()
        }
    }

    private func stopTimers() {
        typewriterTimer?.invalidate()
        cycleTimer?.invalidate()
    }
}

// MARK: - Gradient Orb

struct GradientOrb: View {
    // Animation states for each layer
    @State private var layer1Animate = false
    @State private var layer2Animate = false
    @State private var layer3Animate = false

    var body: some View {
        ZStack {
            // Layer 1 - "Farthest" (largest, bottom layer)
            Ellipse()
                .fill(AppColors.gradientCoral)
                .frame(width: 366.72, height: 312.57)
                .scaleEffect(layer1Animate ? 1.12 : 0.95)
                .rotationEffect(.degrees(layer1Animate ? 15 : -15))
                .offset(
                    x: layer1Animate ? 40 : -40,
                    y: 92 + (layer1Animate ? -30 : 30)
                )
                .blur(radius: 115.5)

            // Layer 2 - "Middle"
            Ellipse()
                .fill(AppColors.gradientAmber)
                .frame(width: 195.67, height: 124.29)
                .scaleEffect(layer2Animate ? 1.15 : 0.92)
                .rotationEffect(.degrees(80 + (layer2Animate ? 10 : -10)))
                .offset(
                    x: 40 + (layer2Animate ? 35 : -35),
                    y: 20 + (layer2Animate ? -25 : 25)
                )
                .blur(radius: 84)

            // Layer 3 - "Top" (smallest, front layer)
            Ellipse()
                .fill(AppColors.gradientPeach)
                .frame(width: 195.67, height: 124.29)
                .scaleEffect(layer3Animate ? 1.1 : 0.9)
                .rotationEffect(.degrees(80 + (layer3Animate ? 8 : -8)))
                .offset(
                    x: 60 + (layer3Animate ? 25 : -25),
                    y: -10 + (layer3Animate ? -20 : 20)
                )
                .blur(radius: 40)
        }
        .onAppear {
            // Layer 1: Slowest - 9s drift, 12s scale, 15s rotation
            withAnimation(
                .easeInOut(duration: 9)
                .repeatForever(autoreverses: true)
            ) {
                layer1Animate = true
            }

            // Layer 2: Medium - 7s timing, offset start for organic feel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(
                    .easeInOut(duration: 7)
                    .repeatForever(autoreverses: true)
                ) {
                    layer2Animate = true
                }
            }

            // Layer 3: Fastest - 6s timing, different offset
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(
                    .easeInOut(duration: 6)
                    .repeatForever(autoreverses: true)
                ) {
                    layer3Animate = true
                }
            }
        }
    }
}

// MARK: - Language Card

struct LanguageCard: View {
    let language: LanguageOption
    let isSelected: Bool
    let action: () -> Void

    private func triggerHaptic() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
    }

    var body: some View {
        Button(action: {
            triggerHaptic()
            action()
        }) {
            ZStack {
                // Card background with glassmorphism
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(isSelected ? 1.0 : 0.9),
                                Color.white.opacity(isSelected ? 0.85 : 0.7),
                                Color.white.opacity(isSelected ? 0.6 : 0.4)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 0.98, green: 0.43, blue: 0.85).opacity(0.4),
                                        Color(red: 1.0, green: 0.71, blue: 0.45).opacity(0.3)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isSelected ? AppColors.claudeDeepOrange : Color.clear,
                                lineWidth: 2
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(isSelected ? 0.3 : 0.6),
                                        Color.white.opacity(isSelected ? 0.1 : 0.2)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)

                // Inner glow effect
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 0.45, green: 0.55, blue: 0.96).opacity(0.3),
                                        Color.clear
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .blur(radius: 4)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Content
                VStack(alignment: .leading, spacing: 0) {
                    // Flag emoji
                    Text(language.flag)
                        .font(AppTypography.emojiSize)
                        .offset(y: -4)  // Move flag up 4px
                        .padding(.bottom, 68)

                    // Language name
                    Text(language.displayName)
                        .font(.system(size: 20, weight: .medium))
                        .tracking(0.48)
                        .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                        .padding(.bottom, 6)

                    // Abbreviation
                    Text(language.abbreviation)
                        .font(.system(size: 15, weight: .regular))
                        .tracking(0.33)
                        .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(width: 168, height: 212)
            // Selected state shadows - always present, opacity controlled by isSelected
            .shadow(color: Color(hex: "B85C38").opacity(isSelected ? 0.15 : 0), radius: 10, x: 0, y: 0)
            .shadow(color: Color(hex: "E8714E").opacity(isSelected ? 0.50 : 0), radius: 16, x: 0, y: 0)
            .shadow(color: Color(hex: "0C0C0D").opacity(isSelected ? 0.05 : 0), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeOut(duration: 0.3), value: isSelected)
    }
}

// MARK: - Conditional Modifier Extension

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - English Selected Screen

struct EnglishSelectedScreen: View {
    @ObservedObject var onboardingState: OnboardingState
    var onBackTapped: (() -> Void)?
    var onTranslationStart: ((String) -> Void)?  // Pass room_id to start translation

    @State private var currentScreen: GetStartedScreenState = .pairing(direction: "en_to_kr")

    private var selectedCard: String? {
        switch onboardingState.selectedSessionMode {
        case .create: return "create"
        case .join: return "join"
        case nil: return nil
        }
    }

    enum GetStartedScreenState: Equatable {
        case selection
        case pairing(direction: String)
        case manualPairing(roomCode: String)
        case success(roomId: String)
        case liveTranslation(roomId: String)
    }

    var body: some View {
        ZStack {
            // Selection screen
            if currentScreen == .selection {
                ZStack {
                    // Heading and body - positioned from top
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Let's get you connected.")
                            .font(AppTypography.h2)
                            .lineSpacing(39 - 28)  // line height 39, font size 28
                            .tracking(0.672)
                            .foregroundColor(AppColors.primaryText)

                        Text("Choose one, and your partner will pick\nthe other.")
                            .font(AppTypography.b2)
                            .foregroundColor(AppColors.primaryText)
                            .lineSpacing(22 - 17)
                            .tracking(0.37)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                    .padding(.trailing, 20)
                    .padding(.top, AppSpacing.welcomeContentStart - 8)
                    .frame(maxHeight: .infinity, alignment: .top)

                    // Get started cards - same position as page 1
                    VStack {
                        HStack(spacing: AppSpacing.betweenCards) {
                            GetStartedCard(
                                icon: "user-circle-plus",
                                title: "Create\nSession",
                                subtitle: "Share a code",
                                isSelected: selectedCard == "create",
                                iconTopOffset: 8  // Move icon down 8px
                            ) {
                                onboardingState.selectedSessionMode = .create
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation(.easeInOut(duration: 0.4)) {
                                        currentScreen = .manualPairing(roomCode: "")
                                    }
                                }
                            }

                            GetStartedCard(
                                icon: "users",
                                title: "Join\nSession",
                                subtitle: "Scan a code",
                                isSelected: selectedCard == "join",
                                iconTopOffset: 4  // Move icon down 4px
                            ) {
                                onboardingState.selectedSessionMode = .join
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation(.easeInOut(duration: 0.4)) {
                                        currentScreen = .manualPairing(roomCode: "")
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)

                        Spacer()
                    }
                    .padding(.top, AppSpacing.cardsFromTop)

                    // Back button - top left
                    VStack {
                        HStack {
                            BackButton {
                                onBackTapped?()
                            }
                            Spacer()
                        }
                        .padding(.leading, 20)
                        .padding(.top, 40)

                        Spacer()
                    }
                }
                .transition(.opacity)
            }

            // Pairing screen
            if case .pairing(let direction) = currentScreen {
                PairingScreen(
                    direction: direction,
                    onBackTapped: {
                        // Go back to language selection
                        onBackTapped?()
                    },
                    onManualPairing: { roomCode in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .selection  // Go to Create/Join selection when auto-pairing fails
                        }
                    },
                    onSuccess: { roomId in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .success(roomId: roomId)
                        }
                    }
                )
                .transition(.opacity)
            }

            // Manual pairing screen
            if case .manualPairing(let roomCode) = currentScreen {
                ManualPairingScreen(
                    sessionMode: onboardingState.selectedSessionMode ?? .create,
                    roomCode: roomCode,
                    onBackTapped: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .selection  // Go back to Create/Join selection
                        }
                    },
                    onSuccess: { roomId in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .success(roomId: roomId)
                        }
                    }
                )
                .transition(.opacity)
            }

            // Success screen
            if case .success(let roomId) = currentScreen {
                SetupSuccessScreen(
                    roomId: roomId,
                    onProceed: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .liveTranslation(roomId: roomId)
                        }
                    },
                    onBackTapped: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .pairing(direction: onboardingState.selectedSessionMode == .create ? "en_to_kr" : "kr_to_en")
                        }
                    }
                )
                .transition(.opacity)
            }

            // Live Translation screen (English user)
            if case .liveTranslation(let roomId) = currentScreen {
                LiveTranslationScreen(roomId: roomId, language: "en")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Korean Selected Screen

struct KoreanSelectedScreen: View {
    @ObservedObject var onboardingState: OnboardingState
    var onBackTapped: (() -> Void)?
    var onTranslationStart: ((String) -> Void)?

    @State private var currentScreen: GetStartedScreenState = .pairing(direction: "kr_to_en")

    private var selectedCard: String? {
        switch onboardingState.selectedSessionMode {
        case .create: return "create"
        case .join: return "join"
        case nil: return nil
        }
    }

    enum GetStartedScreenState: Equatable {
        case selection
        case pairing(direction: String)
        case manualPairing(roomCode: String)
        case success(roomId: String)
        case liveTranslation(roomId: String)
    }

    var body: some View {
        ZStack {
            // Selection screen
            if currentScreen == .selection {
                ZStack {
                    // Heading and body - positioned from top (Korean)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("연결해 드릴게요.")
                            .font(AppTypography.h2Korean)
                            .lineSpacing(38 - 28)
                            .tracking(0.672)
                            .foregroundColor(AppColors.primaryText)

                        Text("둘 중 하나를 고르세요. 상대방은 나머지를\n선택하면 돼요.")
                            .font(AppTypography.b2Korean)
                            .foregroundColor(AppColors.primaryText)
                            .lineSpacing(22 - 17)
                            .tracking(0.37)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                    .padding(.trailing, 20)
                    .padding(.top, AppSpacing.welcomeContentStart - 8)
                    .frame(maxHeight: .infinity, alignment: .top)

                    // Get started cards - same position as page 1
                    VStack {
                        HStack(spacing: AppSpacing.betweenCards) {
                            GetStartedCard(
                                icon: "user-circle-plus",
                                title: "세션 만들기",
                                subtitle: "코드 공유",
                                isSelected: selectedCard == "create",
                                iconTopOffset: 8  // Move icon down 8px
                            ) {
                                onboardingState.selectedSessionMode = .create
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation(.easeInOut(duration: 0.4)) {
                                        currentScreen = .manualPairing(roomCode: "")
                                    }
                                }
                            }

                            GetStartedCard(
                                icon: "users",
                                title: "세션 참여",
                                subtitle: "코드 스캔",
                                isSelected: selectedCard == "join",
                                iconTopOffset: 4  // Move icon down 4px
                            ) {
                                onboardingState.selectedSessionMode = .join
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation(.easeInOut(duration: 0.4)) {
                                        currentScreen = .manualPairing(roomCode: "")
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)

                        Spacer()
                    }
                    .padding(.top, AppSpacing.cardsFromTop)

                    // Back button - top left
                    VStack {
                        HStack {
                            BackButton {
                                onBackTapped?()
                            }
                            Spacer()
                        }
                        .padding(.leading, 20)
                        .padding(.top, 40)

                        Spacer()
                    }
                }
                .transition(.opacity)
            }

            // Pairing screen (Korean)
            if case .pairing(let direction) = currentScreen {
                PairingScreenKorean(
                    direction: direction,
                    onBackTapped: {
                        // Go back to language selection
                        onBackTapped?()
                    },
                    onManualPairing: { roomCode in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .selection  // Go to Create/Join selection when auto-pairing fails
                        }
                    },
                    onSuccess: { roomId in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .success(roomId: roomId)
                        }
                    }
                )
                .transition(.opacity)
            }

            // Manual pairing screen (Korean)
            if case .manualPairing(let roomCode) = currentScreen {
                ManualPairingScreenKorean(
                    sessionMode: onboardingState.selectedSessionMode ?? .create,
                    roomCode: roomCode,
                    onBackTapped: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .selection  // Go back to Create/Join selection
                        }
                    },
                    onSuccess: { roomId in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .success(roomId: roomId)
                        }
                    }
                )
                .transition(.opacity)
            }

            // Success screen (Korean)
            if case .success(let roomId) = currentScreen {
                SetupSuccessScreenKorean(
                    roomId: roomId,
                    onProceed: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .liveTranslation(roomId: roomId)
                        }
                    },
                    onBackTapped: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .pairing(direction: onboardingState.selectedSessionMode == .create ? "kr_to_en" : "en_to_kr")
                        }
                    }
                )
                .transition(.opacity)
            }

            // Live Translation screen (Korean user)
            if case .liveTranslation(let roomId) = currentScreen {
                LiveTranslationScreen(roomId: roomId, language: "kr")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Get Started Card

struct GetStartedCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    var iconTopOffset: CGFloat = 0  // Additional offset to move icon down
    let action: () -> Void

    private func triggerHaptic() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
    }

    var body: some View {
        Button(action: {
            triggerHaptic()
            action()
        }) {
            ZStack {
                // Card background with glassmorphism
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(isSelected ? 1.0 : 0.9),
                                Color.white.opacity(isSelected ? 0.85 : 0.7),
                                Color.white.opacity(isSelected ? 0.6 : 0.4)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 0.98, green: 0.43, blue: 0.85).opacity(0.4),
                                        Color(red: 1.0, green: 0.71, blue: 0.45).opacity(0.3)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isSelected ? AppColors.claudeDeepOrange : Color.clear,
                                lineWidth: 2
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(isSelected ? 0.3 : 0.6),
                                        Color.white.opacity(isSelected ? 0.1 : 0.2)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)

                // Inner glow effect
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 0.45, green: 0.55, blue: 0.96).opacity(0.3),
                                        Color.clear
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .blur(radius: 4)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Content - icon at top, title/subtitle at bottom (title grows up)
                VStack(alignment: .leading, spacing: 0) {
                    // Icon at top
                    Image(icon)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(AppColors.primaryIconOnMedia)
                        .frame(width: 44, height: 44)
                        .padding(.top, iconTopOffset)

                    Spacer()

                    // Title - grows upward from subtitle
                    Text(title)
                        .font(AppTypography.b1)
                        .tracking(0.48)
                        .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                        .lineSpacing(24 - 20)
                        .padding(.bottom, 6)

                    // Subtitle - fixed at bottom
                    Text(subtitle)
                        .font(.system(size: 15, weight: .regular))
                        .tracking(0.33)
                        .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(width: 168, height: 212)
            // Selected state shadows
            .shadow(color: Color(hex: "B85C38").opacity(isSelected ? 0.15 : 0), radius: 10, x: 0, y: 0)
            .shadow(color: Color(hex: "E8714E").opacity(isSelected ? 0.50 : 0), radius: 16, x: 0, y: 0)
            .shadow(color: Color(hex: "0C0C0D").opacity(isSelected ? 0.05 : 0), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeOut(duration: 0.3), value: isSelected)
    }
}

// MARK: - Back Button

struct BackButton: View {
    let action: () -> Void

    var body: some View {
        GlassCircleButton(icon: "chevron.left") {
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
            action()
        }
    }
}

// MARK: - Looking For Partner Screen

struct LookingForPartnerScreen: View {
    var onBackTapped: (() -> Void)?
    var onProceed: (() -> Void)?

    @State private var hasProceeded = false

    // DEBUG: Toggle for simulator testing - remove before shipping
    @State private var debugOverride: Bool? = nil

    var body: some View {
        ZStack {
            // Background
            AppColors.background
                .ignoresSafeArea()

            // Gradient orb decoration
            GradientOrb()
                .frame(width: 400, height: 350)
                .rotationEffect(.degrees(-80))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 20, y: -238)

            // Content
            VStack(alignment: .leading, spacing: 0) {
                // Title
                Text("Looking for your partner...")
                    .font(AppTypography.h2)
                    .lineSpacing(39 - 28)
                    .tracking(0.672)
                    .foregroundColor(AppColors.primaryText)

                // Loading dots - 12px below title
                BouncingDots()
                    .padding(.top, 12)

                // Subtitle
                Text("You'll both need the same WiFi\nand a pair of headphones.")
                    .font(AppTypography.b2)
                    .foregroundColor(AppColors.primaryText)
                    .lineSpacing(22 - 17)
                    .tracking(0.37)
                    .padding(.top, 24)

                // Headphone status card with real-time detection
                HeadphoneStatusCard(
                    onConnectionChange: { isConnected in
                        handleConnectionChange(isConnected)
                    },
                    debugOverride: debugOverride
                )
                .padding(.top, 32)

                Spacer()
            }
            .padding(.leading, 20)
            .padding(.top, AppSpacing.welcomeContentStart - 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Back button - top left
            VStack {
                HStack {
                    BackButton {
                        onBackTapped?()
                    }
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.top, 40)

                Spacer()
            }

            // DEBUG: Toggle button - remove before shipping
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: {
                        if debugOverride == nil {
                            debugOverride = true
                        } else if debugOverride == true {
                            debugOverride = false
                        } else {
                            debugOverride = nil
                        }
                    }) {
                        Text("🎧 \(debugStateLabel)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.6))
                            )
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 40)
                }
            }
        }
    }

    private var debugStateLabel: String {
        switch debugOverride {
        case .none: return "AUTO"
        case .some(true): return "ON"
        case .some(false): return "OFF"
        }
    }

    private func handleConnectionChange(_ isConnected: Bool) {
        guard isConnected && !hasProceeded else { return }

        // Wait 2 seconds then proceed
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard !hasProceeded else { return }
            hasProceeded = true
            print("Proceeding...")
            onProceed?()
        }
    }
}

// MARK: - Loading Dots

struct BouncingDots: View {
    @State private var animating = [false, false, false]

    private let dotSize: CGFloat = 10
    private let bounceHeight: CGFloat = 6
    private let dotSpacing: CGFloat = 12
    private let staggerDelay: Double = 0.15
    private let pauseDuration: Double = 0.5

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<3, id: \.self) { index in
                LoaderDot(dotSize: dotSize)
                    .offset(y: animating[index] ? -bounceHeight : 0)
                    .animation(
                        .spring(
                            response: 0.45,
                            dampingFraction: 0.55,
                            blendDuration: 0.1
                        ),
                        value: animating[index]
                    )
            }
        }
        .onAppear {
            // Initial pause before starting
            DispatchQueue.main.asyncAfter(deadline: .now() + pauseDuration) {
                animateLoop()
            }
        }
    }

    private func animateLoop() {
        // Each dot bounces independently with stagger
        for i in 0..<3 {
            let delay = Double(i) * staggerDelay

            // Bounce up
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                animating[i] = true
            }

            // Bounce down
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.4) {
                animating[i] = false
            }
        }

        // Wait for all dots to finish, then pause and repeat
        let totalCycleTime = (2 * staggerDelay) + 0.4 + 0.5 // last dot up + down time
        DispatchQueue.main.asyncAfter(deadline: .now() + totalCycleTime + pauseDuration) {
            animateLoop()
        }
    }
}

// MARK: - Loader Dot

struct LoaderDot: View {
    let dotSize: CGFloat

    private let baseColor = Color(red: 232/255, green: 115/255, blue: 74/255) // #E8734A
    private let shadowTint = Color(red: 39/255, green: 39/255, blue: 39/255)  // #272727

    var body: some View {
        ZStack {
            // Base circle with drop shadow
            Circle()
                .fill(baseColor)
                .frame(width: dotSize, height: dotSize)
                .shadow(color: shadowTint.opacity(0.05), radius: 12, x: 0, y: 8)

            // Inner highlight stroke (top-left lit edge)
            Circle()
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.35), location: 0.0),
                            .init(color: Color.white.opacity(0.15), location: 0.3),
                            .init(color: Color.clear, location: 0.5)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .frame(width: dotSize, height: dotSize)

            // Inner shadow stroke (bottom-right edge depth)
            Circle()
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.clear, location: 0.5),
                            .init(color: shadowTint.opacity(0.08), location: 0.7),
                            .init(color: shadowTint.opacity(0.12), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .frame(width: dotSize, height: dotSize)
        }
    }
}

// MARK: - Headphone Status Card

struct HeadphoneStatusCard: View {
    @StateObject private var detector = HeadphoneDetector()
    var onConnectionChange: ((Bool) -> Void)?

    // DEBUG: Override for simulator testing - remove before shipping
    var debugOverride: Bool? = nil

    private var isConnected: Bool {
        debugOverride ?? detector.isConnected
    }

    private func triggerHaptic() {
        #if os(iOS)
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        #endif
    }

    private func openBluetoothSettings() {
        #if os(iOS)
        if let url = URL(string: "App-Prefs:root=Bluetooth") {
            UIApplication.shared.open(url)
        }
        #endif
    }

    var body: some View {
        Button(action: {
            if !isConnected {
                triggerHaptic()
                openBluetoothSettings()
            }
        }) {
            ZStack {
                // Card background with glassmorphism (same as GetStartedCard)
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.9),
                                Color.white.opacity(0.7),
                                Color.white.opacity(0.4)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 0.98, green: 0.43, blue: 0.85).opacity(0.4),
                                        Color(red: 1.0, green: 0.71, blue: 0.45).opacity(0.3)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(0.6),
                                        Color.white.opacity(0.2)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)

                // Inner glow effect
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 0.45, green: 0.55, blue: 0.96).opacity(0.3),
                                        Color.clear
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .blur(radius: 4)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Content - icon at top, title/subtitle at bottom (same layout as GetStartedCard)
                VStack(alignment: .leading, spacing: 0) {
                    // Icon at top
                    Image(isConnected ? "headphones-connected-color" : "not-connected-headphones-color")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 60)

                    Spacer()

                    // Title - grows upward from subtitle
                    Text(isConnected ? "Headphones connected" : "No headphones connected")
                        .font(AppTypography.b1)
                        .tracking(0.48)
                        .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                        .padding(.bottom, 6)

                    // Subtitle - fixed at bottom
                    Text(isConnected ? "You're ready to go!" : "Tap here to connect them now")
                        .font(AppTypography.b3)
                        .tracking(0.33)
                        .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.7))
                    // Optional chevron for "not connected" state:
                    // HStack(alignment: .center, spacing: 4) {
                    //     Text("Tap here to connect them now")
                    //         .font(AppTypography.b3)
                    //         .tracking(0.33)
                    //         .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.7))
                    //     Image(systemName: "chevron.right")
                    //         .font(.system(size: 12, weight: .medium))
                    //         .foregroundColor(AppColors.secondaryIcon)
                    //         .frame(width: 14, height: 14)
                    // }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)  // Auto-fill available width
        }
        .buttonStyle(PlainButtonStyle())
        .allowsHitTesting(!isConnected)
        .animation(.easeInOut(duration: 0.3), value: isConnected)
        .onChange(of: detector.isConnected) { _, newValue in
            onConnectionChange?(newValue)
        }
    }
}

// MARK: - Session Card

struct SessionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var isPressed = false

    private func triggerHaptic() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
    }

    var body: some View {
        Button(action: {
            triggerHaptic()
            action()
        }) {
            ZStack {
                // Card background with glassmorphism
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.9),
                                Color.white.opacity(0.7),
                                Color.white.opacity(0.4)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 0.98, green: 0.43, blue: 0.85).opacity(0.4),
                                        Color(red: 1.0, green: 0.71, blue: 0.45).opacity(0.3)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(0.6),
                                        Color.white.opacity(0.2)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)

                // Inner glow effect
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 0.45, green: 0.55, blue: 0.96).opacity(0.3),
                                        Color.clear
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .blur(radius: 4)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Content
                VStack(alignment: .leading, spacing: 0) {
                    // Icon
                    Image(systemName: icon)
                        .font(.system(size: 32, weight: .regular))
                        .foregroundColor(AppColors.claudeOrange)
                        .frame(width: 60, height: 60)
                        .padding(.bottom, 44)

                    // Title
                    Text(title)
                        .font(.system(size: 20, weight: .medium))
                        .tracking(0.48)
                        .foregroundColor(AppColors.primaryText)
                        .lineSpacing(24 - 20)
                        .padding(.bottom, 6)

                    // Subtitle
                    Text(subtitle)
                        .font(.system(size: 15, weight: .regular))
                        .tracking(0.33)
                        .foregroundColor(AppColors.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(width: 168, height: 212)
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.easeOut(duration: 0.3), value: isPressed)
    }
}

// MARK: - Preview

#Preview {
    WelcomeScreenLangSelect()
}
