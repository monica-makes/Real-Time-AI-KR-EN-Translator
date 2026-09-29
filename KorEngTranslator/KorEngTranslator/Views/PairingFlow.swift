import SwiftUI
import UIKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import Combine

// MARK: - Keyboard Observer

class KeyboardObserver: ObservableObject {
    @Published var keyboardHeight: CGFloat = 0
    @Published var isKeyboardVisible: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .compactMap { notification -> CGFloat? in
                (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.25)) {
                        self?.keyboardHeight = height
                        self?.isKeyboardVisible = true
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.25)) {
                        self?.keyboardHeight = 0
                        self?.isKeyboardVisible = false
                    }
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - UIKit TextField for Reliable Keyboard Focus

struct UIKitTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool
    var onDigitEntered: (() -> Void)?
    var onComplete: (() -> Void)?
    var onTextChange: ((_ oldValue: String, _ newValue: String) -> Void)?

    // Static reference to allow direct focus triggering
    static var currentTextField: UITextField?

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.keyboardType = .numberPad
        tf.textContentType = .oneTimeCode
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.textChanged), for: .editingChanged)

        // Make invisible but still functional
        tf.alpha = 0.01
        tf.tintColor = .clear

        // Store references
        context.coordinator.textField = tf
        UIKitTextField.currentTextField = tf

        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // Keep static reference updated
        UIKitTextField.currentTextField = uiView

        if uiView.text != text {
            uiView.text = text
        }

        // Handle focus state changes
        if isFirstResponder && !uiView.isFirstResponder {
            // Delay slightly to ensure view is in hierarchy
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        } else if !isFirstResponder && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // Call this to directly focus the text field
    static func focus() {
        DispatchQueue.main.async {
            currentTextField?.becomeFirstResponder()
        }
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: UIKitTextField
        weak var textField: UITextField?
        private var previousText = ""

        init(_ parent: UIKitTextField) {
            self.parent = parent
            self.previousText = parent.text
        }

        @objc func textChanged(_ tf: UITextField) {
            let filtered = String((tf.text ?? "").filter { $0.isNumber }.prefix(6))
            let oldValue = previousText

            if filtered.count > previousText.count {
                parent.onDigitEntered?()
            }
            previousText = filtered

            parent.onTextChange?(oldValue, filtered)
            parent.text = filtered
            tf.text = filtered

            if filtered.count == 6 {
                parent.onComplete?()
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                self.parent.isFirstResponder = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                self.parent.isFirstResponder = false
            }
        }
    }
}

// MARK: - Session Mode

enum SessionMode: Equatable {
    case create  // User shows QR code / numeric code for partner to scan/enter
    case join    // User scans QR code or enters numeric code
}

// MARK: - Onboarding State (persists selections)

class OnboardingState: ObservableObject {
    @Published var selectedLanguage: LanguageOption? = nil
    @Published var selectedSessionMode: SessionMode? = nil
}

// MARK: - Room Code Manager (for code generation and validation)

class RoomCodeManager: ObservableObject {
    /// Shared instance for cross-language code sharing (English Create ↔ Korean Join)
    static let shared = RoomCodeManager()

    @Published var generatedRoomCode: String = ""

    /// Track which language generated the code (for cross-language pairing)
    @Published var generatorLanguage: String = ""  // "en" or "ko"

    /// Generate a new 6-digit numeric room code
    func generateNewCode(language: String = "en") {
        generatedRoomCode = (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
        generatorLanguage = language
    }

    /// Validate entered code against the generated code
    func validateCode(_ enteredCode: String) -> Bool {
        // In production, this would validate against server
        // For now, validate against locally generated code (for debug/demo)
        return enteredCode == generatedRoomCode && !generatedRoomCode.isEmpty
    }

    /// Clear the generated code
    func clearCode() {
        generatedRoomCode = ""
        generatorLanguage = ""
    }
}

// MARK: - Pairing State Enum

enum PairingState {
    case searching           // Connecting to server, checking headphones
    case waitingForPartner   // Connected, waiting for partner to connect + have headphones
    case partnerConnected    // Partner connected but no headphones yet
    case matched             // Both connected, both have headphones, WiFi matched
}

// MARK: - Partner Status

enum PartnerStatus {
    case waiting
    case connectedNoHeadphones
    case ready
}

// MARK: - Pairing WebSocket Manager

class PairingWebSocketManager: ObservableObject {
    @Published var pairingState: PairingState = .searching
    @Published var partnerStatus: PartnerStatus = .waiting
    @Published var roomId: String?
    @Published var roomCode: String?
    @Published var isConnected = false
    @Published var shouldNavigateToManual = false
    @Published var shouldNavigateToSuccess = false
    @Published var connectionTimedOut = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var direction: String
    private var connectionTimeoutTask: Task<Void, Never>?

    init(direction: String = "ko_to_en") {
        self.direction = direction
    }

    /// - Parameter serverIP: Optional host override (defaults to ServerConfig.host)
    func connect(serverIP: String? = nil, timeoutSeconds: Double = 8.0) {
        let urlString = ServerConfig.pairURL(direction: direction, host: serverIP)
        print("[PairingWS] Connecting to: \(urlString)")
        guard let url = URL(string: urlString) else {
            print("[PairingWS] Invalid URL")
            handleConnectionFailure()
            return
        }

        disconnect()

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        urlSession = session

        // Start connection timeout
        connectionTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            await MainActor.run {
                if !self.isConnected && !self.shouldNavigateToSuccess {
                    print("[PairingWS] Connection timeout after \(timeoutSeconds)s")
                    self.handleConnectionFailure()
                }
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                if self.webSocketTask?.state == .running {
                    self.isConnected = true
                    self.pairingState = .waitingForPartner
                    // Cancel timeout since we connected
                    // But keep timeout for partner matching
                }
            }
        }

        receiveMessage()
    }

    private func handleConnectionFailure() {
        connectionTimedOut = true
        // Generate a room code for manual pairing
        roomCode = String(format: "%06d", Int.random(in: 0...999999))
        shouldNavigateToManual = true
    }

    func disconnect() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
    }

    func sendHeadphoneStatus(connected: Bool) {
        guard isConnected else { return }

        let message = ["type": "headphone_status", "connected": connected] as [String: Any]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                print("[PairingWS] Send error: \(error)")
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                self?.handleReceiveResult(result)
            }
        }
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            if case .string(let text) = message {
                handleTextMessage(text)
            }
            receiveMessage()

        case .failure(let error):
            print("[PairingWS] Receive error: \(error)")
            isConnected = false
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "searching":
            pairingState = .searching
            partnerStatus = .waiting

        case "partner_connected":
            let hasHeadphones = json["headphones"] as? Bool ?? false
            pairingState = .partnerConnected
            partnerStatus = hasHeadphones ? .ready : .connectedNoHeadphones

        case "partner_ready":
            partnerStatus = .ready

        case "matched":
            roomId = json["room_id"] as? String
            pairingState = .matched
            shouldNavigateToSuccess = true

        case "no_match":
            roomCode = json["room_code"] as? String
            shouldNavigateToManual = true

        default:
            print("[PairingWS] Unknown message type: \(type)")
        }
    }
}

// MARK: - Headphone Monitor

class HeadphoneMonitor: ObservableObject {
    @Published var isConnected = false

    init() {
        checkHeadphones()
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        #endif
    }

    func checkHeadphones() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        isConnected = session.currentRoute.outputs.contains { output in
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(output.portType)
        }
        #endif
    }

    @objc private func routeChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            self.checkHeadphones()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Screen 1: PairingScreen

struct PairingScreen: View {
    var direction: String = "ko_to_en"
    var onBackTapped: (() -> Void)?
    var onManualPairing: ((String) -> Void)?  // Pass room code
    var onSuccess: ((String) -> Void)?        // Pass room id

    @StateObject private var pairingManager = PairingWebSocketManager()
    @StateObject private var headphoneMonitor = HeadphoneMonitor()

    // Headphone reminder alert
    @State private var showHeadphoneAlert = false
    @State private var hasShownHeadphoneAlert = false
    @State private var headphoneAlertTimer: Timer? = nil

    // DEBUG: Mode toggle for simulator testing
    #if DEBUG
    @State private var debugMode = true  // Start in debug mode for simulator
    @State private var debugHeadphonesConnected = false
    #endif

    private var effectiveHeadphoneStatus: Bool {
        #if DEBUG
        if debugMode {
            return debugHeadphonesConnected
        }
        #endif
        return headphoneMonitor.isConnected
    }

    var body: some View {
        ZStack {
            // Content (background and gradient provided by parent WelcomeScreenLangSelect)
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

                // Headphone status card - 32px below subtitle
                PairingHeadphoneStatusCard(
                    isConnected: effectiveHeadphoneStatus,
                    onTap: {
                        openBluetoothSettings()
                    }
                )
                .padding(.top, 32)

                Spacer()
            }
            .padding(.leading, 20)
            .padding(.top, AppSpacing.welcomeContentStart - 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Back button
            VStack {
                HStack {
                    BackButton {
                        pairingManager.disconnect()
                        onBackTapped?()
                    }
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.top, 40)
                Spacer()
            }

            // DEBUG: Explicit controls panel at bottom
            #if DEBUG
            VStack {
                Spacer()
                debugControlsPanel
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }
            #endif
        }
        .onAppear {
            #if DEBUG
            if !debugMode {
                pairingManager.connect()
                startHeadphoneAlertTimer()
            }
            #else
            pairingManager.connect()
            startHeadphoneAlertTimer()
            #endif
        }
        .onDisappear {
            pairingManager.disconnect()
            headphoneAlertTimer?.invalidate()
            headphoneAlertTimer = nil
        }
        .onChange(of: headphoneMonitor.isConnected) { _, newValue in
            #if DEBUG
            if !debugMode {
                pairingManager.sendHeadphoneStatus(connected: newValue)
            }
            #else
            pairingManager.sendHeadphoneStatus(connected: newValue)
            #endif

            // If headphones connected, cancel alert timer
            if newValue {
                headphoneAlertTimer?.invalidate()
                headphoneAlertTimer = nil
            }
        }
        .onChange(of: pairingManager.partnerStatus) { _, newStatus in
            // Show alert immediately if partner is ready but we don't have headphones
            if newStatus == .ready && !effectiveHeadphoneStatus {
                showHeadphoneAlertIfNeeded()
            }
        }
        .onChange(of: pairingManager.shouldNavigateToManual) { _, shouldNavigate in
            if shouldNavigate, let code = pairingManager.roomCode {
                onManualPairing?(code)
            }
        }
        .onChange(of: pairingManager.shouldNavigateToSuccess) { _, shouldNavigate in
            if shouldNavigate, let roomId = pairingManager.roomId {
                onSuccess?(roomId)
            }
        }
        .alert("Connect Your Headphones", isPresented: $showHeadphoneAlert) {
            Button("Open Settings") {
                openBluetoothSettings()
            }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("You'll need headphones to hear the live translation.")
        }
    }

    // MARK: - Headphone Alert Logic

    private func startHeadphoneAlertTimer() {
        // Only start timer if headphones not already connected
        guard !effectiveHeadphoneStatus else { return }

        headphoneAlertTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
            DispatchQueue.main.async {
                // Show alert after 10 seconds if headphones still not connected
                if !effectiveHeadphoneStatus {
                    showHeadphoneAlertIfNeeded()
                }
            }
        }
    }

    private func showHeadphoneAlertIfNeeded() {
        // Only show once per session
        guard !hasShownHeadphoneAlert else { return }
        guard !effectiveHeadphoneStatus else { return }

        hasShownHeadphoneAlert = true
        showHeadphoneAlert = true
    }

    #if DEBUG
    private var debugControlsPanel: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "ladybug.fill")
                    .foregroundColor(.orange)
                Text("Debug Controls")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("", isOn: $debugMode)
                    .toggleStyle(SwitchToggleStyle(tint: .orange))
                    .labelsHidden()
                    .onChange(of: debugMode) { _, newValue in
                        if newValue {
                            pairingManager.disconnect()
                        } else {
                            pairingManager.connect()
                        }
                    }
            }

            if debugMode {
                // Headphones Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("HEADPHONES")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Button(action: { debugHeadphonesConnected = true }) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Paired")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(debugHeadphonesConnected ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(debugHeadphonesConnected ? Color.green : Color.gray.opacity(0.2))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())

                        Button(action: { debugHeadphonesConnected = false }) {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                Text("Not Paired")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(!debugHeadphonesConnected ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(!debugHeadphonesConnected ? Color.red : Color.gray.opacity(0.2))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                // WiFi Connection Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("WIFI CONNECTION RESULT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Button(action: {
                            // If headphones not connected, show alert first
                            if !debugHeadphonesConnected {
                                showHeadphoneAlertIfNeeded()
                            } else {
                                onSuccess?("DEBUG-ROOM-123")
                            }
                        }) {
                            HStack {
                                Image(systemName: "wifi")
                                Text("Success")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.green)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())

                        Button(action: {
                            onManualPairing?("208098")
                        }) {
                            HStack {
                                Image(systemName: "wifi.slash")
                                Text("Failed")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.orange)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                // Headphone Alert Test
                Button(action: {
                    hasShownHeadphoneAlert = false  // Reset for testing
                    showHeadphoneAlertIfNeeded()
                }) {
                    HStack {
                        Image(systemName: "headphones")
                        Text("Show Headphone Alert")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                // Live mode status
                HStack {
                    Circle()
                        .fill(pairingManager.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(pairingManager.isConnected ? "Connected to server" : "Connecting... (8s timeout)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    #endif

    private func openBluetoothSettings() {
        #if os(iOS)
        if let url = URL(string: "App-Prefs:root=Bluetooth") {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

// MARK: - Pairing Headphone Status Card (matches original design)

struct PairingHeadphoneStatusCard: View {
    let isConnected: Bool
    var onTap: (() -> Void)?

    private func triggerHaptic() {
        #if os(iOS)
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        #endif
    }

    var body: some View {
        Button(action: {
            if !isConnected {
                triggerHaptic()
                onTap?()
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(width: 353, height: 184)
        }
        .buttonStyle(PlainButtonStyle())
        .allowsHitTesting(!isConnected)
        .animation(.easeInOut(duration: 0.3), value: isConnected)
    }
}

// Korean version of PairingHeadphoneStatusCard
struct PairingHeadphoneStatusCardKorean: View {
    let isConnected: Bool
    var onTap: (() -> Void)?

    private func triggerHaptic() {
        #if os(iOS)
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        #endif
    }

    var body: some View {
        Button(action: {
            if !isConnected {
                triggerHaptic()
                onTap?()
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

                // Content - icon at top, title/subtitle at bottom
                VStack(alignment: .leading, spacing: 0) {
                    // Icon at top
                    Image(isConnected ? "headphones-connected-color" : "not-connected-headphones-color")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 60)

                    Spacer()

                    // Title - Korean
                    Text(isConnected ? "헤드폰 연결됨" : "헤드폰이 연결되지 않았어요")
                        .font(AppTypography.b1Korean)
                        .tracking(0.48)
                        .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                        .padding(.bottom, 6)

                    // Subtitle - Korean
                    Text(isConnected ? "준비 완료!" : "여기를 눌러 연결하세요")
                        .font(AppTypography.b3Korean)
                        .lineSpacing(21 - 14)  // line height 21
                        .tracking(0.33)
                        .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(width: 353, height: 184)
        }
        .buttonStyle(PlainButtonStyle())
        .allowsHitTesting(!isConnected)
        .animation(.easeInOut(duration: 0.3), value: isConnected)
    }
}

// MARK: - Screen 2: ManualPairingScreen

struct ManualPairingScreen: View {
    let sessionMode: SessionMode
    let roomCode: String  // For create mode: the code to display. For join mode: ignored initially
    var onBackTapped: (() -> Void)?
    var onSuccess: ((String) -> Void)?
    var onSwitchToKoreanJoin: (() -> Void)?  // Debug: Switch to Korean Join screen

    @State private var showCopiedFeedback = false
    @State private var enteredCode: String = ""
    @State private var isConnecting = false
    @State private var showError = false  // Controls error text display
    @State private var showErrorGlow = false  // Controls red glow on boxes (fades after 1s)
    @State private var isCodeFieldFocused: Bool = false  // Changed from @FocusState to @State for UIKitTextField compatibility
    @State private var shakeOffset: CGFloat = 0
    @State private var showTopGradient = false
    @State private var isAnimatingOut = false  // For coordinated digit exit animation
    @State private var cachedQRImage: UIImage? = nil  // Cached QR code to prevent flickering
    @StateObject private var qrScanner = QRScannerModel(autoStart: false)
    @StateObject private var keyboardObserver = KeyboardObserver()
    @ObservedObject private var sharedCodeManager = RoomCodeManager.shared

    // Debug mode override
    #if DEBUG
    @State private var debugSessionMode: SessionMode? = nil
    @State private var debugCollapsed = true
    @State private var debugLanguage: String = "en"  // "en" or "ko" for cross-language switching
    @State private var showPartnerJoinView = false  // Fade to Korean Join view
    #endif

    private func triggerHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        #if os(iOS)
        let impactFeedback = UIImpactFeedbackGenerator(style: style)
        impactFeedback.impactOccurred()
        #endif
    }

    private func triggerErrorHaptic() {
        #if os(iOS)
        let notificationFeedback = UINotificationFeedbackGenerator()
        notificationFeedback.notificationOccurred(.error)
        #endif
    }

    private func triggerShakeAnimation() {
        let shakeSequence: [(CGFloat, Double)] = [
            (10, 0.05), (-10, 0.05), (8, 0.05), (-8, 0.05),
            (5, 0.05), (-5, 0.05), (2, 0.05), (0, 0.05)
        ]

        var delay: Double = 0
        for (offset, duration) in shakeSequence {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.linear(duration: duration)) {
                    shakeOffset = offset
                }
            }
            delay += duration
        }
    }

    private var effectiveMode: SessionMode {
        #if DEBUG
        return debugSessionMode ?? sessionMode
        #else
        return sessionMode
        #endif
    }

    // In debug mode, Join should show Korean (partner's language)
    #if DEBUG
    private var isShowingPartnerLanguage: Bool {
        debugSessionMode == .join
    }
    #endif

    // Localized text properties for cross-language debug support
    private var titleText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "파트너를 찾을 수 없나요?"
        }
        #endif
        return "Can't find your partner?"
    }

    private var subtitleText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "다른 네트워크에 있을 수 있어요."
        }
        #endif
        return "You might be on different networks."
    }

    private var titleFont: Font {
        #if DEBUG
        if isShowingPartnerLanguage {
            return AppTypography.h2Korean
        }
        #endif
        return AppTypography.h2
    }

    private var bodyFont: Font {
        #if DEBUG
        if isShowingPartnerLanguage {
            return AppTypography.b2Korean
        }
        #endif
        return AppTypography.b2
    }

    private var h3Font: Font {
        #if DEBUG
        if isShowingPartnerLanguage {
            return AppTypography.h3Korean
        }
        #endif
        return AppTypography.h3
    }

    private var b3Font: Font {
        #if DEBUG
        if isShowingPartnerLanguage {
            return AppTypography.b3Korean
        }
        #endif
        return AppTypography.b3
    }

    // Join mode localized text
    private var scanQRText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "QR 코드를 스캔하세요:"
        }
        #endif
        return "Scan their QR code:"
    }

    private var cameraNotAvailableSimulatorText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "시뮬레이터에서 카메라를 사용할 수 없습니다"
        }
        #endif
        return "Camera not available in Simulator"
    }

    private var cameraNotAvailableText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "카메라를 사용할 수 없습니다"
        }
        #endif
        return "Camera not available"
    }

    private var manualEntryText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "스캔이 안 되나요? 코드를 입력하세요."
        }
        #endif
        return "Not scanning? Enter in their code."
    }

    private var verifyingCodeText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "코드 확인 중..."
        }
        #endif
        return "Verifying code..."
    }

    private var invalidCodeText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "잘못된 코드입니다. 다시 시도해 주세요."
        }
        #endif
        return "Invalid code. Please try again."
    }

    // Calculate the offset needed to position code boxes 32px above keyboard
    private var keyboardContentOffset: CGFloat {
        guard isCodeFieldFocused && keyboardObserver.isKeyboardVisible else { return 0 }
        // Shift content up by keyboard height minus safe area, plus 32px padding
        // The code boxes are roughly in the middle-bottom of the view
        return keyboardObserver.keyboardHeight - 32
    }

    // Background elements opacity - 90% normally, 100% when code entry is focused
    private var backgroundElementsOpacity: Double {
        isCodeFieldFocused ? 1.0 : 0.9
    }

    #if DEBUG
    private var mainContentOpacity: Double {
        showPartnerJoinView ? 0 : 1
    }
    #endif

    var body: some View {
        GeometryReader { geometry in
            let topPadding = geometry.size.height * 0.225

            ZStack {
                // Scrollable content with top gradient overlay
                // (background and gradient provided by parent WelcomeScreenLangSelect)
                ZStack(alignment: .top) {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                // Scroll position tracker and anchor for scrolling back to top
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(
                                            key: ScrollOffsetPreferenceKey.self,
                                            value: geo.frame(in: .named("manualPairingScroll")).minY
                                        )
                                }
                                .frame(height: 0)
                                .id("topAnchor")

                                // Title
                                Text(titleText)
                                    .font(titleFont)
                                    .lineSpacing(39 - 28)
                                    .tracking(0.672)
                                    .foregroundColor(AppColors.primaryText)

                                // Subtitle - 12pt below title
                                Text(subtitleText)
                                    .font(bodyFont)
                                    .foregroundColor(AppColors.primaryText)
                                    .lineSpacing(22 - 17)
                                    .tracking(0.37)
                                    .padding(.top, AppSpacing.headerBody)

                                // Mode-specific content
                                if effectiveMode == .create {
                                    createModeContent
                                } else {
                                    joinModeContent
                                }

                                // Spacer to position code entry above keyboard (40px clearance)
                                if keyboardObserver.isKeyboardVisible {
                                    Spacer()
                                        .frame(height: 40)
                                        .id("bottomSpacer")
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, topPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Dismiss keyboard when tapping outside code boxes
                                if keyboardObserver.isKeyboardVisible {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    isCodeFieldFocused = false
                                }
                            }
                        }
                        .coordinateSpace(name: "manualPairingScroll")
                        .scrollBounceBehavior(.basedOnSize)
                        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                            // Show gradient when scrolled down (negative offset means scrolled)
                            let shouldShow = value < (topPadding - 10)
                            if shouldShow != showTopGradient {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showTopGradient = shouldShow
                                }
                            }
                        }
                    // Allow scrolling when keyboard is visible so user can scroll to see camera
                    .scrollDisabled(!keyboardObserver.isKeyboardVisible)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Dismiss keyboard when tapping outside code boxes
                        if isCodeFieldFocused {
                            isCodeFieldFocused = false
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    }
                    .onChange(of: isCodeFieldFocused) { _, focused in
                        if focused && keyboardObserver.isKeyboardVisible {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("codeEntryField", anchor: .bottom)
                            }
                        } else if !focused {
                            // Scroll back to top when focus is lost
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("topAnchor", anchor: .top)
                            }
                        }
                    }
                    .onChange(of: keyboardObserver.isKeyboardVisible) { _, visible in
                        if visible && isCodeFieldFocused {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    proxy.scrollTo("codeEntryField", anchor: .bottom)
                                }
                            }
                        } else if !visible {
                            // Keyboard dismissed - scroll back to top
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("topAnchor", anchor: .top)
                            }
                        }
                    }
                }

                // Top fade gradient (appears when scrolled - JOIN MODE ONLY)
                // Extends behind status bar / dynamic island
                if showTopGradient && effectiveMode == .join {
                    VStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                .init(color: AppColors.background.opacity(1.0), location: 0.0),
                                .init(color: AppColors.background.opacity(0.6), location: 0.66),
                                .init(color: AppColors.background.opacity(0.25), location: 0.84),
                                .init(color: AppColors.background.opacity(0.0), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 200)
                        Spacer()
                    }
                    .ignoresSafeArea(.all, edges: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            #if DEBUG
            .opacity(mainContentOpacity)
            .animation(.easeInOut(duration: 0.3), value: showPartnerJoinView)
            #endif

            // Back button (fixed, always on top of gradient)
            VStack {
                HStack {
                    BackButton {
                        #if DEBUG
                        if showPartnerJoinView {
                            // Navigate to pairing screen when viewing partner's screen
                            showPartnerJoinView = false
                            onBackTapped?()
                        } else {
                            onBackTapped?()
                        }
                        #else
                        onBackTapped?()
                        #endif
                    }
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.top, 40)
                Spacer()
            }
            #if DEBUG
            .opacity(mainContentOpacity)
            .animation(.easeInOut(duration: 0.3), value: showPartnerJoinView)
            #endif

            // DEBUG: Collapsible controls
            #if DEBUG
            if !showPartnerJoinView {
                VStack {
                    Spacer()
                    if debugCollapsed {
                        // Collapsed state - just a small toggle button
                        HStack {
                            Spacer()
                            Button(action: { debugCollapsed = false }) {
                                Image(systemName: "ladybug.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        Circle()
                                            .fill(Color.orange.opacity(0.8))
                                    )
                            }
                            .padding(.trailing, 20)
                        }
                    } else {
                        debugControlsPanel
                            .padding(.horizontal, 20)
                    }
                    Spacer().frame(height: 40)
                }
            }

            // Korean Join view overlay (fades in when showPartnerJoinView is true)
            // Back button navigates to pairing screen (same as real flow)
            if showPartnerJoinView {
                ManualPairingScreenKorean(
                    sessionMode: .join,
                    roomCode: roomCode,
                    onBackTapped: {
                        // Navigate to pairing screen (resets WiFi timer)
                        showPartnerJoinView = false
                        onBackTapped?()
                    },
                    onSuccess: { roomId in
                        showPartnerJoinView = false
                        onSuccess?(roomId)
                    }
                )
                .transition(.opacity)
            }
            #endif
        }
            .onChange(of: qrScanner.scannedCode) { _, code in
                if let code = code, !code.isEmpty {
                    handleScannedCode(code)
                }
            }
            .onAppear {
                // Generate a new code when entering Create mode in debug
                #if DEBUG
                if effectiveMode == .create && sharedCodeManager.generatedRoomCode.isEmpty {
                    sharedCodeManager.generateNewCode(language: "en")
                }
                #endif
            }
        }
    }

    // MARK: - Create Mode Content

    private var createModeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // QR Code Section Label - 32pt below subtitle
            Text("Show this QR code:")
                .font(AppTypography.h3)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, 32)

            // QR Code - 12pt below label (uses cached image to prevent flickering)
            if let qrImage = cachedQRImage {
                ZStack {
                    // White container 242x242
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppColors.cardFill.opacity(0.95))
                        .frame(width: 242, height: 242)

                    // QR code centered inside (228x228 - 6px padding on each side, reduced from 8px)
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 228, height: 228)
                }
                .codeBoxShadow()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            }

            // Code Section Label - 76pt below QR code (60 + 16)
            Text("Or share this code:")
                .font(AppTypography.b2)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, 76)

            // Code Display Card - 16pt below label
            HStack(alignment: .center) {
                // Code with spaces between digits
                Text(spacedDisplayCode)
                    .font(AppTypography.codeEntry)
                    .foregroundColor(AppColors.primaryText)
                    .padding(.leading, 6)

                Spacer()

                // Copy Button
                CopyButton(showCopiedFeedback: showCopiedFeedback, action: copyCode)
                    .padding(.trailing, 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 16)
            .frame(width: 242)
            .background(AppColors.cardFill.opacity(0.95))
            .cornerRadius(8)
            .codeBoxShadow()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
        }
        .onAppear {
            // Generate QR code once and cache it
            if cachedQRImage == nil {
                cachedQRImage = generateQRCode(from: displayCode)
            }
        }
        .onChange(of: displayCode) { _, newCode in
            // Regenerate if code changes
            cachedQRImage = generateQRCode(from: newCode)
        }
    }

    // MARK: - Join Mode Content

    private var isCameraAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    @ViewBuilder
    private var statusMessageView: some View {
        HStack(spacing: 8) {
            if isConnecting {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(AppColors.secondaryIcon)
                Text(verifyingCodeText)
                    .font(AppTypography.subtext)
                    .foregroundColor(AppColors.secondaryText)
            } else if showError {
                Text(invalidCodeText)
                    .font(AppTypography.subtext)
                    .foregroundColor(AppColors.errorRed)
            }
        }
        .padding(.top, 14)
        .animation(.easeInOut(duration: 0.2), value: isConnecting)
        .animation(.easeInOut(duration: 0.2), value: showError)
    }

    private var joinModeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Camera Section
            Text(scanQRText)
                .font(h3Font)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, 32)

            // Camera container (semi-transparent to show surroundings, full opacity when code entry focused)
            ZStack {
                // Container background with conditional opacity (90% normally, 100% when code focused)
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppColors.cardFill.opacity(0.95 * backgroundElementsOpacity))
                    .frame(width: 353, height: 200)

                // Container border with same conditional opacity
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.05 * backgroundElementsOpacity), lineWidth: 1)
                    .frame(width: 353, height: 200)

                // Camera viewfinder (329x176 - 12px padding) - always full opacity
                #if targetEnvironment(simulator)
                // Simulator: Show placeholder with semi-transparent background
                VStack(spacing: 12) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 48))
                        .foregroundColor(AppColors.secondaryText)
                    Text(cameraNotAvailableSimulatorText)
                        .font(b3Font)
                        .foregroundColor(AppColors.secondaryText)
                }
                .frame(width: 329, height: 176)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                #else
                // Real device: Show camera viewfinder at full opacity
                if isCameraAvailable {
                    QRScannerView(scanner: qrScanner, isReady: qrScanner.isReady)
                        .frame(width: 329, height: 176)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // Fallback if camera not available on device
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 48))
                            .foregroundColor(AppColors.secondaryText)
                        Text(cameraNotAvailableText)
                            .font(b3Font)
                            .foregroundColor(AppColors.secondaryText)
                    }
                    .frame(width: 329, height: 176)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                #endif
            }
            .codeBoxShadow()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .animation(.easeInOut(duration: 0.25), value: backgroundElementsOpacity)
            .onTapGesture {
                // Dismiss keyboard when tapping camera area - scroll will revert automatically
                if isCodeFieldFocused {
                    isCodeFieldFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }

            // Manual Code Entry Section - 60pt below camera (same as Create mode)
            Text(manualEntryText)
                .font(bodyFont)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, 76)

            // Code Entry Field
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { index in
                        CodeDigitBox(
                            digit: getDigit(at: index),
                            isFocused: isCodeFieldFocused && enteredCode.count == index && !showErrorGlow,
                            isError: showErrorGlow,
                            isAnimatingOut: isAnimatingOut,
                            backgroundOpacity: backgroundElementsOpacity
                        )
                    }
                }
                .offset(x: shakeOffset)
                .animation(.easeInOut(duration: 0.25), value: backgroundElementsOpacity)
                .background(
                    // Hidden UIKit TextField for reliable keyboard input - MUST be in .background()
                    UIKitTextField(
                        text: $enteredCode,
                        isFirstResponder: $isCodeFieldFocused,
                        onDigitEntered: { triggerHaptic() },
                        onComplete: { handleEnteredCode() },
                        onTextChange: { oldValue, newValue in
                            // Clear error states when user starts typing
                            if newValue.count > oldValue.count {
                                if showError { showError = false }
                                if showErrorGlow { showErrorGlow = false }
                            }
                        }
                    )
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    // CRITICAL: Must call becomeFirstResponder explicitly!
                    isCodeFieldFocused = true
                    UIKitTextField.focus()
                }

                // Status message (inside the VStack so it scrolls with code boxes)
                statusMessageView
            }
            .padding(.top, 16)
            .padding(.bottom, 12)
            .id("codeEntryField")

        }
        .onAppear {
            // Only start camera when Join mode content appears and camera is available
            if isCameraAvailable {
                qrScanner.startIfNeeded()
            }
        }
        .onDisappear {
            if isCameraAvailable {
                qrScanner.stopScanning()
            }
        }
    }

    // MARK: - Debug Controls

    #if DEBUG
    private var debugControlsPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "ladybug.fill")
                    .foregroundColor(.orange)
                Text("Debug: Mode Switch")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { debugCollapsed = true }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button(action: {
                    debugSessionMode = .create
                    sharedCodeManager.generateNewCode(language: "en")
                }) {
                    Text("🇺🇸 Create")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(effectiveMode == .create ? .white : .primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(effectiveMode == .create ? Color.orange : Color.gray.opacity(0.2))
                        )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    // Fade to Korean Join view (partner's perspective)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showPartnerJoinView = true
                    }
                }) {
                    Text("🇰🇷 Join")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Display generated code for testing (when in Join mode with a code generated)
            if !sharedCodeManager.generatedRoomCode.isEmpty {
                HStack {
                    Text("Test Code:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(sharedCodeManager.generatedRoomCode)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                    Text("(\(sharedCodeManager.generatorLanguage.uppercased()))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        UIPasteboard.general.string = sharedCodeManager.generatedRoomCode
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Quick success button for testing
            Button(action: {
                onSuccess?("DEBUG-ROOM-\(enteredCode.isEmpty ? roomCode : enteredCode)")
            }) {
                Text("→ Simulate Success")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green)
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    #endif

    // MARK: - Helper Methods

    /// The actual code to display - uses roomCodeManager in debug mode when available
    private var displayCode: String {
        #if DEBUG
        if !sharedCodeManager.generatedRoomCode.isEmpty {
            return sharedCodeManager.generatedRoomCode
        }
        #endif
        return roomCode
    }

    private var formattedDisplayCode: String {
        // Add space in middle for readability: "208 098"
        let code = displayCode
        let mid = code.index(code.startIndex, offsetBy: min(3, code.count))
        return String(code[..<mid]) + " " + String(code[mid...])
    }

    private var spacedDisplayCode: String {
        // Add space between each digit: "2 0 8 0 9 8"
        return displayCode.map { String($0) }.joined(separator: " ")
    }

    private func getDigit(at index: Int) -> String {
        guard index < enteredCode.count else { return "" }
        let charIndex = enteredCode.index(enteredCode.startIndex, offsetBy: index)
        return String(enteredCode[charIndex])
    }

    private func copyCode() {
        #if os(iOS)
        UIPasteboard.general.string = displayCode
        #endif

        showCopiedFeedback = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedFeedback = false
        }
    }

    private func handleEnteredCode() {
        guard enteredCode.count == 6, !isConnecting else { return }
        isConnecting = true

        // Don't dismiss keyboard yet - keep it up during validation

        // TODO: Connect to WebSocket with entered code
        // For now, simulate validation after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Validate code - in debug/simulator, use test validation
            let isValid: Bool

            // Debug validation: codes starting with "9" always fail
            // If a code was generated (Create mode), must match exactly
            if !sharedCodeManager.generatedRoomCode.isEmpty {
                // Validate against generated code
                isValid = sharedCodeManager.validateCode(enteredCode)
            } else {
                // No code generated - use simple rule: codes starting with "9" fail
                isValid = !enteredCode.hasPrefix("9")
            }

            if !isValid {
                // Hide connecting state before showing error
                isConnecting = false

                // Show error state with glow and text
                withAnimation(.easeInOut(duration: 0.2)) {
                    showError = true
                    showErrorGlow = true
                }
                triggerErrorHaptic()

                // After 0.75s, animate digits out (fade down)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isAnimatingOut = true
                    }

                    // After digits fade out (0.3s), clear code and reset first box
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        enteredCode = ""
                        isAnimatingOut = false
                        // First box becomes active again, keyboard stays up
                        isCodeFieldFocused = true
                    }
                }

                // After 1 second, fade out the glow but keep error text
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showErrorGlow = false
                    }
                }
                return
            }

            // Success - dismiss keyboard and navigate
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            isCodeFieldFocused = false
            showError = false
            showErrorGlow = false
            onSuccess?(enteredCode)
        }
    }

    private func handleScannedCode(_ code: String) {
        // Stop scanning
        qrScanner.stopScanning()

        // Use scanned code
        enteredCode = code.filter { $0.isNumber }.prefix(6).description

        // Auto-connect
        handleEnteredCode()
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)

        guard let ciImage = filter.outputImage else { return nil }

        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: transform)

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Copy Button with Animation

struct CopyButton: View {
    let showCopiedFeedback: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Image("check")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 24, height: 24)  // Decreased from 28x28
                    .foregroundColor(AppColors.primaryIcon)
                    .scaleEffect(showCopiedFeedback ? 1.1 : 0.01)
                    .opacity(showCopiedFeedback ? 1 : 0)

                Image("copy")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 24, height: 24)  // Decreased from 28x28
                    .foregroundColor(AppColors.primaryIcon)
                    .scaleEffect(showCopiedFeedback ? 0.01 : (isPressed ? 0.9 : 1.0))
                    .opacity(showCopiedFeedback ? 0 : 1)
            }
            .frame(width: 24, height: 24)  // Decreased from 28x28
            .animation(.easeInOut(duration: 0.15), value: isPressed)
            .animation(.easeInOut(duration: 0.15), value: showCopiedFeedback)
        }
        .buttonStyle(PlainButtonStyle())
        .pressEvents {
            isPressed = true
        } onRelease: {
            isPressed = false
        }
    }
}

// MARK: - Press Events Modifier

struct PressEventsModifier: ViewModifier {
    var onPress: () -> Void
    var onRelease: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
    }
}

extension View {
    func pressEvents(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressEventsModifier(onPress: onPress, onRelease: onRelease))
    }
}

// MARK: - Code Digit Box

struct CodeDigitBox: View {
    let digit: String
    let isFocused: Bool
    var isError: Bool = false
    var isAnimatingOut: Bool = false  // For coordinated exit animation
    var backgroundOpacity: Double = 1.0
    var hasContent: Bool { !digit.isEmpty }

    @State private var cursorOpacity: Double = 1.0
    @State private var digitOffset: CGFloat = 20
    @State private var digitOpacity: Double = 0

    var body: some View {
        ZStack {
            // Background with conditional opacity
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColors.cardFill.opacity(0.95 * backgroundOpacity))

            // Content area (clipped for roll-up animation)
            ZStack {
                // Digit or cursor bar
                if digit.isEmpty {
                    // Flashing horizontal bar when focused (offset down 18px)
                    if isFocused && !isError {
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(AppColors.primaryText)
                            .frame(width: 24, height: 1)
                            .offset(y: 18)
                            .opacity(cursorOpacity)
                            .onAppear {
                                startCursorBlink()
                            }
                            .onDisappear {
                                cursorOpacity = 1.0
                            }
                    }
                } else {
                    // Digit with roll-up animation
                    Text(digit)
                        .font(AppTypography.codeEntry)
                        .foregroundColor(AppColors.primaryText)
                        .offset(y: isAnimatingOut ? 20 : digitOffset)
                        .opacity(isAnimatingOut ? 0 : digitOpacity)
                }
            }
            .frame(width: 48, height: 61)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Orange stroke - shows on filled boxes OR focused box, but NOT in error state
            if (hasContent || isFocused) && !isError {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColors.claudeOrange, lineWidth: 2)
            }
        }
        .frame(width: 52, height: 65)
        // Layer 1: White highlight shadow
        .shadow(color: Color.white.opacity(0.25), radius: 5, x: 0, y: 8)
        // Layer 2 & 3: Error glow (conditional)
        .shadow(color: isError ? AppColors.errorRed.opacity(0.55) : Color.clear, radius: 6, x: 0, y: 0)
        .shadow(color: isError ? AppColors.errorRed.opacity(0.35) : Color.clear, radius: 12, x: 0, y: 0)
        // Layer 5: Subtle bottom shadow
        .shadow(color: Color(hex: "0C0C0D").opacity(0.05), radius: 2, x: 0, y: 1)
        // Inner shadow effect via overlay
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: "ACACAC"), lineWidth: 4)
                .blur(radius: 2)
                .offset(x: 4, y: 4)
                .mask(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [Color.black, Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .opacity(0.05)
                .allowsHitTesting(false)
        )
        // Apply selected shadow only when focused and not in error
        .if(isFocused && !isError) { view in
            view.selectedCardShadow()
        }
        .animation(.easeInOut(duration: 0.2), value: isError)
        .animation(.easeInOut(duration: 0.3), value: isAnimatingOut)
        .onChange(of: digit) { oldValue, newValue in
            // Animate when digit is entered
            if !newValue.isEmpty && oldValue.isEmpty {
                animateDigitEntry()
            } else if newValue.isEmpty && !oldValue.isEmpty {
                // Reset for when digit is cleared
                digitOffset = 20
                digitOpacity = 0
            }
        }
        .onChange(of: isFocused) { _, newValue in
            // Reset cursor opacity when focus changes
            if newValue && !isError {
                cursorOpacity = 1.0
                startCursorBlink()
            }
        }
    }

    private func startCursorBlink() {
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            cursorOpacity = 0.0
        }
    }

    private func animateDigitEntry() {
        // Start from below, invisible
        digitOffset = 20
        digitOpacity = 0

        // Animate up and fade in (0.3s - 20% slower than original 0.25s)
        withAnimation(.easeOut(duration: 0.3)) {
            digitOffset = 0
            digitOpacity = 1
        }
    }
}

// MARK: - Scroll Offset Preference Key

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Code Entry TextField (UIKit wrapper for proper focus tracking)

struct CodeEntryTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onDigitEntered: (() -> Void)?
    var onComplete: (() -> Void)?

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.keyboardType = .numberPad
        textField.textContentType = .oneTimeCode  // Helps with autofill
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textFieldDidChange(_:)), for: .editingChanged)
        // Ensure the text field can become first responder
        textField.isUserInteractionEnabled = true
        // Make text invisible but field still functional
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.backgroundColor = .clear
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        // Handle focus changes from SwiftUI
        if isFocused && !uiView.isFirstResponder {
            // Use asyncAfter with small delay to ensure view hierarchy is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let _ = uiView.becomeFirstResponder()
            }
        } else if !isFocused && uiView.isFirstResponder {
            // Explicitly resign first responder when focus is removed
            DispatchQueue.main.async {
                uiView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CodeEntryTextField
        private var previousLength = 0

        init(_ parent: CodeEntryTextField) {
            self.parent = parent
            self.previousLength = parent.text.count
        }

        @objc func textFieldDidChange(_ textField: UITextField) {
            let newText = textField.text ?? ""

            // Filter to only digits and limit to 6
            let filtered = String(newText.filter { $0.isNumber }.prefix(6))

            // Update the binding
            parent.text = filtered

            // Trigger haptic if a new digit was added
            if filtered.count > previousLength {
                parent.onDigitEntered?()
            }
            previousLength = filtered.count

            // Sync back to text field if filtered
            if textField.text != filtered {
                textField.text = filtered
            }

            // Auto-submit when 6 digits entered
            if filtered.count == 6 {
                parent.onComplete?()
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            // Allow backspace
            if string.isEmpty {
                return true
            }

            // Only allow digits
            let allowedCharacters = CharacterSet.decimalDigits
            let characterSet = CharacterSet(charactersIn: string)
            guard allowedCharacters.isSuperset(of: characterSet) else {
                return false
            }

            // Limit to 6 characters
            let currentText = textField.text ?? ""
            let newLength = currentText.count + string.count - range.length
            return newLength <= 6
        }
    }
}

// MARK: - QR Scanner Model

class QRScannerModel: NSObject, ObservableObject {
    @Published var scannedCode: String? = nil
    @Published var isScanning = false
    @Published var cameraPermissionGranted = false
    @Published var isReady = false  // Track when camera is ready for preview

    let captureSession = AVCaptureSession()
    private var isSetup = false

    // Serial queue for camera operations - NEVER block main thread
    private let cameraQueue = DispatchQueue(label: "com.dari.cameraQueue", qos: .userInitiated)

    init(autoStart: Bool = true) {
        super.init()
        if autoStart {
            checkCameraPermission()
        }
    }

    func startIfNeeded() {
        if !isSetup {
            checkCameraPermission()
        } else if !captureSession.isRunning {
            startScanning()
        }
    }

    func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async {
                self.cameraPermissionGranted = true
            }
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.cameraPermissionGranted = granted
                }
                if granted {
                    self?.setupCamera()
                }
            }
        default:
            DispatchQueue.main.async {
                self.cameraPermissionGranted = false
            }
        }
    }

    func setupCamera() {
        // Run ALL camera setup on background queue to prevent UI freeze
        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isSetup else { return }

            // Configure session
            self.captureSession.beginConfiguration()

            guard let device = AVCaptureDevice.default(for: .video) else {
                self.captureSession.commitConfiguration()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)

                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }

                let output = AVCaptureMetadataOutput()
                if self.captureSession.canAddOutput(output) {
                    self.captureSession.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                    output.metadataObjectTypes = [.qr]
                }

                self.captureSession.commitConfiguration()
                self.isSetup = true

                // Mark as ready on main thread BEFORE starting
                DispatchQueue.main.async {
                    self.isReady = true
                }

                // Start the session (already on background queue)
                self.captureSession.startRunning()

                DispatchQueue.main.async {
                    self.isScanning = true
                }

            } catch {
                self.captureSession.commitConfiguration()
                print("QRScannerModel: Failed to setup camera - \(error.localizedDescription)")
            }
        }
    }

    func startScanning() {
        guard isSetup, !captureSession.isRunning else { return }
        cameraQueue.async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async {
                self?.isScanning = true
            }
        }
    }

    func stopScanning() {
        guard captureSession.isRunning else { return }
        cameraQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            DispatchQueue.main.async {
                self?.isScanning = false
            }
        }
    }
}

extension QRScannerModel: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let code = metadataObject.stringValue else {
            return
        }

        scannedCode = code
    }
}

// MARK: - QR Scanner View

struct QRScannerView: UIViewRepresentable {
    @ObservedObject var scanner: QRScannerModel
    var isReady: Bool  // Explicitly pass to trigger SwiftUI updates

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        // Don't create preview layer yet - wait for scanner to be ready
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Only create and add preview layer once scanner is ready
        if isReady {
            if context.coordinator.previewLayer == nil {
                // Create preview layer only when scanner is ready
                let previewLayer = AVCaptureVideoPreviewLayer(session: scanner.captureSession)
                previewLayer.videoGravity = .resizeAspectFill
                previewLayer.frame = uiView.bounds
                uiView.layer.addSublayer(previewLayer)
                context.coordinator.previewLayer = previewLayer
            } else if let previewLayer = context.coordinator.previewLayer {
                // Update frame when bounds change
                previewLayer.frame = uiView.bounds
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

// MARK: - Screen 3: SetupSuccessScreen

struct SetupSuccessScreen: View {
    let roomId: String
    var onProceed: (() -> Void)?
    var onBackTapped: (() -> Void)?  // Debug only

    @State private var hasProceeded = false
    @State private var circleScale: CGFloat = 1.0
    @State private var checkmarkProgress: CGFloat = 0.0

    var body: some View {
        ZStack {
            // Content (background and gradient provided by parent WelcomeScreenLangSelect)
            VStack(alignment: .leading, spacing: 0) {
                // Success checkmark with animation
                ZStack {
                    // Outer pulsing circle - sage green
                    Circle()
                        .fill(AppColors.lightGreen.opacity(0.6))
                        .frame(width: 48, height: 48)
                        .scaleEffect(circleScale)

                    // Inner static circle - success green
                    Circle()
                        .fill(AppColors.successGreen)
                        .frame(width: 36, height: 36)

                    // Animated checkmark - white
                    CheckmarkShape()
                        .trim(from: 0, to: checkmarkProgress)
                        .stroke(AppColors.whiteIcon, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(width: 18, height: 18)
                }
                .frame(width: 48, height: 48)

                // Title - 20px below checkmark
                Text("You're all set!")
                    .font(AppTypography.h2)
                    .lineSpacing(39 - 28)
                    .tracking(0.672)
                    .foregroundColor(AppColors.primaryText)
                    .padding(.top, 20)

                // Subtitle - 8px below title (same as other screens)
                Text("Starting your translation session now.")
                    .font(AppTypography.b2)
                    .foregroundColor(AppColors.primaryText)
                    .lineSpacing(22 - 17)
                    .tracking(0.37)
                    .padding(.top, 8)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, AppSpacing.welcomeContentStart)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // DEBUG: Back button
            #if DEBUG
            VStack {
                HStack {
                    BackButton {
                        hasProceeded = true  // Prevent auto-proceed
                        onBackTapped?()
                    }
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.top, 40)
                Spacer()
            }
            #endif
        }
        .onAppear {
            // Start animations 0.5 seconds after content loads
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                startSuccessAnimation()
            }

            // Auto-proceed after 3.5 seconds (3s after animation starts)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                guard !hasProceeded else { return }
                hasProceeded = true
                onProceed?()
            }
        }
    }

    private func startSuccessAnimation() {
        // Circle pulse: starts 0.1s after appear, 1.0 → 1.25 → 1.0 over 0.6s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                circleScale = 1.25
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeInOut(duration: 0.3)) {
                circleScale = 1.0
            }
        }

        // Checkmark draw: starts at 0.25s, finishes when circle finishes (0.7s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.45)) {
                checkmarkProgress = 1.0
            }
        }
    }
}

// MARK: - Checkmark Shape

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Checkmark drawn left to right
        // Start at left-middle, go down to bottom-center, then up to top-right
        let startPoint = CGPoint(x: rect.width * 0.15, y: rect.height * 0.5)
        let midPoint = CGPoint(x: rect.width * 0.4, y: rect.height * 0.75)
        let endPoint = CGPoint(x: rect.width * 0.85, y: rect.height * 0.25)

        path.move(to: startPoint)
        path.addLine(to: midPoint)
        path.addLine(to: endPoint)

        return path
    }
}

// MARK: - Screen 4: LiveTranslationScreen
// Main screen with animated bubble that responds to speech
// Works for both English and Korean language selections
// Connects to WebSocket for bidirectional translation

struct LiveTranslationScreen: View {
    let roomId: String
    var language: String = "en"  // "en" for English, "ko" for Korean

    // MARK: - Services (shared singletons)
    @StateObject private var webSocket = WebSocketManager.shared
    @StateObject private var audioCapture = AudioCaptureService.shared
    @StateObject private var audioPlayback = AudioPlaybackService.shared

    // MARK: - Audio State
    @State private var audioLevel: CGFloat = 0.0
    @State private var isSpeaking: Bool = false

    // MARK: - Language Selector State
    // true = I speak English (They speak Korean), false = I speak Korean (They speak English)
    @State private var iSpeakEnglish: Bool = true
    @State private var languageOpacity: Double = 1.0  // For fade animation

    // MARK: - Session State
    @State private var isSessionActive: Bool = false  // true only while mic capture is actually running
    @State private var hasStartedOnce: Bool = false  // Track if session was ever started (for hiding instruction text)
    @State private var isConnected: Bool = false  // true once session_started received; false = needs re-join
    @State private var isPartnerConnected: Bool = false
    @State private var isJoining: Bool = false  // Room join in flight (waiting for session_started)
    @State private var pendingCaptureStart: Bool = false  // Start capture as soon as the join completes

    // MARK: - Translation Display State
    @State private var myLastUtterance: String = ""
    @State private var partnerLastUtterance: String = ""
    @State private var partnerTranslation: String = ""

    // MARK: - Debug Mode State
    @State private var showDebugMenu: Bool = false
    @State private var selectedBubbleStyle: BubbleStyle = .combination
    @State private var simulatedAudioLevel: CGFloat = 0.0
    @State private var isSimulatingSpeaking: Bool = false

    #if DEBUG
    @State private var debugLanguage: String? = nil  // Override language in debug mode
    #endif

    // MARK: - Language Properties
    private var effectiveLanguage: String {
        #if DEBUG
        return debugLanguage ?? language
        #else
        return language
        #endif
    }

    private var isKorean: Bool {
        // When user speaks Korean, show UI in Korean
        !iSpeakEnglish
    }

    /// User's language enum for WebSocket
    private var userLanguage: UserLanguage {
        effectiveLanguage == "en" ? .english : .korean
    }

    // MARK: - Computed Properties
    private var effectiveAudioLevel: CGFloat {
        showDebugMenu ? simulatedAudioLevel : audioLevel
    }

    private var effectiveIsSpeaking: Bool {
        showDebugMenu ? isSimulatingSpeaking : isSpeaking
    }


    var body: some View {
        ZStack {
            // Background - solid beige color
            AppColors.background
                .ignoresSafeArea()

            // Language Selector - 32px below dynamic island
            VStack {
                languageSelectorView
                    .padding(.top, 32)
                Spacer()
            }

            // Bubble - centered in screen
            VStack(spacing: 24) {
                // Animated bubble with extra space for glow effects
                // Active prototype - animates continuously without audio bindings
                OrganicBubble(style: selectedBubbleStyle)
                    .frame(width: 400, height: 400)  // Larger container to prevent glow clipping

                // Translation display (shows when partner speaks)
                if !partnerTranslation.isEmpty {
                    translationDisplayView
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }

            // Instruction text - centered both vertically and horizontally
            // Only shows before first mic tap, never shows again after pause
            if !hasStartedOnce {
                Text(isKorean ? "마이크를 눌러 시작하세요!" : "Tap the mic to start.")
                    .font(isKorean ? AppTypography.h2Korean : AppTypography.h2)
                    .foregroundColor(AppColors.primaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }

            // Connection status indicator (top right)
            VStack {
                HStack {
                    Spacer()
                    connectionStatusView
                        .padding(.trailing, 16)
                        .padding(.top, 16)
                }
                Spacer()
            }

            // Mic button - exactly 60pt from actual screen bottom edge
            VStack {
                Spacer()
                MicButton(
                    isSessionActive: $isSessionActive,
                    onMicTapped: {
                        if isSessionActive {
                            // Pause: stop the mic but stay in the room
                            withAnimation {
                                isSessionActive = false
                            }
                            stopAudioCapture()
                        } else if isConnected {
                            startAudioCapture()
                        } else {
                            // Not in a live session (backend started late, connection dropped,
                            // or after Stop) - re-join and start capture once session_started arrives
                            pendingCaptureStart = true
                            if !isJoining {
                                connectToRoom()
                            }
                        }
                    },
                    onMoreTapped: {
                        // TODO: Handle more button tap
                    },
                    onStopTapped: {
                        withAnimation {
                            isSessionActive = false
                        }
                        stopAudioCapture()
                        endSession()
                    }
                )
            }
            .ignoresSafeArea(edges: .bottom)
            .padding(.bottom, 60)

            // Debug overlay (bottom right)
            #if DEBUG
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    liveTranslationDebugOverlay
                        .padding(.trailing, 16)
                        .padding(.bottom, 100)
                }
            }
            #endif
        }
        .onAppear {
            setupWebSocket()
            connectToRoom()
        }
        .onDisappear {
            disconnect()
        }
    }

    // MARK: - Connection Status View
    private var connectionStatusView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? (isPartnerConnected ? Color.green : Color.yellow) : Color.red)
                .frame(width: 8, height: 8)

            Text(connectionStatusText)
                .font(.system(size: 11))
                .foregroundColor(AppColors.primaryText.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.5))
        )
    }

    private var connectionStatusText: String {
        if !isConnected {
            return "Connecting..."
        } else if !isPartnerConnected {
            return isKorean ? "파트너 대기 중" : "Waiting for partner"
        } else {
            return isKorean ? "연결됨" : "Connected"
        }
    }

    // MARK: - Translation Display View
    private var translationDisplayView: some View {
        VStack(spacing: 8) {
            // Original text (partner's language)
            if !partnerLastUtterance.isEmpty {
                Text(partnerLastUtterance)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.primaryText.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            // Divider
            Rectangle()
                .fill(AppColors.primaryText.opacity(0.2))
                .frame(width: 60, height: 1)

            // Translated text (my language)
            Text(partnerTranslation)
                .font(isKorean ? AppTypography.h3Korean : AppTypography.h3)
                .foregroundColor(AppColors.primaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.3))
        )
    }

    // MARK: - WebSocket Setup
    private func setupWebSocket() {
        // Set up callbacks for session events
        webSocket.onSessionStarted = { roomId in
            DispatchQueue.main.async {
                isConnected = true
                isJoining = false
                print("[LiveTranslation] Session started in room: \(roomId)")

                // Mic was tapped while we were (re)joining - start capture now
                if pendingCaptureStart {
                    pendingCaptureStart = false
                    startAudioCapture()
                }
            }
        }

        webSocket.onPartnerJoined = {
            DispatchQueue.main.async {
                isPartnerConnected = true
                print("[LiveTranslation] Partner joined")
            }
        }

        webSocket.onPartnerLeft = {
            DispatchQueue.main.async {
                isPartnerConnected = false
                print("[LiveTranslation] Partner left")
            }
        }

        webSocket.onMyTranscription = { text in
            DispatchQueue.main.async {
                myLastUtterance = text
                print("[LiveTranslation] My transcription: \(text)")
            }
        }

        webSocket.onPartnerTranslation = { original, translated in
            DispatchQueue.main.async {
                partnerLastUtterance = original
                partnerTranslation = translated
                print("[LiveTranslation] Partner said: \(original) -> \(translated)")
            }
        }

        webSocket.onAudioReceived = { audioData in
            // Play received audio (translated speech from partner)
            audioPlayback.playAudio(audioData)
        }

        webSocket.onError = { errorMessage in
            DispatchQueue.main.async {
                print("[LiveTranslation] Error: \(errorMessage)")

                // Server error while (re)joining means the join failed - let the next mic tap retry
                if isJoining {
                    isJoining = false
                    pendingCaptureStart = false
                }
            }
        }

        webSocket.onDisconnected = { reason in
            DispatchQueue.main.async {
                print("[LiveTranslation] Connection lost: \(reason)")

                // Reflect reality in the pill and mic; next mic tap re-joins the room
                isConnected = false
                isPartnerConnected = false
                isJoining = false
                pendingCaptureStart = false
                withAnimation {
                    isSessionActive = false
                }
                stopAudioCapture()
            }
        }
    }

    private func connectToRoom() {
        isJoining = true

        // Join the existing room with our language preference
        webSocket.joinRoom(
            roomId: roomId,
            userLanguage: userLanguage,
            honorificMode: false
        )

        // Update connection state based on WebSocket state
        isConnected = webSocket.connectionState.isConnected
        isPartnerConnected = webSocket.isPartnerConnected
    }

    private func startAudioCapture() {
        guard isConnected else {
            print("[LiveTranslation] Cannot start capture: not connected")
            return
        }

        Task { @MainActor in
            // Ask for mic permission on first activation (no-op once granted)
            let granted = await AudioSessionManager.shared.requestMicrophonePermission()
            guard granted else {
                print("[LiveTranslation] Microphone permission denied - capture not started")
                return
            }

            // Connection may have dropped (or Stop tapped) while the permission prompt was up
            guard isConnected else {
                print("[LiveTranslation] Cannot start capture: not connected")
                return
            }

            let started = audioCapture.startCapturing { audioData, level in
                // Update audio level for bubble animation
                DispatchQueue.main.async {
                    self.audioLevel = CGFloat(level)
                    self.isSpeaking = level > 0.1
                }

                // Echo guard: while our translated speech is playing through the phone's own
                // speaker, send same-length silence so Deepgram stays fed but doesn't
                // re-transcribe our output. With headphones, send the mic audio unchanged.
                let echoRisk = audioPlayback.isOutputActive && AudioSessionManager.isOutputOnBuiltInSpeaker()
                let outgoing = echoRisk ? Data(count: audioData.count) : audioData

                // Send audio to WebSocket
                webSocket.sendAudioChunk(outgoing)
            }

            guard started else {
                print("[LiveTranslation] Failed to start audio capture - mic stays inactive")
                return
            }

            withAnimation {
                isSessionActive = true
                hasStartedOnce = true
            }
        }
    }

    private func stopAudioCapture() {
        audioCapture.stopCapturing()
        DispatchQueue.main.async {
            self.audioLevel = 0
            self.isSpeaking = false
        }
    }

    private func endSession() {
        webSocket.sendSessionEnd()

        // Server drops our orchestrator on session_end - next mic tap must re-join the room
        isConnected = false
        pendingCaptureStart = false
    }

    private func disconnect() {
        stopAudioCapture()
        webSocket.sendSessionEnd()
        webSocket.disconnect()
    }

    // MARK: - Debug Overlay
    #if DEBUG
    private var liveTranslationDebugOverlay: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Bug icon button (always visible)
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showDebugMenu.toggle()
                }
            }) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.6))
                    )
            }

            // Expandable menu
            if showDebugMenu {
                VStack(alignment: .leading, spacing: 12) {
                    // Language toggle section
                    languageDebugSection

                    Divider()
                        .background(Color.white.opacity(0.2))

                    // Bubble style section
                    bubbleStyleDebugSection

                    Divider()
                        .background(Color.white.opacity(0.2))

                    // Audio simulation section
                    audioSimulationDebugSection
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.75))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .transition(.scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity))
            }
        }
    }

    private var languageDebugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LANGUAGE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                // English button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        debugLanguage = "en"
                    }
                }) {
                    HStack(spacing: 4) {
                        Text("🇺🇸")
                        Text("EN")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(effectiveLanguage == "en" ? AppColors.gradientPeach : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(effectiveLanguage == "en" ? Color.white.opacity(0.2) : Color.clear)
                    )
                }
                .buttonStyle(.plain)

                // Korean button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        debugLanguage = "ko"
                    }
                }) {
                    HStack(spacing: 4) {
                        Text("🇰🇷")
                        Text("KR")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(effectiveLanguage == "ko" ? AppColors.gradientPeach : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(effectiveLanguage == "ko" ? Color.white.opacity(0.2) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            // Show current language info
            Text("User selected: \(language.uppercased())")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var bubbleStyleDebugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BUBBLE STYLE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            ForEach(BubbleStyle.allCases, id: \.rawValue) { style in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedBubbleStyle = style
                    }
                }) {
                    HStack(spacing: 8) {
                        Text("\(style.rawValue)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .frame(width: 20)

                        Text(style.displayName)
                            .font(.system(size: 12, weight: .medium))

                        Spacer()

                        if selectedBubbleStyle == style {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .foregroundColor(selectedBubbleStyle == style ? AppColors.gradientPeach : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedBubbleStyle == style ? Color.white.opacity(0.15) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var audioSimulationDebugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AUDIO SIMULATION")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            // Speaking toggle
            Toggle(isOn: $isSimulatingSpeaking) {
                HStack {
                    Image(systemName: isSimulatingSpeaking ? "mic.fill" : "mic")
                        .foregroundColor(isSimulatingSpeaking ? AppColors.gradientPeach : .white.opacity(0.7))
                    Text("Speaking")
                        .font(.system(size: 12))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: AppColors.gradientPeach))
            .foregroundColor(.white)

            // Audio level slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Level")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text(String(format: "%.2f", simulatedAudioLevel))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AppColors.gradientPeach)
                }

                Slider(value: $simulatedAudioLevel, in: 0...1)
                    .tint(AppColors.gradientPeach)
            }
        }
    }
    #endif

    // MARK: - Language Selector View
    private var languageSelectorView: some View {
        VStack(spacing: 4) {
            // Labels row
            HStack(spacing: 0) {
                languageLabel(theySpeakLabel)
                    .frame(width: 160)

                Spacer()

                languageLabel(iSpeakLabel)
                    .frame(width: 160)
            }

            // Boxes row (static display, non-interactable)
            HStack(spacing: 0) {
                // Left box - "They speak"
                languageBox(label: theySpeakLabel, language: theySpeakLanguage)

                Spacer()

                // Right box - "I speak"
                languageBox(label: iSpeakLabel, language: iSpeakLanguage)
            }

            // P2: Language switch functionality - commented out for now.
            // Would be more useful when supporting more than 2 languages.
            // Previously had a switch button in the middle that called switchLanguages()
            // to swap "I speak" and "They speak" languages with a fade animation.
            // See switchLanguages() function below for the implementation.
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Language Box Component
    private func languageBox(label: String, language: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColors.languageDisplayBox)
                .frame(width: 160, height: 44)
                .codeBoxShadow()

            Text(language)
                .font(isKorean ? AppTypography.b2Korean : AppTypography.b2)
                .foregroundColor(AppColors.primaryText)
                // P2: languageOpacity used by switchLanguages() for fade animation
                .opacity(languageOpacity)
        }
    }

    // MARK: - Language Label Component
    private func languageLabel(_ label: String) -> some View {
        Text(label)
            .font(isKorean ? AppTypography.b3Korean : AppTypography.b3)
            .foregroundColor(AppColors.primaryText)
            .lineSpacing(isKorean ? (21 - 14) : (21 - 15))
    }

    // MARK: - Language Selector Labels
    private var theySpeakLabel: String {
        isKorean ? "상대방 언어" : "They speak"
    }

    private var iSpeakLabel: String {
        isKorean ? "내 언어" : "I speak"
    }

    // MARK: - Language Selector Content
    private var theySpeakLanguage: String {
        if isKorean {
            return iSpeakEnglish ? "한국어" : "영어"
        } else {
            return iSpeakEnglish ? "Korean" : "English"
        }
    }

    private var iSpeakLanguage: String {
        if isKorean {
            return iSpeakEnglish ? "영어" : "한국어"
        } else {
            return iSpeakEnglish ? "English" : "Korean"
        }
    }

    // MARK: - Switch Languages Action (P2 - Currently unused)
    // P2: This function is kept for potential future use when supporting more languages.
    // It swaps the "I speak" and "They speak" languages with a smooth fade animation.
    // To re-enable: add a switch button in languageSelectorView that calls this function.
    private func switchLanguages() {
        // Haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()

        // Phase 1: Fade out text
        withAnimation(.easeOut(duration: 0.12)) {
            languageOpacity = 0
        }

        // Phase 2: Toggle the language while text is hidden
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            iSpeakEnglish.toggle()
        }

        // Phase 3: Fade in new text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.easeOut(duration: 0.15)) {
                languageOpacity = 1
            }
        }
    }
}

// MARK: - Korean Screens

// Korean version of PairingScreen
struct PairingScreenKorean: View {
    var direction: String = "ko_to_en"
    var onBackTapped: (() -> Void)?
    var onManualPairing: ((String) -> Void)?
    var onSuccess: ((String) -> Void)?

    @StateObject private var pairingManager = PairingWebSocketManager()
    @StateObject private var headphoneMonitor = HeadphoneMonitor()

    // Headphone reminder alert
    @State private var showHeadphoneAlert = false
    @State private var hasShownHeadphoneAlert = false
    @State private var headphoneAlertTimer: Timer? = nil

    // DEBUG: Mode toggle for simulator testing
    #if DEBUG
    @State private var debugMode = true  // Start in debug mode for simulator
    @State private var debugHeadphonesConnected = false
    #endif

    private var effectiveHeadphoneStatus: Bool {
        #if DEBUG
        if debugMode {
            return debugHeadphonesConnected
        }
        #endif
        return headphoneMonitor.isConnected
    }

    var body: some View {
        ZStack {
            // Content (background and gradient provided by parent)
            VStack(alignment: .leading, spacing: 0) {
                // Title
                Text("파트너를 찾는 중...")
                    .font(AppTypography.h2Korean)
                    .lineSpacing(38 - 28)
                    .tracking(0.672)
                    .foregroundColor(AppColors.primaryText)

                // Loading dots - 12px below title
                BouncingDots()
                    .padding(.top, 12)

                // Subtitle
                Text("같은 WiFi에 연결해 주세요.\n헤드폰도 준비해 주세요.")
                    .font(AppTypography.b2Korean)
                    .foregroundColor(AppColors.primaryText)
                    .lineSpacing(22 - 17)
                    .tracking(0.37)
                    .padding(.top, 24)

                // Headphone status card - 32px below subtitle
                PairingHeadphoneStatusCardKorean(
                    isConnected: effectiveHeadphoneStatus,
                    onTap: {
                        openBluetoothSettings()
                    }
                )
                .padding(.top, 32)

                Spacer()

                // Manual pairing button
                Button(action: {
                    let roomCode = String(format: "%06d", Int.random(in: 0...999999))
                    onManualPairing?(roomCode)
                }) {
                    Text("파트너를 찾을 수 없나요?")
                        .font(AppTypography.b2Korean)
                        .foregroundColor(AppColors.claudeOrange)
                        .underline()
                }
                .padding(.bottom, 40)
            }
            .padding(.leading, 20)
            .padding(.top, AppSpacing.welcomeContentStart - 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Back button
            VStack {
                HStack {
                    BackButton {
                        pairingManager.disconnect()
                        onBackTapped?()
                    }
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.top, 40)
                Spacer()
            }

            // DEBUG: Explicit controls panel at bottom
            #if DEBUG
            VStack {
                Spacer()
                debugControlsPanelKorean
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }
            #endif
        }
        .onAppear {
            #if DEBUG
            if !debugMode {
                pairingManager.connect()
                startHeadphoneAlertTimer()
            }
            #else
            pairingManager.connect()
            startHeadphoneAlertTimer()
            #endif
        }
        .onDisappear {
            pairingManager.disconnect()
            headphoneAlertTimer?.invalidate()
            headphoneAlertTimer = nil
        }
        .onChange(of: headphoneMonitor.isConnected) { _, newValue in
            #if DEBUG
            if !debugMode {
                pairingManager.sendHeadphoneStatus(connected: newValue)
            }
            #else
            pairingManager.sendHeadphoneStatus(connected: newValue)
            #endif

            // If headphones connected, cancel alert timer
            if newValue {
                headphoneAlertTimer?.invalidate()
                headphoneAlertTimer = nil
            }
        }
        .onChange(of: pairingManager.partnerStatus) { _, newStatus in
            // Show alert immediately if partner is ready but we don't have headphones
            if newStatus == .ready && !effectiveHeadphoneStatus {
                showHeadphoneAlertIfNeeded()
            }
        }
        .onChange(of: pairingManager.shouldNavigateToManual) { _, shouldNavigate in
            if shouldNavigate, let code = pairingManager.roomCode {
                onManualPairing?(code)
            }
        }
        .onChange(of: pairingManager.shouldNavigateToSuccess) { _, shouldNavigate in
            if shouldNavigate, let roomId = pairingManager.roomId {
                onSuccess?(roomId)
            }
        }
        .alert("헤드폰을 연결하세요", isPresented: $showHeadphoneAlert) {
            Button("설정 열기") {
                openBluetoothSettings()
            }
            Button("나중에", role: .cancel) { }
        } message: {
            Text("실시간 번역을 들으려면 헤드폰이 필요해요.")
        }
    }

    // MARK: - Headphone Alert Logic (Korean)

    private func startHeadphoneAlertTimer() {
        headphoneAlertTimer?.invalidate()
        headphoneAlertTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            showHeadphoneAlertIfNeeded()
        }
    }

    private func showHeadphoneAlertIfNeeded() {
        if !effectiveHeadphoneStatus && !hasShownHeadphoneAlert {
            showHeadphoneAlert = true
            hasShownHeadphoneAlert = true
        }
    }

    private func openBluetoothSettings() {
        #if os(iOS)
        if let url = URL(string: "App-Prefs:root=Bluetooth") {
            UIApplication.shared.open(url)
        }
        #endif
    }

    // MARK: - Debug Controls (Korean)

    #if DEBUG
    @ViewBuilder
    private var debugControlsPanelKorean: some View {
        VStack(spacing: 12) {
            Text("DEBUG CONTROLS")
                .font(.caption.bold())
                .foregroundColor(.white)

            Toggle("Debug Mode", isOn: $debugMode)
                .toggleStyle(SwitchToggleStyle(tint: .orange))
                .foregroundColor(.white)

            if debugMode {
                Toggle("Headphones", isOn: $debugHeadphonesConnected)
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                    .foregroundColor(.white)

                Button("Manual Pairing") {
                    let roomCode = String(format: "%06d", Int.random(in: 0...999999))
                    onManualPairing?(roomCode)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(8)

                Button("Success") {
                    onSuccess?("debug-room-id")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
    }
    #endif
}

// Korean version of ManualPairingScreen
struct ManualPairingScreenKorean: View {
    let sessionMode: SessionMode
    let roomCode: String
    var onBackTapped: (() -> Void)?
    var onSuccess: ((String) -> Void)?
    var onSwitchToEnglishJoin: (() -> Void)?  // Debug: Switch to English Join screen

    @State private var showCopiedFeedback = false
    @State private var enteredCode: String = ""
    @State private var isConnecting = false
    @State private var showError = false
    @State private var showErrorGlow = false
    @State private var isCodeFieldFocused: Bool = false  // Changed from @FocusState to @State for UIKitTextField compatibility
    @State private var shakeOffset: CGFloat = 0
    @State private var showTopGradient = false
    @State private var isAnimatingOut = false
    @State private var cachedQRImage: UIImage? = nil  // Cached QR code to prevent flickering
    @StateObject private var qrScanner = QRScannerModel(autoStart: false)
    @StateObject private var keyboardObserver = KeyboardObserver()
    @ObservedObject private var sharedCodeManager = RoomCodeManager.shared

    #if DEBUG
    @State private var debugSessionMode: SessionMode? = nil
    @State private var debugCollapsed = true
    @State private var debugLanguage: String = "ko"  // "en" or "ko" for cross-language switching
    @State private var showPartnerJoinView = false  // Fade to English Join view
    #endif

    private var effectiveMode: SessionMode {
        #if DEBUG
        return debugSessionMode ?? sessionMode
        #else
        return sessionMode
        #endif
    }

    // In debug mode, Join should show English (partner's language)
    #if DEBUG
    private var isShowingPartnerLanguage: Bool {
        debugSessionMode == .join
    }
    #endif

    // Localized text properties for cross-language debug support (Korean → English for partner)
    private var titleText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "Can't find your partner?"
        }
        #endif
        return "파트너를 찾을 수 없나요?"
    }

    private var subtitleText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "You might be on different networks."
        }
        #endif
        return "다른 네트워크에 있을 수 있어요."
    }

    private var titleFont: Font {
        #if DEBUG
        if isShowingPartnerLanguage {
            return AppTypography.h2
        }
        #endif
        return AppTypography.h2Korean
    }

    private var bodyFont: Font {
        #if DEBUG
        if isShowingPartnerLanguage {
            return AppTypography.b2
        }
        #endif
        return AppTypography.b2Korean
    }

    private var h3Font: Font {
        #if DEBUG
        if isShowingPartnerLanguage {
            return AppTypography.h3
        }
        #endif
        return AppTypography.h3Korean
    }

    private var b3Font: Font {
        #if DEBUG
        if isShowingPartnerLanguage {
            return AppTypography.b3
        }
        #endif
        return AppTypography.b3Korean
    }

    // Join mode localized text (Korean → English for partner)
    private var scanQRText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "Scan their QR code:"
        }
        #endif
        return "QR 코드를 스캔하세요:"
    }

    private var cameraNotAvailableSimulatorText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "Camera not available in Simulator"
        }
        #endif
        return "시뮬레이터에서 카메라를 사용할 수 없습니다"
    }

    private var cameraNotAvailableText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "Camera not available"
        }
        #endif
        return "카메라를 사용할 수 없습니다"
    }

    private var manualEntryText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "Not scanning? Enter in their code."
        }
        #endif
        return "스캔이 안 되나요? 코드를 입력하세요."
    }

    private var verifyingCodeText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "Verifying code..."
        }
        #endif
        return "코드 확인 중..."
    }

    private var invalidCodeText: String {
        #if DEBUG
        if isShowingPartnerLanguage {
            return "Invalid code. Please try again."
        }
        #endif
        return "잘못된 코드입니다. 다시 시도해 주세요."
    }

    private var backgroundElementsOpacity: Double {
        isCodeFieldFocused ? 1.0 : 0.9
    }

    #if DEBUG
    private var mainContentOpacity: Double {
        showPartnerJoinView ? 0 : 1
    }
    #endif

    var body: some View {
        GeometryReader { geometry in
            let topPadding = geometry.size.height * 0.225

            ZStack {
                ZStack(alignment: .top) {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(
                                            key: ScrollOffsetPreferenceKey.self,
                                            value: geo.frame(in: .named("manualPairingScrollKorean")).minY
                                        )
                                }
                                .frame(height: 0)
                                .id("topAnchorKorean")

                                // Title
                                Text(titleText)
                                    .font(titleFont)
                                    .lineSpacing(38 - 28)
                                    .tracking(0.672)
                                    .foregroundColor(AppColors.primaryText)

                                // Subtitle
                                Text(subtitleText)
                                    .font(bodyFont)
                                    .foregroundColor(AppColors.primaryText)
                                    .lineSpacing(22 - 17)
                                    .tracking(0.37)
                                    .padding(.top, AppSpacing.headerBody)

                                // Mode-specific content
                                if effectiveMode == .create {
                                    createModeContentKorean
                                } else {
                                    joinModeContentKorean
                                }

                                // Spacer to position code entry above keyboard (40px clearance)
                                if keyboardObserver.isKeyboardVisible {
                                    Spacer()
                                        .frame(height: 40)
                                        .id("bottomSpacerKorean")
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, topPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if keyboardObserver.isKeyboardVisible {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    isCodeFieldFocused = false
                                }
                            }
                        }
                        .coordinateSpace(name: "manualPairingScrollKorean")
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollDisabled(!keyboardObserver.isKeyboardVisible)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Dismiss keyboard when tapping outside code boxes
                            if isCodeFieldFocused {
                                isCodeFieldFocused = false
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }
                        }
                    .onChange(of: isCodeFieldFocused) { _, focused in
                        if focused && keyboardObserver.isKeyboardVisible {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("codeEntryFieldKorean", anchor: .bottom)
                            }
                        } else if !focused {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("topAnchorKorean", anchor: .top)
                            }
                        }
                    }
                    .onChange(of: keyboardObserver.isKeyboardVisible) { _, visible in
                        if visible && isCodeFieldFocused {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    proxy.scrollTo("codeEntryFieldKorean", anchor: .bottom)
                                }
                            }
                        } else if !visible {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("topAnchorKorean", anchor: .top)
                            }
                        }
                    }
                }

                // Top fade gradient (Join mode only)
                if showTopGradient && effectiveMode == .join {
                    VStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                .init(color: AppColors.background.opacity(1.0), location: 0.0),
                                .init(color: AppColors.background.opacity(0.6), location: 0.66),
                                .init(color: AppColors.background.opacity(0.25), location: 0.84),
                                .init(color: AppColors.background.opacity(0.0), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 200)
                        Spacer()
                    }
                    .ignoresSafeArea(.all, edges: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            #if DEBUG
            .opacity(mainContentOpacity)
            .animation(.easeInOut(duration: 0.3), value: showPartnerJoinView)
            #endif

            // Back button
            VStack {
                HStack {
                    BackButton {
                        #if DEBUG
                        if showPartnerJoinView {
                            // Navigate to pairing screen when viewing partner's screen
                            showPartnerJoinView = false
                            onBackTapped?()
                        } else {
                            onBackTapped?()
                        }
                        #else
                        onBackTapped?()
                        #endif
                    }
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.top, 40)
                Spacer()
            }
            #if DEBUG
            .opacity(mainContentOpacity)
            .animation(.easeInOut(duration: 0.3), value: showPartnerJoinView)
            #endif

            // DEBUG: Collapsible controls
            #if DEBUG
            if !showPartnerJoinView {
                VStack {
                    Spacer()
                    if debugCollapsed {
                        // Collapsed state - just a small toggle button
                        HStack {
                            Spacer()
                            Button(action: { debugCollapsed = false }) {
                                Image(systemName: "ladybug.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        Circle()
                                            .fill(Color.orange.opacity(0.8))
                                    )
                            }
                            .padding(.trailing, 20)
                        }
                    } else {
                        debugControlsPanelManualKorean
                            .padding(.horizontal, 20)
                    }
                    Spacer().frame(height: 40)
                }
            }

            // English Join view overlay (fades in when showPartnerJoinView is true)
            // Back button navigates to pairing screen (same as real flow)
            if showPartnerJoinView {
                ManualPairingScreen(
                    sessionMode: .join,
                    roomCode: roomCode,
                    onBackTapped: {
                        // Navigate to pairing screen (resets WiFi timer)
                        showPartnerJoinView = false
                        onBackTapped?()
                    },
                    onSuccess: { roomId in
                        showPartnerJoinView = false
                        onSuccess?(roomId)
                    }
                )
                .transition(.opacity)
            }
            #endif
        }
            .onChange(of: qrScanner.scannedCode) { _, code in
                if let code = code, !code.isEmpty {
                    handleScannedCode(code)
                }
            }
            .onAppear {
                #if DEBUG
                if effectiveMode == .create && sharedCodeManager.generatedRoomCode.isEmpty {
                    sharedCodeManager.generateNewCode(language: "ko")
                }
                #endif
            }
        }
    }

    // MARK: - Debug Controls (Korean Manual Pairing)
    #if DEBUG
    private var debugControlsPanelManualKorean: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "ladybug.fill")
                    .foregroundColor(.orange)
                Text("Debug: Mode Switch")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { debugCollapsed = true }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button(action: {
                    debugSessionMode = .create
                    sharedCodeManager.generateNewCode(language: "ko")
                }) {
                    Text("🇰🇷 Create")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(effectiveMode == .create ? .white : .primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(effectiveMode == .create ? Color.orange : Color.gray.opacity(0.2))
                        )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    // Fade to English Join view (partner's perspective)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showPartnerJoinView = true
                    }
                }) {
                    Text("🇺🇸 Join")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Display generated code for testing (when in Join mode with a code generated)
            if !sharedCodeManager.generatedRoomCode.isEmpty {
                HStack {
                    Text("Test Code:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(sharedCodeManager.generatedRoomCode)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                    Text("(\(sharedCodeManager.generatorLanguage.uppercased()))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        UIPasteboard.general.string = sharedCodeManager.generatedRoomCode
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Quick success button for testing
            Button(action: {
                onSuccess?("DEBUG-ROOM-\(enteredCode.isEmpty ? roomCode : enteredCode)")
            }) {
                Text("→ Simulate Success")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green)
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    #endif

    // MARK: - Create Mode Content (Korean)
    private var createModeContentKorean: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("QR 코드를 보여주세요:")
                .font(AppTypography.h3Korean)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, 32)

            // QR Code (uses cached image to prevent flickering)
            if let qrImage = cachedQRImage {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppColors.cardFill.opacity(0.95))
                        .frame(width: 242, height: 242)
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 228, height: 228)
                }
                .codeBoxShadow()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            }

            Text("또는 이 코드를 공유하세요:")
                .font(AppTypography.b2Korean)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, 76)

            HStack(alignment: .center) {
                Text(spacedDisplayCode)
                    .font(AppTypography.codeEntry)
                    .foregroundColor(AppColors.primaryText)
                    .padding(.leading, 6)
                Spacer()
                CopyButton(showCopiedFeedback: showCopiedFeedback, action: copyCode)
                    .padding(.trailing, 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 16)
            .frame(width: 242)
            .background(AppColors.cardFill.opacity(0.95))
            .cornerRadius(8)
            .codeBoxShadow()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
        }
        .onAppear {
            // Generate QR code once and cache it
            if cachedQRImage == nil {
                cachedQRImage = generateQRCode(from: displayCode)
            }
        }
        .onChange(of: displayCode) { _, newCode in
            // Regenerate if code changes
            cachedQRImage = generateQRCode(from: newCode)
        }
    }

    // MARK: - Join Mode Content (Korean)
    private var joinModeContentKorean: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Camera Section
            Text(scanQRText)
                .font(h3Font)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, 32)

            // Camera container (semi-transparent to show surroundings, full opacity when code entry focused)
            ZStack {
                // Container background with conditional opacity (90% normally, 100% when code focused)
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppColors.cardFill.opacity(0.95 * backgroundElementsOpacity))
                    .frame(width: 353, height: 200)

                // Container border with same conditional opacity
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.05 * backgroundElementsOpacity), lineWidth: 1)
                    .frame(width: 353, height: 200)

                // Camera viewfinder (329x176 - 12px padding) - always full opacity
                #if targetEnvironment(simulator)
                // Simulator: Show placeholder with semi-transparent background
                VStack(spacing: 12) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 48))
                        .foregroundColor(AppColors.secondaryText)
                    Text(cameraNotAvailableSimulatorText)
                        .font(b3Font)
                        .foregroundColor(AppColors.secondaryText)
                }
                .frame(width: 329, height: 176)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                #else
                // Real device: Show camera viewfinder at full opacity
                if isCameraAvailable {
                    QRScannerView(scanner: qrScanner, isReady: qrScanner.isReady)
                        .frame(width: 329, height: 176)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // Fallback if camera not available on device
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 48))
                            .foregroundColor(AppColors.secondaryText)
                        Text(cameraNotAvailableText)
                            .font(b3Font)
                            .foregroundColor(AppColors.secondaryText)
                    }
                    .frame(width: 329, height: 176)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                #endif
            }
            .codeBoxShadow()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .animation(.easeInOut(duration: 0.25), value: backgroundElementsOpacity)
            .onTapGesture {
                // Dismiss keyboard when tapping camera area - scroll will revert automatically
                if isCodeFieldFocused {
                    isCodeFieldFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }

            // Manual Code Entry Section - 60pt below camera (same as Create mode)
            Text(manualEntryText)
                .font(bodyFont)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, 76)

            // Code Entry Field
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { index in
                        CodeDigitBox(
                            digit: getDigit(at: index),
                            isFocused: isCodeFieldFocused && enteredCode.count == index && !showErrorGlow,
                            isError: showErrorGlow,
                            isAnimatingOut: isAnimatingOut,
                            backgroundOpacity: backgroundElementsOpacity
                        )
                    }
                }
                .offset(x: shakeOffset)
                .animation(.easeInOut(duration: 0.25), value: backgroundElementsOpacity)
                .background(
                    UIKitTextField(
                        text: $enteredCode,
                        isFirstResponder: $isCodeFieldFocused,
                        onDigitEntered: { triggerHaptic() },
                        onComplete: { handleEnteredCode() },
                        onTextChange: { oldValue, newValue in
                            // Clear error states when user starts typing
                            if newValue.count > oldValue.count {
                                if showError { showError = false }
                                if showErrorGlow { showErrorGlow = false }
                            }
                        }
                    )
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    isCodeFieldFocused = true
                    UIKitTextField.focus()
                }

                // Status message (inside the VStack so it scrolls with code boxes)
                statusMessageViewKorean
            }
            .padding(.top, 16)
            .padding(.bottom, 12)  // Extra padding to push content higher when scrolled
            .id("codeEntryFieldKorean")

        }
        .onAppear {
            // Only start camera when Join mode content appears and camera is available
            if isCameraAvailable {
                qrScanner.startIfNeeded()
            }
        }
        .onDisappear {
            if isCameraAvailable {
                qrScanner.stopScanning()
            }
        }
    }

    @ViewBuilder
    private var statusMessageViewKorean: some View {
        HStack(spacing: 8) {
            if isConnecting {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(AppColors.secondaryIcon)
                Text(verifyingCodeText)
                    .font(AppTypography.subtextKorean)
                    .foregroundColor(AppColors.secondaryText)
            } else if showError {
                Text(invalidCodeText)
                    .font(AppTypography.subtextKorean)
                    .foregroundColor(AppColors.errorRed)
            }
        }
        .padding(.top, 14)
        .animation(.easeInOut(duration: 0.2), value: isConnecting)
        .animation(.easeInOut(duration: 0.2), value: showError)
    }

    // Helper methods
    private var isCameraAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    private var displayCode: String {
        #if DEBUG
        if !sharedCodeManager.generatedRoomCode.isEmpty {
            return sharedCodeManager.generatedRoomCode
        }
        #endif
        return roomCode
    }

    private var spacedDisplayCode: String {
        return displayCode.map { String($0) }.joined(separator: " ")
    }

    private func getDigit(at index: Int) -> String {
        guard index < enteredCode.count else { return "" }
        let charIndex = enteredCode.index(enteredCode.startIndex, offsetBy: index)
        return String(enteredCode[charIndex])
    }

    private func copyCode() {
        UIPasteboard.general.string = displayCode
        showCopiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedFeedback = false
        }
    }

    private func handleEnteredCode() {
        guard enteredCode.count == 6, !isConnecting else { return }
        isConnecting = true

        // Don't dismiss keyboard yet - keep it up during validation

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let isValid: Bool
            if !sharedCodeManager.generatedRoomCode.isEmpty {
                isValid = sharedCodeManager.validateCode(enteredCode)
            } else {
                isValid = !enteredCode.hasPrefix("9")
            }

            if !isValid {
                isConnecting = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    showError = true
                    showErrorGlow = true
                }
                triggerErrorHaptic()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isAnimatingOut = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        enteredCode = ""
                        isAnimatingOut = false
                        // First box becomes active again, keyboard stays up
                        isCodeFieldFocused = true
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showErrorGlow = false
                    }
                }
                return
            }

            // Success - dismiss keyboard and navigate
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            isCodeFieldFocused = false
            showError = false
            showErrorGlow = false
            onSuccess?(enteredCode)
        }
    }

    private func handleScannedCode(_ code: String) {
        qrScanner.stopScanning()
        enteredCode = code.filter { $0.isNumber }.prefix(6).description
        handleEnteredCode()
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let ciImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: transform)
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func triggerHaptic() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
    }

    private func triggerErrorHaptic() {
        let notificationFeedback = UINotificationFeedbackGenerator()
        notificationFeedback.notificationOccurred(.error)
    }
}

// Korean version of SetupSuccessScreen
struct SetupSuccessScreenKorean: View {
    let roomId: String
    var onProceed: (() -> Void)?
    var onBackTapped: (() -> Void)?

    @State private var hasProceeded = false
    @State private var circleScale: CGFloat = 1.0
    @State private var checkmarkProgress: CGFloat = 0.0

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                // Success checkmark
                ZStack {
                    Circle()
                        .fill(AppColors.lightGreen.opacity(0.6))
                        .frame(width: 48, height: 48)
                        .scaleEffect(circleScale)
                    Circle()
                        .fill(AppColors.successGreen)
                        .frame(width: 36, height: 36)
                    CheckmarkShape()
                        .trim(from: 0, to: checkmarkProgress)
                        .stroke(AppColors.whiteIcon, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(width: 18, height: 18)
                }
                .frame(width: 48, height: 48)

                Text("준비 완료!")
                    .font(AppTypography.h2Korean)
                    .lineSpacing(38 - 28)
                    .tracking(0.672)
                    .foregroundColor(AppColors.primaryText)
                    .padding(.top, 20)

                Text("번역 세션을 시작합니다.")
                    .font(AppTypography.b2Korean)
                    .foregroundColor(AppColors.primaryText)
                    .lineSpacing(22 - 17)
                    .tracking(0.37)
                    .padding(.top, 8)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, AppSpacing.welcomeContentStart)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            #if DEBUG
            VStack {
                HStack {
                    BackButton {
                        hasProceeded = true
                        onBackTapped?()
                    }
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.top, 40)
                Spacer()
            }
            #endif
        }
        .onAppear {
            // Start animations 0.5 seconds after content loads
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                startSuccessAnimation()
            }

            // Auto-proceed after 3.5 seconds (3s after animation starts)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                guard !hasProceeded else { return }
                hasProceeded = true
                onProceed?()
            }
        }
    }

    private func startSuccessAnimation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                circleScale = 1.25
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    circleScale = 1.0
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.4)) {
                checkmarkProgress = 1.0
            }
        }
    }
}

// MARK: - Pairing Flow Container

struct PairingFlowContainer: View {
    var direction: String = "ko_to_en"
    var sessionMode: SessionMode = .join
    var onBackTapped: (() -> Void)?
    var onComplete: ((String) -> Void)?  // Pass room id to translation screen

    enum Screen {
        case pairing
        case manual(roomCode: String)
        case success(roomId: String)
        case liveTranslation(roomId: String)
    }

    @State private var currentScreen: Screen = .pairing

    var body: some View {
        ZStack {
            switch currentScreen {
            case .pairing:
                PairingScreen(
                    direction: direction,
                    onBackTapped: onBackTapped,
                    onManualPairing: { roomCode in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .manual(roomCode: roomCode)
                        }
                    },
                    onSuccess: { roomId in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .success(roomId: roomId)
                        }
                    }
                )
                .transition(.opacity)

            case .manual(let roomCode):
                ManualPairingScreen(
                    sessionMode: sessionMode,
                    roomCode: roomCode,
                    onBackTapped: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .pairing
                        }
                    },
                    onSuccess: { roomId in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .success(roomId: roomId)
                        }
                    }
                )
                .transition(.opacity)

            case .success(let roomId):
                SetupSuccessScreen(
                    roomId: roomId,
                    onProceed: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .liveTranslation(roomId: roomId)
                        }
                    },
                    onBackTapped: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            currentScreen = .pairing
                        }
                    }
                )
                .transition(.opacity)

            case .liveTranslation(let roomId):
                LiveTranslationScreen(roomId: roomId)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Preview

#Preview("Pairing Screen") {
    PairingScreen()
}

#Preview("Manual Pairing - Create") {
    ManualPairingScreen(sessionMode: .create, roomCode: "208098")
}

#Preview("Manual Pairing - Join") {
    ManualPairingScreen(sessionMode: .join, roomCode: "208098")
}

#Preview("Success Screen") {
    SetupSuccessScreen(roomId: "ABC123")
}

#Preview("Live Translation") {
    LiveTranslationScreen(roomId: "ABC123")
}
