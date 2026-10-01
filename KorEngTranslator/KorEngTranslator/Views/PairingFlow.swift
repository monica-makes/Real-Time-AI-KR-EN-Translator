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
    /// Why the last join_room attempt failed (nil while none has); reset on every attempt
    @Published var joinFailure: JoinFailure? = nil
    /// True while the server holds the code offered with createRoom (a partner can join it)
    @Published var isCodeRegistered = false
    /// Why the last create_room attempt failed (nil while none has); reset on every attempt
    @Published var createFailure: CreateFailure? = nil

    enum JoinFailure: Equatable {
        case unknownCode  // The server knows no live creator for that code
        case connection   // Couldn't reach the server
    }

    enum CreateFailure: Equatable {
        case codeInUse    // Another live creator holds that code; offer a different one
        case rejected     // The server refused the code for another reason
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var direction: String
    private var manualMode = false
    private var connectionTimeoutTask: Task<Void, Never>?
    private var joinTimeoutTask: Task<Void, Never>?
    private var reregisterTask: Task<Void, Never>?
    /// Reported as soon as the socket is up (the screen's headphone state at connect time)
    private var initialHeadphoneStatus: Bool?
    /// Sent as soon as the socket is up (manual pairing)
    private var pendingCreateCode: String?
    private var pendingJoinCode: String?
    /// The code we are offering (registered, or being registered); re-offered after a dropped socket
    private var offeredCode: String?

    init(direction: String = "ko_to_en") {
        self.direction = Self.protocolDirection(direction)
    }

    /// Onboarding says "en_to_kr" / "kr_to_en"; the protocol (and /ws/pair matching) says "en_to_ko" / "ko_to_en"
    static func protocolDirection(_ raw: String) -> String {
        switch raw {
        case "en_to_kr", "en_to_ko":
            return "en_to_ko"
        case "kr_to_en", "ko_to_en":
            return "ko_to_en"
        default:
            return raw
        }
    }

    /// Connect for Wi-Fi pairing.
    /// - Parameters:
    ///   - direction: This user's direction (onboarding or protocol spelling); replaces the init value
    ///   - headphonesConnected: Current headphone state, reported right after connecting so a phone
    ///     whose headphones were already on doesn't wait for a route change to count as ready
    ///   - serverIP: Optional host override (defaults to ServerConfig.host)
    func connect(
        direction: String? = nil,
        headphonesConnected: Bool? = nil,
        serverIP: String? = nil,
        timeoutSeconds: Double = 8.0
    ) {
        if let direction {
            self.direction = Self.protocolDirection(direction)
        }
        initialHeadphoneStatus = headphonesConnected
        pendingCreateCode = nil
        pendingJoinCode = nil
        manualMode = false
        open(serverIP: serverIP, timeoutSeconds: timeoutSeconds)
    }

    /// Manual pairing: register `code` so a partner can join it. `shouldNavigateToSuccess` /
    /// `roomId` follow once someone does.
    func createRoom(code: String, direction: String? = nil, serverIP: String? = nil) {
        if let direction {
            self.direction = Self.protocolDirection(direction)
        }
        // Same code while a manual connection is still coming up (onAppear followed by
        // onChange(of: displayCode)): the pending request already carries it
        if manualMode && webSocketTask != nil && !isConnected && pendingCreateCode == code {
            return
        }
        createFailure = nil
        if offeredCode != code {
            isCodeRegistered = false
        }
        offeredCode = code
        pendingCreateCode = code
        pendingJoinCode = nil
        if isConnected && manualMode {
            sendJSON(["type": "create_room", "room_code": code])
            return
        }
        manualMode = true
        open(serverIP: serverIP, timeoutSeconds: 8.0)
    }

    /// Manual pairing: join the partner who created `code`. Watch `shouldNavigateToSuccess`
    /// (matched, `roomId` set) and `joinFailure`.
    func joinRoom(code: String, direction: String? = nil, serverIP: String? = nil, timeoutSeconds: Double = 10.0) {
        if let direction {
            self.direction = Self.protocolDirection(direction)
        }
        joinFailure = nil
        pendingJoinCode = code
        pendingCreateCode = nil
        offeredCode = nil
        if isConnected && manualMode {
            sendJSON(["type": "join_room", "room_code": code])
        } else {
            manualMode = true
            open(serverIP: serverIP, timeoutSeconds: 8.0)  // disconnect() inside cancels older timers
        }
        // A join the server never answers fails like an unreachable server, so the screen
        // doesn't stay on "verifying" forever. Armed after open(), which cancels older timers.
        joinTimeoutTask?.cancel()
        joinTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            } catch {
                return  // Cancelled: a newer attempt, an answer, or disconnect()
            }
            await MainActor.run {
                guard let self, !Task.isCancelled, self.pendingJoinCode == code else { return }
                print("[PairingWS] Join timed out after \(timeoutSeconds)s")
                self.pendingJoinCode = nil
                self.joinFailure = .connection
            }
        }
    }

    /// Re-offer the current code on a fresh socket after the previous one dropped
    private func scheduleReregister(after seconds: Double) {
        reregisterTask?.cancel()
        reregisterTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            await MainActor.run {
                guard let self, !Task.isCancelled, let code = self.offeredCode,
                      self.webSocketTask == nil, !self.shouldNavigateToSuccess else { return }
                print("[PairingWS] Re-offering room code \(code)")
                self.pendingCreateCode = nil  // force a fresh connection in createRoom
                self.createRoom(code: code)
            }
        }
    }

    private func open(serverIP: String?, timeoutSeconds: Double) {
        let urlString = ServerConfig.pairURL(direction: direction, host: serverIP, manual: manualMode)
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
        connectionTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            } catch {
                return  // Cancelled by a newer open() or disconnect()
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
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
                    self.sendPendingRequests()
                }
            }
        }

        receiveMessage()
    }

    /// Everything the screen asked for before the socket was up
    private func sendPendingRequests() {
        if let headphones = initialHeadphoneStatus {
            sendHeadphoneStatus(connected: headphones)
        }
        if let code = pendingCreateCode {
            sendJSON(["type": "create_room", "room_code": code])
        }
        if let code = pendingJoinCode {
            sendJSON(["type": "join_room", "room_code": code])
        }
    }

    private func handleConnectionFailure() {
        if manualMode {
            // A join that can't reach the server fails like a wrong code; a create just stays unregistered
            if pendingJoinCode != nil {
                pendingJoinCode = nil
                joinFailure = .connection
            }
            return
        }
        connectionTimedOut = true
        // Generate a room code for manual pairing
        roomCode = String(format: "%06d", Int.random(in: 0...999999))
        shouldNavigateToManual = true
    }

    func disconnect() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        joinTimeoutTask?.cancel()
        joinTimeoutTask = nil
        reregisterTask?.cancel()
        reregisterTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        isCodeRegistered = false
    }

    /// Stop offering the current code (the screen is going away)
    func cancelOffer() {
        offeredCode = nil
        disconnect()
    }

    func sendHeadphoneStatus(connected: Bool) {
        guard isConnected else { return }
        sendJSON(["type": "headphone_status", "connected": connected])
    }

    private func sendJSON(_ message: [String: Any]) {
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
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                // Ignore results from a socket we already closed or replaced (re-connect),
                // otherwise its cancellation error would fail the new attempt
                guard let self, self.webSocketTask === task else { return }
                self.handleReceiveResult(result)
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
            isCodeRegistered = false
            webSocketTask = nil
            if pendingJoinCode != nil {
                pendingJoinCode = nil
                joinTimeoutTask?.cancel()
                joinFailure = .connection
            }
            // A creator's code lives on its socket: get it back on a new one
            if manualMode && offeredCode != nil && !shouldNavigateToSuccess {
                scheduleReregister(after: 2.0)
            }
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

        case "partner_disconnected":
            pairingState = .waitingForPartner
            partnerStatus = .waiting

        case "matched":
            roomId = json["room_id"] as? String
            pendingJoinCode = nil
            pendingCreateCode = nil
            joinTimeoutTask?.cancel()
            reregisterTask?.cancel()
            pairingState = .matched
            shouldNavigateToSuccess = true

        case "no_match":
            roomCode = json["room_code"] as? String
            shouldNavigateToManual = true

        case "room_created":
            pendingCreateCode = nil
            roomCode = json["room_code"] as? String
            isCodeRegistered = roomCode == offeredCode
            print("[PairingWS] Room code registered: \(roomCode ?? "-")")

        case "create_failed":
            pendingCreateCode = nil
            isCodeRegistered = false
            let reason = json["reason"] as? String ?? "-"
            print("[PairingWS] Could not register room code: \(reason)")
            createFailure = reason == "code_in_use" ? .codeInUse : .rejected

        case "join_failed":
            pendingJoinCode = nil
            joinTimeoutTask?.cancel()
            print("[PairingWS] Join failed: \(json["reason"] as? String ?? "-")")
            joinFailure = .unknownCode

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
    #if targetEnvironment(simulator)
    @State private var debugMode = true   // Simulator: no real pairing, use the debug controls
    #else
    @State private var debugMode = RecordingDemo.isPairingDemo  // Device: pair for real (the toggle below still switches), except in the recording demo
    #endif
    @State private var debugHeadphonesConnected = RecordingDemo.startsWithHeadphones  // pairing demo
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
            // Content (background and gradient provided by parent WelcomeScreenLangSelect), placed by
            // PartnerSearchLayoutTuning: the title at home's title top, the loading dots 12pt under it,
            // the subtitle 20pt under the dots, the card at home's Card Y and card height
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    // Title
                    Text("Looking for your partner.")
                        .font(AppTypography.h2)
                        .lineSpacing(39 - 28)
                        .tracking(0.672)
                        .foregroundColor(AppColors.primaryText)

                    // Loading dots
                    BouncingDots()
                        .padding(.top, PartnerSearchLayoutTuning.shared.titleDotsGap)

                    // Subtitle
                    Text("You'll both need the same WiFi\nand a pair of headphones.")
                        .font(AppTypography.b2)
                        .foregroundColor(AppColors.primaryText)
                        .lineSpacing(PartnerSearchLayoutTuning.shared.bodyLineSpacing)
                        .tracking(0.37)
                        .padding(.top, PartnerSearchLayoutTuning.shared.dotsBodyGap)
                }
                .padding(.top, PartnerSearchLayoutTuning.shared.titleTop)

                // Headphone status card
                PairingHeadphoneStatusCard(
                    isConnected: effectiveHeadphoneStatus,
                    onTap: {
                        openBluetoothSettings()
                    }
                )
                .padding(.top, PartnerSearchLayoutTuning.shared.cardTop)

                // Manual pairing button - at the bottom, like the Korean page
                VStack(spacing: 0) {
                    Spacer()
                    Button(action: {
                        let roomCode = String(format: "%06d", Int.random(in: 0...999999))
                        onManualPairing?(roomCode)
                    }) {
                        Text("Can't find your partner?")
                            .font(AppTypography.b2)
                            .foregroundColor(AppColors.secondaryText)
                            // Rolls in letter by letter, left to right, once the search has run 20s
                            .staggeredReveal(delay: 20)
                    }
                    .padding(.bottom, 44)
                }
                // Centered, 44pt above the screen's bottom edge
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .bottom)
            }
            .padding(.horizontal, 20)
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
                .padding(.top, LiveLayoutTuning.shared.languagesTop)  // level with the live screen's language row
                Spacer()
            }

            // DEBUG: Explicit controls panel at bottom (folds into a ladybug), and the layout panel
            #if DEBUG
            CollapsibleDebugControls {
                debugControlsPanel
            }
            PartnerSearchLayoutPanel()
            #endif
        }
        .onAppear {
            #if DEBUG
            if !debugMode {
                pairingManager.connect(direction: direction, headphonesConnected: effectiveHeadphoneStatus)
                startHeadphoneAlertTimer()
            }
            #else
            pairingManager.connect(direction: direction, headphonesConnected: effectiveHeadphoneStatus)
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
        #if DEBUG
        .pairingDemoSearch(headphones: $debugHeadphonesConnected) { onSuccess?($0) }
        #endif
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
                            pairingManager.connect(direction: direction, headphonesConnected: effectiveHeadphoneStatus)
                        }
                    }
            }

            // Pairing mode (remembered): Starter / Joiner jumps to the Create/Join choice
            PairingModeDebugPicker { mode in
                if mode == .starterJoiner {
                    onManualPairing?("")
                }
            }

            TypographyDebugPicker()

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
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    #endif

    private func openBluetoothSettings() {
        #if DEBUG
        if RecordingDemo.openFakeBluetoothSettings() { return }  // English pairing demo
        #endif
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
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
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
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
                    // Glass rim sits under the outlines so it can't cover them
                    .overlay(GlassEdgeRim())
                    .overlay(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
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
                RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
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
                    .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadius))

                // Content - icon at top, title/subtitle at bottom (same layout as GetStartedCard)
                VStack(alignment: .leading, spacing: 0) {
                    // Icon at top - swaps when the check succeeds (IconSwap), with the text below
                    ZStack {
                        Image("not-connected-headphones-color")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 60)
                            .iconSwapShown(!isConnected)
                        Image("headphones-connected-color")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 60)
                            .iconSwapShown(isConnected)
                    }
                    .animation(reduceMotion ? nil : IconSwap.animation, value: isConnected)

                    Spacer()

                    // Title - grows upward from subtitle; text-swaps with the icon
                    SwappingText(isConnected ? "Headphones connected" : "No headphones connected") {
                        Text($0)
                            .font(AppTypography.b1)
                            .tracking(0.48)
                            .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                    }
                    .padding(.bottom, 6)

                    // Subtitle - fixed at bottom
                    SwappingText(isConnected ? "You're ready to go!" : "Tap here to connect them now") {
                        Text($0)
                            .font(AppTypography.b3)
                            .tracking(0.33)
                            .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)  // fills the row, 20pt margins
            .frame(height: HomeLayoutTuning.shared.cardHeight)  // same height as the language cards
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
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
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
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
                    // Glass rim sits under the outlines so it can't cover them
                    .overlay(GlassEdgeRim())
                    .overlay(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
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
                RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
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
                    .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadius))

                // Content - icon at top, title/subtitle at bottom
                VStack(alignment: .leading, spacing: 0) {
                    // Icon at top - swaps when the check succeeds (IconSwap), with the text below
                    ZStack {
                        Image("not-connected-headphones-color")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 60)
                            .iconSwapShown(!isConnected)
                        Image("headphones-connected-color")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 60)
                            .iconSwapShown(isConnected)
                    }
                    .animation(reduceMotion ? nil : IconSwap.animation, value: isConnected)

                    Spacer()

                    // Title - Korean; text-swaps with the icon
                    SwappingText(isConnected ? "헤드폰 연결됨" : "헤드폰이 연결되지 않았어요") {
                        Text($0)
                            .font(AppTypography.b1Korean)
                            .tracking(0.48)
                            .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                    }
                    .padding(.bottom, 6)

                    // Subtitle - Korean
                    SwappingText(isConnected ? "준비 완료!" : "여기를 눌러 연결하세요") {
                        Text($0)
                            .font(AppTypography.b3Korean)
                            .lineSpacing(21 - 14)  // line height 21
                            .tracking(0.33)
                            .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)  // fills the row, 20pt margins
            .frame(height: HomeLayoutTuning.shared.cardHeight)  // same height as the language cards
        }
        .buttonStyle(PlainButtonStyle())
        .allowsHitTesting(!isConnected)
        .animation(.easeInOut(duration: 0.3), value: isConnected)
    }
}

// MARK: - Screen 2: ManualPairingScreen

struct ManualPairingScreen: View {
    /// Tops and gaps for both modes (tunable from the Debug layout panel)
    private var pairingLayout: PairingLayoutTuning { .shared }
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
    @StateObject private var pairingManager = PairingWebSocketManager()

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
            // Each mode's title top (PairingLayoutTuning)
            let topPadding = effectiveMode == .create ? pairingLayout.createTop : pairingLayout.joinTop

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
                                    .padding(.top, PairingLayoutTuning.titleBodyGap - HomeLayoutTuning.bodyLiftAfterHome)

                                // Mode-specific content
                                if effectiveMode == .create {
                                    createModeContent(pageWidth: geometry.size.width)
                                } else {
                                    joinModeContent(pageWidth: geometry.size.width)
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
                .padding(.top, LiveLayoutTuning.shared.languagesTop)  // level with the live screen's language row
                Spacer()
            }
            #if DEBUG
            .opacity(mainContentOpacity)
            .animation(.easeInOut(duration: 0.3), value: showPartnerJoinView)
            #endif

            // DEBUG: layout panel (ruler, bottom left) - the whole unit's top, then each gap
            #if DEBUG
            if !showPartnerJoinView {
                PairingLayoutDebugPanel(isCreate: effectiveMode == .create)
            }
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
                // Create mode: make a code and register it with the server so the partner can join it
                if effectiveMode == .create {
                    if sharedCodeManager.generatedRoomCode.isEmpty {
                        sharedCodeManager.generateNewCode(language: "en")
                    }
                    pairingManager.createRoom(code: displayCode, direction: "en_to_ko")
                }
            }
            .onDisappear {
                pairingManager.cancelOffer()
            }
            .onChange(of: displayCode) { _, newCode in
                // The debug "Create" button makes a fresh code; offer that one instead
                if effectiveMode == .create {
                    pairingManager.createRoom(code: newCode, direction: "en_to_ko")
                }
            }
            .onChange(of: pairingManager.createFailure) { _, failure in
                // Someone else is offering the same code right now: show a different one
                if failure == .codeInUse, effectiveMode == .create {
                    sharedCodeManager.generateNewCode(language: "en")
                }
            }
            .onChange(of: pairingManager.shouldNavigateToSuccess) { _, matched in
                // The partner joined our code, or the server accepted the code we entered
                if matched, let roomId = pairingManager.roomId {
                    joinSucceeded(roomId: roomId)
                }
            }
            .onChange(of: pairingManager.joinFailure) { _, failure in
                if let failure, isConnecting {
                    joinFailed(failure)
                }
            }
        }
    }

    // MARK: - Create Mode Content

    private func createModeContent(pageWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // QR Code Section Label
            Text("Show this QR code:")
                .font(AppTypography.h3)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, PairingLayoutTuning.labelGap + HomeLayoutTuning.bodyLiftAfterHome)  // stays put as the subtitle lifts

            // QR Code - 20% smaller than full width and left-aligned like the code box below
            // (uses cached image to prevent flickering)
            if let qrImage = cachedQRImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(1, contentMode: .fit)
                    .containerRelativeFrame(.horizontal) { width, _ in (width - 72) * 0.8 }  // 20pt page + 16pt card padding a side
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
                            .fill(AppColors.cardFill.opacity(0.95))
                    )
                    .codeBoxShadow()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, PairingLayoutTuning.squareGap)
            }

            // Code Section Label
            Text("Or share this code:")
                .font(AppTypography.b2)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, pairingLayout.shareGap)

            // Code Display Card
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
            // As wide as the QR box above: its QR ((width - 72) * 0.8) plus 16pt padding a side
            .containerRelativeFrame(.horizontal) { width, _ in (width - 72) * 0.8 + 32 }
            .background(AppColors.cardFill.opacity(0.95))
            .cornerRadius(AppStyle.smallCornerRadius)
            .codeBoxShadow()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PairingLayoutTuning.codeGap)
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

    private func joinModeContent(pageWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Camera Section
            Text(scanQRText)
                .font(h3Font)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, PairingLayoutTuning.labelGap + HomeLayoutTuning.bodyLiftAfterHome)  // stays put as the subtitle lifts

            // Camera container (semi-transparent to show surroundings, full opacity when code entry focused)
            ZStack {
                // The home screen cards' glass surface, a little see-through until the code entry is focused
                GlassCardBackground()
                    .opacity(backgroundElementsOpacity)
                    .frame(width: PairingLayoutTuning.cameraSide(pageWidth: pageWidth),
                           height: PairingLayoutTuning.cameraSide(pageWidth: pageWidth))

                // Camera viewfinder (square, 12pt inside the box) - always full opacity
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
                .frame(width: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth), height: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth))
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: PairingLayoutTuning.viewfinderRadius))
                #else
                // Real device: Show camera viewfinder at full opacity
                if isCameraAvailable {
                    QRScannerView(scanner: qrScanner, isReady: qrScanner.isReady)
                        .frame(width: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth), height: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth))
                        .clipShape(RoundedRectangle(cornerRadius: PairingLayoutTuning.viewfinderRadius))
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
                    .frame(width: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth), height: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth))
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: PairingLayoutTuning.viewfinderRadius))
                }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PairingLayoutTuning.squareGap)
            .animation(.easeInOut(duration: 0.25), value: backgroundElementsOpacity)
            .onTapGesture {
                // Dismiss keyboard when tapping camera area - scroll will revert automatically
                if isCodeFieldFocused {
                    isCodeFieldFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }

            // Manual Code Entry Section
            Text(manualEntryText)
                .font(bodyFont)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, pairingLayout.codeEntryGap)

            // Code Entry Field
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { index in
                        CodeDigitBox(
                            digit: getDigit(at: index),
                            isFocused: isCodeFieldFocused && enteredCode.count == index && !showErrorGlow,
                            isError: showErrorGlow,
                            isAnimatingOut: isAnimatingOut
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
                // Simultaneous, so each box's press effect doesn't swallow the tap
                .simultaneousGesture(TapGesture().onEnded {
                    // CRITICAL: Must call becomeFirstResponder explicitly!
                    isCodeFieldFocused = true
                    UIKitTextField.focus()
                })

                // Status message (inside the VStack so it scrolls with code boxes)
                statusMessageView
            }
            .padding(.top, PairingLayoutTuning.codeGap)
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
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    #endif

    // MARK: - Helper Methods

    /// The actual code to display - uses roomCodeManager in debug mode when available
    private var displayCode: String {
        if !sharedCodeManager.generatedRoomCode.isEmpty {
            return sharedCodeManager.generatedRoomCode
        }
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

        // Ask the server to pair us with whoever created this code. `matched` or `join_failed`
        // comes back through pairingManager (see the onChange handlers on this screen)
        pairingManager.joinRoom(code: enteredCode, direction: "en_to_ko")
    }

    /// Both phones now share a room id: dismiss the keyboard and move on
    private func joinSucceeded(roomId: String) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isCodeFieldFocused = false
        isConnecting = false
        showError = false
        showErrorGlow = false
        onSuccess?(roomId)
    }

    private func joinFailed(_ failure: PairingWebSocketManager.JoinFailure) {
        #if DEBUG
        // Single-device debug flow without a backend (Create here, then switch to the partner's
        // Join screen): a code generated on this phone is accepted locally. A server that
        // answered "unknown code" is never overridden.
        if failure == .connection && sharedCodeManager.validateCode(enteredCode) {
            joinSucceeded(roomId: enteredCode)
            return
        }
        #if targetEnvironment(simulator)
        // Simulator UI work with no backend: keep the old rule, codes starting with "9" fail
        if failure == .connection && sharedCodeManager.generatedRoomCode.isEmpty && !enteredCode.hasPrefix("9") {
            joinSucceeded(roomId: enteredCode)
            return
        }
        #endif
        #endif

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
        // Dotted QR with the Dari logo; encodes a pairing link (the Join scanner keeps the digits)
        StyledQRCode.image(for: StyledQRCode.pairingPayload(code: string, language: "en"))
    }
}

// MARK: - Copy Button with Animation

/// A bare icon, so it dims while pressed like iOS's own icon buttons (the default button style)
struct CopyButton: View {
    let showCopiedFeedback: Bool
    let action: () -> Void

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
                    .scaleEffect(showCopiedFeedback ? 0.01 : 1.0)
                    .opacity(showCopiedFeedback ? 0 : 1)
            }
            .frame(width: 24, height: 24)  // Decreased from 28x28
            .animation(.easeInOut(duration: 0.15), value: showCopiedFeedback)
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
    var hasContent: Bool { !digit.isEmpty }

    @State private var cursorOpacity: Double = 1.0
    @State private var digitOffset: CGFloat = 20
    @State private var digitOpacity: Double = 0
    @State private var isPressed = false

    /// The home language cards' selected stroke (2pt, AppColors.selectedStrokeGradient), faded in
    /// rather than drawn, with no glow
    private var showsStroke: Bool { (hasContent || isFocused) && !isError }

    var body: some View {
        ZStack {
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

            // A 12% white layer while pressed
            RoundedRectangle(cornerRadius: AppStyle.smallCornerRadius)
                .fill(Color.white.opacity(0.12))
                .opacity(isPressed ? 1 : 0)

            // Selected stroke - on filled boxes and the focused box, not in the error state; fades in over 300ms
            RoundedRectangle(cornerRadius: AppStyle.smallCornerRadius)
                .stroke(
                    LinearGradient(gradient: AppColors.selectedStrokeGradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 2
                )
                .opacity(showsStroke ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: showsStroke)
        }
        .frame(width: 52, height: 65)
        // Liquid Glass, like iOS's own text entry fields (Messages' compose field); not interactive,
        // so the press is ours (white layer and a springy grow) with no system glow
        .glassEffect(.regular, in: .rect(cornerRadius: AppStyle.smallCornerRadius))
        // Error glow (conditional)
        .shadow(color: isError ? AppColors.errorRed.opacity(0.55) : Color.clear, radius: 6, x: 0, y: 0)
        .shadow(color: isError ? AppColors.errorRed.opacity(0.35) : Color.clear, radius: 12, x: 0, y: 0)
        // Pressed: grows 14% on iOS's press spring, and bounces back on its release spring
        .scaleEffect(isPressed ? 1.14 : 1)
        .animation(IOSPress.animation(pressed: isPressed), value: isPressed)
        .pressEvents(onPress: { if !isPressed { isPressed = true } }, onRelease: { isPressed = false })
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
    @State private var showCheck = false

    var body: some View {
        ZStack {
            // Content (background and gradient provided by parent WelcomeScreenLangSelect)
            VStack(alignment: .leading, spacing: 0) {
                // Success checkmark with animation
                SuccessCheckBadge(isShown: showCheck)

                // Title - 20px below checkmark
                Text("You're all set!")
                    .font(AppTypography.h2)
                    .lineSpacing(39 - 28)
                    .tracking(0.672)
                    .foregroundColor(AppColors.primaryText)
                    .padding(.top, 20)

                // Subtitle - 12px below title
                Text("Starting your translation session now.")
                    .font(AppTypography.b2)
                    .foregroundColor(AppColors.primaryText)
                    .lineSpacing(22 - 17)
                    .tracking(0.37)
                    .padding(.top, 12)

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
                .padding(.top, LiveLayoutTuning.shared.languagesTop)  // level with the live screen's language row
                Spacer()
            }
            .hiddenWhileRecording()
            #endif
        }
        .onAppear {
            // Start animations 0.5 seconds after content loads
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                startSuccessAnimation()
            }

            // Auto-proceed 200ms after the check badge settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + SuccessCheckBadge.playDuration + 0.2) {
                guard !hasProceeded else { return }
                #if DEBUG
                if RecordingDemo.holdsOnSuccess { return }  // pairing demo: the take ends here
                #endif
                hasProceeded = true
                onProceed?()
            }
        }
    }

    private func startSuccessAnimation() {
        showCheck = true
    }
}

// MARK: - Success Check Badge
// Shared by SetupSuccessScreen and SetupSuccessScreenKorean.
// Appear (Transitions.dev "Success check", minus the Y-bob): the badge fades in,
// unrotates from 80°, and unblurs from 10pt while the check stroke draws.
// The sage halo behind it pulses 1.0 → 1.25 → 1.0 on the card-stack spring
// curves, so it overshoots on the way out and again on the way back.

struct SuccessCheckBadge: View {
    var isShown: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var haloScale: CGFloat = 1.0
    @State private var checkProgress: CGFloat = 0.0

    // Appear: 500ms, cubic-bezier(0.22, 1, 0.36, 1)
    private static let appearEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
    // Check draw: 500ms after an 80ms delay, same ease-out
    private static let drawEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5).delay(0.08)
    // Halo out: 410ms, cubic-bezier(0.31, 2.34, 0.64, 1) — springy overshoot
    private static let haloOpen = Animation.timingCurve(0.31, 2.34, 0.64, 1, duration: 0.41)
    // Halo back: 360ms, cubic-bezier(0.34, 1.9, 0.64, 1) — softer spring
    private static let haloClose = Animation.timingCurve(0.34, 1.9, 0.64, 1, duration: 0.36)

    /// From `isShown` until the whole badge has finished: the halo settling back (0.1 + 0.41 + 0.36s)
    /// ends after the check draw (0.08 + 0.5s) and the appear (0.5s)
    static let playDuration: Double = 0.1 + 0.41 + 0.36

    var body: some View {
        ZStack {
            // Outer pulsing halo - sage green
            Circle()
                .fill(AppColors.lightGreen.opacity(0.6))
                .frame(width: 52, height: 52)
                .scaleEffect(haloScale)

            // Inner circle - success green
            Circle()
                .fill(AppColors.successGreen)
                .frame(width: 40, height: 40)

            // Drawn checkmark - white
            CheckmarkShape()
                .trim(from: 0, to: checkProgress)
                .stroke(AppColors.whiteIcon, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 20)
        }
        .frame(width: 52, height: 52)
        .opacity(appeared ? 1 : 0)
        .rotationEffect(.degrees(appeared ? 0 : 80))
        .blur(radius: appeared ? 0 : 10)
        .onAppear { if isShown { play() } }
        .onChange(of: isShown) { _, shown in if shown { play() } }
    }

    private func play() {
        guard !appeared else { return }

        if reduceMotion {
            appeared = true
            checkProgress = 1
            return
        }

        withAnimation(Self.appearEase) { appeared = true }
        withAnimation(Self.drawEase) { checkProgress = 1 }

        // Halo bounce: out at 0.1s, back once the open spring settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(Self.haloOpen) { haloScale = 1.25 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + 0.41) {
            withAnimation(Self.haloClose) { haloScale = 1.0 }
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
    @State private var lastLoudAt: Date = .distantPast   // last time the mic heard real voice energy

    // MARK: - Language Selector State
    // true = I speak English (They speak Korean), false = I speak Korean (They speak English)
    @State private var iSpeakEnglish: Bool = true
    @State private var languageOpacity: Double = 1.0  // For fade animation

    // MARK: - Session State
    @State private var isSessionActive: Bool = false  // true only while mic capture is actually running
    @State private var hasStartedOnce: Bool = false  // Track if session was ever started (for hiding instruction text)
    @State private var isPaused: Bool = false  // Paused after starting: Play shows, More and Stop stay out

    // MARK: - Mic Menu State
    // The voice & honorifics cards the mic button lifts to show. Local for now: not sent to the server yet.
    @State private var isMicMenuOpen: Bool = false
    @State private var voiceChoice: VoiceChoice = .female
    @State private var honorificsOn: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConnected: Bool = false  // true once session_started received; false = needs re-join
    @State private var isPartnerConnected: Bool = false
    @State private var isJoining: Bool = false  // Room join in flight (waiting for session_started)
    @State private var pendingCaptureStart: Bool = false  // Start capture as soon as the join completes
    @State private var isServerUnreachable: Bool = false  // Last join couldn't reach the backend (shown as Offline)
    @State private var reconnectTask: Task<Void, Never>?  // Re-joins on a timer while the backend is unreachable

    // MARK: - Conversation State
    // Both sides of the conversation (my lines and the partner's), joined by the server's
    // segment id. The chat redesign will render all of it; for now the latest line is shown.
    @State private var conversation = ConversationLog()
    /// The scripted demo chat is playing (debug): the mic control shows its live, expanded state
    @State private var isDemoPlaying = false
    #if DEBUG
    /// Who's talking in the reel's screen recording (LiveRecordingDemo), in place of the mic and captions
    @State private var demoVoice: VoiceActivity?
    #endif

    // MARK: - Debug Mode State
    @State private var showDebugMenu: Bool = false
    #if DEBUG
    @State private var selectedBubbleStyle: BubbleStyle = .launchDefault  // -orbStyle
    #else
    @State private var selectedBubbleStyle: BubbleStyle = .combination
    #endif
    @State private var simulatedAudioLevel: CGFloat = 0.0
    @State private var isSimulatingSpeaking: Bool = false
    @State private var useSiriGlass: Bool = false          // New Siri-style glass look (debug toggle)
    @State private var debugOrbState: OrbState? = nil     // nil = Auto (follow real mic/playback state)

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

    /// The voice the partner hears me in; starts on Female
    private enum VoiceChoice { case female, male }

    private var voiceTitle: String {
        switch voiceChoice {
        case .female: return isKorean ? "목소리: 여성" : "Voice: Female"
        case .male: return isKorean ? "목소리: 남성" : "Voice: Male"
        }
    }

    private var honorificsTitle: String {
        if isKorean { return honorificsOn ? "존댓말: 켜짐" : "존댓말: 꺼짐" }
        return honorificsOn ? "Honorifics: ON" : "Honorifics: OFF"
    }

    // Where the language row and the mic rest (LiveLayoutTuning, tunable from the debug panel).
    // The cards sit 8pt under the mic's resting spot with the pill 16pt above them, so opening the
    // menu raises the mic button 88 + 16 - 8 = 96pt wherever it rests.
    private var liveLayout: LiveLayoutTuning { .shared }
    private static let micMenuLift: CGFloat = 96

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

    /// What the orb should be doing right now.
    /// A debug override wins; otherwise derived from playback + mic state.
    private var effectiveOrbState: OrbState {
        #if DEBUG
        if let override = debugOrbState { return override }
        #endif
        if audioPlayback.isOutputActive { return .responding }   // translated speech is playing
        if effectiveIsSpeaking && (isSessionActive || showDebugMenu) { return .listening }
        return .idle                                              // waiting / other person talking
    }

    /// Who's talking, for the voice glow, the partner's edge light and the orb's pulse
    private var voiceActivity: VoiceActivity {
        #if DEBUG
        if let demoVoice { return demoVoice }  // the reel's screen recording
        #endif
        return VoiceActivity.resolve(
            micLevel: effectiveAudioLevel,
            iAmSpeaking: effectiveIsSpeaking,
            micRunning: isSessionActive || showDebugMenu,
            myCaptionLive: conversation.liveCaptions[.me] != nil,
            partnerCaptionLive: conversation.liveCaptions[.partner] != nil,
            partnerAudioPlaying: audioPlayback.isOutputActive
        )
    }

    /// Intensity the orb animates with (0...1). Debug slider when overriding, else live mic level.
    private var effectiveOrbLevel: CGFloat {
        #if DEBUG
        if debugOrbState != nil { return simulatedAudioLevel }
        #endif
        return effectiveAudioLevel
    }


    var body: some View {
        ZStack {
            // Background - solid beige color
            AppColors.background
                .ignoresSafeArea()

            // Who's talking: my voice lights the bottom, the partner's lights the bottom edges (VoiceGlow)
            LiveVoiceGlow(activity: voiceActivity)

            // Bubble - centered in screen
            VStack(spacing: 24) {
                // Animated bubble with extra space for glow effects
                // Classic styles animate unbound; the Siri-glass variant follows orbState / audioLevel
                OrganicBubble(
                    style: selectedBubbleStyle,
                    useSiriGlass: useSiriGlass,
                    orbState: effectiveOrbState,
                    audioLevel: effectiveOrbLevel
                )
                .frame(width: 400, height: 400)  // Larger container to prevent glow clipping
                // Classic looks grow with my voice and rest while the partner talks (Siri glass reacts on its own)
                .voicePulse(useSiriGlass ? 0 : voiceActivity.myLevel, speechLike: voiceActivity.mySpeechLike)
            }

            // Language Selector - 32px below dynamic island, then both sides of the conversation
            // as chat bubbles, over the orb, from under the language boxes down to the mic button
            VStack(spacing: 0) {
                languageSelectorView
                    .padding(.top, liveLayout.languagesTop)
                ConversationChatView(turns: conversation.turns, isKorean: isKorean)
                    #if DEBUG
                    .replacedByLiveDemoChat()  // the reel's recording: a scripted thread
                    #endif
            }
            // Newest bubble micGap above the mic button (micBottom up from the screen's bottom edge,
            // 80pt tall; ChatLayoutTuning); the chat's own bottom padding holds its shadow
            .padding(.bottom, liveLayout.micBottom + 80 + ChatLayoutTuning.shared.micGap - ConversationChatView.bottomShadowRoom)
            .ignoresSafeArea(edges: .bottom)

            // Instruction text - centered both vertically and horizontally
            // Only shows before first mic tap, never shows again after pause, and gives way to the
            // chat if the partner speaks first
            if !hasStartedOnce && conversation.lines.isEmpty && conversation.liveCaptions.isEmpty {
                Text(isKorean ? "마이크를 눌러 시작하세요!" : "Tap the mic to start.")
                    .font(isKorean ? AppTypography.h2Korean : AppTypography.h2)
                    .foregroundColor(AppColors.primaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    // Stays in front while it fades: a ZStack draws a leaving view at the bottom,
                    // behind the opaque background, so it vanished at once instead of fading
                    .zIndex(1)
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
            #if DEBUG
            .hiddenWhileRecording()  // the reel's recording has no connection
            #endif

            // Voice & honorifics cards - micMenuBottom above the screen's bottom edge, uncovered by the lifted mic button
            VStack {
                Spacer()
                if isMicMenuOpen {
                    MicMenuCards(
                        isMaleVoice: voiceChoice == .male,
                        isHonorificsOn: honorificsOn,
                        voiceTitle: voiceTitle,
                        honorificsTitle: honorificsTitle,
                        isKorean: isKorean,
                        onVoiceTapped: { voiceChoice = voiceChoice == .male ? .female : .male },
                        onHonorificsTapped: { honorificsOn.toggle() }
                    )
                    .transition(.micMenuReveal)
                }
            }
            .padding(.bottom, liveLayout.micMenuBottom)
            .ignoresSafeArea(edges: .bottom)

            // Mic button - micBottom above the screen's bottom edge, lifted while the menu is open
            VStack {
                Spacer()
                MicButton(
                    // Expanded, as in a live conversation, while the demo chat plays
                    isSessionActive: isDemoPlaying ? .constant(true) : $isSessionActive,
                    isPaused: isPaused,
                    isMenuOpen: isMicMenuOpen,
                    lift: isMicMenuOpen ? Self.micMenuLift : 0,
                    onMicTapped: {
                        if isSessionActive {
                            // Pause: stop the mic but stay in the room; Pause swaps to Play
                            withAnimation {
                                isSessionActive = false
                            }
                            isPaused = true
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
                        withAnimation(reduceMotion ? nil : MicMenuCards.revealAnimation) {
                            isMicMenuOpen.toggle()
                        }
                    },
                    onStopTapped: {
                        withAnimation {
                            isSessionActive = false
                        }
                        isPaused = false
                        stopAudioCapture()
                        endSession()
                    }
                )
            }
            .padding(.bottom, liveLayout.micBottom)
            .ignoresSafeArea(edges: .bottom)
            .onChange(of: isSessionActive || isPaused) { _, buttonsOut in
                // More (and its X) went back into the mic, so put the menu away with it
                if !buttonsOut && isMicMenuOpen {
                    withAnimation(reduceMotion ? nil : MicMenuCards.revealAnimation) {
                        isMicMenuOpen = false
                    }
                }
            }

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
            .hiddenWhileRecording()

            // Chat bubble radius, padding, gaps and spring (speech-bubble button, bottom left)
            ChatLayoutPanel()
            #endif
        }
        .onAppear {
            #if DEBUG
            if isOrbPreview {
                // Screenshot / preview harness: no server round-trip, so frames are deterministic
                applyOrbLaunchArguments()
                return
            }
            #endif
            // Labels, captions and notices follow the language this screen was opened with
            iSpeakEnglish = effectiveLanguage == "en"
            setupWebSocket()
            connectToRoom()
        }
        .onDisappear {
            reconnectTask?.cancel()
            disconnect()
        }
        #if DEBUG
        // The reel's screen recording (-liveDemo -demoAutopilot): plays the take through this state
        .liveRecordingDemo(isSessionActive: $isSessionActive, hasStartedOnce: $hasStartedOnce,
                           isMicMenuOpen: $isMicMenuOpen, honorificsOn: $honorificsOn, voice: $demoVoice)
        #endif
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
            // Stays Offline through background retries, so the pill doesn't flicker every few seconds
            if isServerUnreachable {
                return isKorean ? "오프라인" : "Offline"
            }
            return "Connecting..."
        } else if !isPartnerConnected {
            return isKorean ? "파트너 대기 중" : "Waiting for partner"
        } else {
            return isKorean ? "연결됨" : "Connected"
        }
    }

    // MARK: - WebSocket Setup
    private func setupWebSocket() {
        // Set up callbacks for session events
        webSocket.onSessionStarted = { roomId in
            DispatchQueue.main.async {
                isConnected = true
                isJoining = false
                isServerUnreachable = false
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
                withAnimation { conversation.endLiveCaptions(of: .partner) }  // their last words won't be finished
                print("[LiveTranslation] Partner left")
            }
        }

        // Conversation text: both sides go into the log, which the display follows
        webSocket.onMyTranscript = { event in
            DispatchQueue.main.async {
                withAnimation { conversation.apply(event, side: .me) }
                if event.isFinal { print("[LiveTranslation] I said: \(event.text)") }
            }
        }

        webSocket.onPartnerTranscript = { event in
            DispatchQueue.main.async {
                withAnimation { conversation.apply(event, side: .partner) }
                if event.isFinal { print("[LiveTranslation] Partner said: \(event.text)") }
            }
        }

        webSocket.onMyTranslation = { event in
            DispatchQueue.main.async {
                withAnimation { conversation.apply(event, side: .me) }
                print("[LiveTranslation] My words translated: \(event.original) -> \(event.translated)")
            }
        }

        webSocket.onPartnerTranslation = { event in
            DispatchQueue.main.async {
                withAnimation { conversation.apply(event, side: .partner) }
                print("[LiveTranslation] Partner's words translated: \(event.original) -> \(event.translated)")
            }
        }

        webSocket.onTranslationFailed = { event, side in
            DispatchQueue.main.async {
                withAnimation { conversation.apply(event, side: side) }
                print("[LiveTranslation] Segment not translated (\(side)): \(event.message)")
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
                withAnimation { conversation.endLiveCaptions() }  // no finals will come for live words
                withAnimation {
                    isSessionActive = false
                }
                stopAudioCapture()

                // Backend down or unreachable: say so, and keep re-joining so the screen
                // recovers by itself once it's back (a mic tap also retries right away)
                isServerUnreachable = true
                print("[LiveTranslation] Can't reach \(ServerConfig.translateURL) - is the backend running? Retrying in \(Int(Self.reconnectDelay))s")
                scheduleReconnect()
            }
        }
    }

    private static let reconnectDelay: TimeInterval = 3

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.reconnectDelay))
            guard !Task.isCancelled, !isConnected, !isJoining else { return }
            connectToRoom()
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
                    self.updateSpeakingGate(level: CGFloat(level))
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
            isPaused = false
        }
    }

    private func stopAudioCapture() {
        audioCapture.stopCapturing()
        DispatchQueue.main.async {
            self.audioLevel = 0
            self.isSpeaking = false
        }
    }

    // MARK: - Speaking Gate
    // The capture meter is dB-normalized ((dB + 60) / 60), so 0.1 is only -54 dBFS: room noise or the
    // partner across the table. Enter "speaking" on real voice energy and leave only after a short
    // silence, so the orb's listening state neither flickers between syllables nor tracks the partner.
    private static let speakingEnterLevel: CGFloat = 0.35   // about -39 dBFS
    private static let speakingExitLevel: CGFloat = 0.22    // about -47 dBFS
    private static let speakingHoldOff: TimeInterval = 0.5

    private func updateSpeakingGate(level: CGFloat) {
        let now = Date()
        if level >= Self.speakingEnterLevel {
            lastLoudAt = now
            if !isSpeaking { isSpeaking = true }
        } else if isSpeaking,
                  level < Self.speakingExitLevel,
                  now.timeIntervalSince(lastLoudAt) > Self.speakingHoldOff {
            isSpeaking = false
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

            // Expandable menu (scrolls once it outgrows the safe area, so the ladybug stays put)
            if showDebugMenu {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Start over on the welcome screen
                        restartDebugSection

                        Divider()
                            .background(Color.white.opacity(0.2))

                        // Chat text reveal style, and a scripted conversation to watch it
                        // (kept near the top so "Play demo chat" shows without scrolling)
                        ChatDebugSection(conversation: $conversation, isDemoPlaying: $isDemoPlaying,
                                         iSpeakKorean: isKorean)

                        Divider()
                            .background(Color.white.opacity(0.2))

                        // Where the language row and the mic (with the menu cards) sit
                        LiveLayoutDebugSection()

                        Divider()
                            .background(Color.white.opacity(0.2))

                        // Voice glow and the partner's edge light: preview and strength
                        VoiceGlowDebugSection()

                        Divider()
                            .background(Color.white.opacity(0.2))

                        // Orb look: classic vs new Siri glass
                        orbLookDebugSection

                        Divider()
                            .background(Color.white.opacity(0.2))

                        // Orb state: idle / listening / responding
                        orbStateDebugSection

                        Divider()
                            .background(Color.white.opacity(0.2))

                        // Language toggle section
                        languageDebugSection

                        Divider()
                            .background(Color.white.opacity(0.2))

                        // Bubble style section (classic looks only)
                        bubbleStyleDebugSection

                        Divider()
                            .background(Color.white.opacity(0.2))

                        // Audio simulation section
                        audioSimulationDebugSection
                    }
                    .padding(12)
                }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: true, vertical: false)
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

    private var restartDebugSection: some View {
        Button(action: {
            NotificationCenter.default.post(name: .debugRestartToHome, object: nil)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                Text("Restart on home screen")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.12))
            )
        }
    }

    private var orbLookDebugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ORB LOOK")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            Toggle(isOn: $useSiriGlass.animation(.easeInOut(duration: 0.35))) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundColor(useSiriGlass ? AppColors.gradientPeach : .white.opacity(0.7))
                    Text(useSiriGlass ? "Siri Glass (new)" : "Classic")
                        .font(.system(size: 12))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: AppColors.gradientPeach))
            .foregroundColor(.white)
        }
    }

    private var orbStateDebugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ORB STATE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 6) {
                orbStateChip(nil, label: "Auto")
                orbStateChip(.idle, label: "Idle")
            }
            HStack(spacing: 6) {
                orbStateChip(.listening, label: "Listening")
                orbStateChip(.responding, label: "Responding")
            }

            Text("Now: \(effectiveOrbState.displayName)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            Text("Idle = other person talking")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func orbStateChip(_ state: OrbState?, label: String) -> some View {
        let isSelected = debugOrbState == state
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.25)) {
                debugOrbState = state
            }
        }) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSelected ? AppColors.gradientPeach : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.white.opacity(0.2) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    /// True only on the `-orbPreview` launch route (see KorEngTranslatorApp), never in the normal flow
    private var isOrbPreview: Bool {
        roomId == "ORB-PREVIEW" && (ProcessInfo.processInfo.arguments.contains("-orbPreview") || LiveRecordingDemo.isOn)
    }

    /// Launch arguments for screenshot / preview runs (Debug builds only), e.g.
    /// `-orbPreview -siriGlass 1 -orbState listening -orbLevel 0.6 -bubbleStyle 3`
    private func applyOrbLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("-orbPreview") {
            hasStartedOnce = true   // hide the "Tap the mic" overlay so the orb is unobstructed
        }
        if let raw = value(after: "-siriGlass") {
            useSiriGlass = (raw as NSString).boolValue
        }
        if let raw = value(after: "-orbState") {
            debugOrbState = OrbState(rawValue: raw.lowercased())
        }
        if let raw = value(after: "-orbLevel"), let level = Double(raw) {
            simulatedAudioLevel = CGFloat(min(max(level, 0), 1))
        }
        if let raw = value(after: "-bubbleStyle"), let n = Int(raw), let style = BubbleStyle(rawValue: n) {
            selectedBubbleStyle = style
        }
        if args.contains("-chatDemo") {
            // Scripted two-person conversation, to screenshot the chat without a partner phone
            isDemoPlaying = true
            _ = ConversationDemo.play(into: $conversation, iSpeakKorean: isKorean) {
                isDemoPlaying = false
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
        Text(language)
            .font(isKorean ? AppTypography.b2Korean : AppTypography.b2)
            .foregroundColor(AppColors.primaryText)
            // P2: languageOpacity used by switchLanguages() for fade animation
            .opacity(languageOpacity)
            .frame(width: 160, height: 44)
            // A subtler take on the mic menu cards' Liquid Glass: clear glass over the box's own
            // fill, so the box keeps its color and shadow and gains the glass edge
            .glassEffect(.clear, in: .rect(cornerRadius: AppStyle.smallCornerRadius))
            .background(
                RoundedRectangle(cornerRadius: AppStyle.smallCornerRadius)
                    .fill(AppColors.languageDisplayBox)
                    .codeBoxShadow()
            )
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
    #if targetEnvironment(simulator)
    @State private var debugMode = true   // Simulator: no real pairing, use the debug controls
    #else
    @State private var debugMode = RecordingDemo.isPairingDemo  // Device: pair for real (the toggle below still switches), except in the recording demo
    #endif
    @State private var debugHeadphonesConnected = RecordingDemo.startsWithHeadphones  // pairing demo
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
            // Content (background and gradient provided by parent), placed by
            // PartnerSearchLayoutTuning: the title at home's title top, the loading dots 12pt under it,
            // the subtitle 20pt under the dots, the card at home's Card Y and card height
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    // Title
                    Text("파트너를 찾는 중.")
                        .font(AppTypography.h2Korean)
                        .lineSpacing(38 - 28)
                        .tracking(0.672)
                        .foregroundColor(AppColors.primaryText)

                    // Loading dots
                    BouncingDots()
                        .padding(.top, PartnerSearchLayoutTuning.shared.titleDotsGap)

                    // Subtitle
                    Text("같은 WiFi에 연결해 주세요.\n헤드폰도 준비해 주세요.")
                        .font(AppTypography.b2Korean)
                        .foregroundColor(AppColors.primaryText)
                        .lineSpacing(PartnerSearchLayoutTuning.shared.bodyLineSpacing)
                        .tracking(0.37)
                        .padding(.top, PartnerSearchLayoutTuning.shared.dotsBodyGap)
                }
                .padding(.top, PartnerSearchLayoutTuning.shared.titleTop)

                // Headphone status card
                PairingHeadphoneStatusCardKorean(
                    isConnected: effectiveHeadphoneStatus,
                    onTap: {
                        openBluetoothSettings()
                    }
                )
                .padding(.top, PartnerSearchLayoutTuning.shared.cardTop)

                // Manual pairing button - at the bottom
                VStack(spacing: 0) {
                    Spacer()
                    Button(action: {
                        let roomCode = String(format: "%06d", Int.random(in: 0...999999))
                        onManualPairing?(roomCode)
                    }) {
                        Text("파트너를 찾을 수 없나요?")
                            .font(AppTypography.b2Korean)
                            .foregroundColor(AppColors.secondaryText)
                            // Rolls in letter by letter, left to right, once the search has run 20s
                            .staggeredReveal(delay: 20)
                    }
                    .padding(.bottom, 44)
                }
                // Centered, 44pt above the screen's bottom edge
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .bottom)
            }
            .padding(.horizontal, 20)
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
                .padding(.top, LiveLayoutTuning.shared.languagesTop)  // level with the live screen's language row
                Spacer()
            }

            // DEBUG: Explicit controls panel at bottom (folds into a ladybug), and the layout panel
            #if DEBUG
            CollapsibleDebugControls {
                debugControlsPanelKorean
            }
            PartnerSearchLayoutPanel()
            #endif
        }
        .onAppear {
            #if DEBUG
            if !debugMode {
                pairingManager.connect(direction: direction, headphonesConnected: effectiveHeadphoneStatus)
                startHeadphoneAlertTimer()
            }
            #else
            pairingManager.connect(direction: direction, headphonesConnected: effectiveHeadphoneStatus)
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
        #if DEBUG
        .pairingDemoSearch(headphones: $debugHeadphonesConnected) { onSuccess?($0) }
        #endif
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
        #if DEBUG
        if RecordingDemo.openFakeBluetoothSettings() { return }  // English pairing demo
        #endif
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

            // Pairing mode (remembered): Starter / Joiner jumps to the Create/Join choice
            PairingModeDebugPicker(onDarkBackground: true) { mode in
                if mode == .starterJoiner {
                    onManualPairing?("")
                }
            }

            TypographyDebugPicker(onDarkBackground: true)

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
    /// Tops and gaps for both modes (tunable from the Debug layout panel)
    private var pairingLayout: PairingLayoutTuning { .shared }
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
    @StateObject private var pairingManager = PairingWebSocketManager()

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
            // Each mode's title top (PairingLayoutTuning)
            let topPadding = effectiveMode == .create ? pairingLayout.createTop : pairingLayout.joinTop

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
                                    .padding(.top, PairingLayoutTuning.titleBodyGap - HomeLayoutTuning.bodyLiftAfterHome)

                                // Mode-specific content
                                if effectiveMode == .create {
                                    createModeContentKorean(pageWidth: geometry.size.width)
                                } else {
                                    joinModeContentKorean(pageWidth: geometry.size.width)
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
                .padding(.top, LiveLayoutTuning.shared.languagesTop)  // level with the live screen's language row
                Spacer()
            }
            #if DEBUG
            .opacity(mainContentOpacity)
            .animation(.easeInOut(duration: 0.3), value: showPartnerJoinView)
            #endif

            // DEBUG: layout panel (ruler, bottom left) - the whole unit's top, then each gap
            #if DEBUG
            if !showPartnerJoinView {
                PairingLayoutDebugPanel(isCreate: effectiveMode == .create)
            }
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
                // Create mode: make a code and register it with the server so the partner can join it
                if effectiveMode == .create {
                    if sharedCodeManager.generatedRoomCode.isEmpty {
                        sharedCodeManager.generateNewCode(language: "ko")
                    }
                    pairingManager.createRoom(code: displayCode, direction: "ko_to_en")
                }
            }
            .onDisappear {
                pairingManager.cancelOffer()
            }
            .onChange(of: displayCode) { _, newCode in
                // The debug "Create" button makes a fresh code; offer that one instead
                if effectiveMode == .create {
                    pairingManager.createRoom(code: newCode, direction: "ko_to_en")
                }
            }
            .onChange(of: pairingManager.createFailure) { _, failure in
                // Someone else is offering the same code right now: show a different one
                if failure == .codeInUse, effectiveMode == .create {
                    sharedCodeManager.generateNewCode(language: "ko")
                }
            }
            .onChange(of: pairingManager.shouldNavigateToSuccess) { _, matched in
                // The partner joined our code, or the server accepted the code we entered
                if matched, let roomId = pairingManager.roomId {
                    joinSucceeded(roomId: roomId)
                }
            }
            .onChange(of: pairingManager.joinFailure) { _, failure in
                if let failure, isConnecting {
                    joinFailed(failure)
                }
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
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    #endif

    // MARK: - Create Mode Content (Korean)
    private func createModeContentKorean(pageWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("QR 코드를 보여주세요:")
                .font(AppTypography.h3Korean)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, PairingLayoutTuning.labelGap + HomeLayoutTuning.bodyLiftAfterHome)  // stays put as the subtitle lifts

            // QR Code - 20% smaller than full width, left-aligned like the code box below (cached to prevent flickering)
            if let qrImage = cachedQRImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(1, contentMode: .fit)
                    .containerRelativeFrame(.horizontal) { width, _ in (width - 72) * 0.8 }  // 20pt page + 16pt card padding a side
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
                            .fill(AppColors.cardFill.opacity(0.95))
                    )
                    .codeBoxShadow()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, PairingLayoutTuning.squareGap)
            }

            Text("또는 이 코드를 공유하세요:")
                .font(AppTypography.b2Korean)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, pairingLayout.shareGap)

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
            // As wide as the QR box above: its QR ((width - 72) * 0.8) plus 16pt padding a side
            .containerRelativeFrame(.horizontal) { width, _ in (width - 72) * 0.8 + 32 }
            .background(AppColors.cardFill.opacity(0.95))
            .cornerRadius(AppStyle.smallCornerRadius)
            .codeBoxShadow()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PairingLayoutTuning.codeGap)
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
    private func joinModeContentKorean(pageWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Camera Section
            Text(scanQRText)
                .font(h3Font)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, PairingLayoutTuning.labelGap + HomeLayoutTuning.bodyLiftAfterHome)  // stays put as the subtitle lifts

            // Camera container (semi-transparent to show surroundings, full opacity when code entry focused)
            ZStack {
                // The home screen cards' glass surface, a little see-through until the code entry is focused
                GlassCardBackground()
                    .opacity(backgroundElementsOpacity)
                    .frame(width: PairingLayoutTuning.cameraSide(pageWidth: pageWidth),
                           height: PairingLayoutTuning.cameraSide(pageWidth: pageWidth))

                // Camera viewfinder (square, 12pt inside the box) - always full opacity
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
                .frame(width: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth), height: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth))
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: PairingLayoutTuning.viewfinderRadius))
                #else
                // Real device: Show camera viewfinder at full opacity
                if isCameraAvailable {
                    QRScannerView(scanner: qrScanner, isReady: qrScanner.isReady)
                        .frame(width: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth), height: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth))
                        .clipShape(RoundedRectangle(cornerRadius: PairingLayoutTuning.viewfinderRadius))
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
                    .frame(width: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth), height: PairingLayoutTuning.viewfinderSide(pageWidth: pageWidth))
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: PairingLayoutTuning.viewfinderRadius))
                }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PairingLayoutTuning.squareGap)
            .animation(.easeInOut(duration: 0.25), value: backgroundElementsOpacity)
            .onTapGesture {
                // Dismiss keyboard when tapping camera area - scroll will revert automatically
                if isCodeFieldFocused {
                    isCodeFieldFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }

            // Manual Code Entry Section
            Text(manualEntryText)
                .font(bodyFont)
                .foregroundColor(AppColors.primaryText)
                .padding(.top, pairingLayout.codeEntryGap)

            // Code Entry Field
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { index in
                        CodeDigitBox(
                            digit: getDigit(at: index),
                            isFocused: isCodeFieldFocused && enteredCode.count == index && !showErrorGlow,
                            isError: showErrorGlow,
                            isAnimatingOut: isAnimatingOut
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
                // Simultaneous, so each box's press effect doesn't swallow the tap
                .simultaneousGesture(TapGesture().onEnded {
                    isCodeFieldFocused = true
                    UIKitTextField.focus()
                })

                // Status message (inside the VStack so it scrolls with code boxes)
                statusMessageViewKorean
            }
            .padding(.top, PairingLayoutTuning.codeGap)
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
        if !sharedCodeManager.generatedRoomCode.isEmpty {
            return sharedCodeManager.generatedRoomCode
        }
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

        // Ask the server to pair us with whoever created this code. `matched` or `join_failed`
        // comes back through pairingManager (see the onChange handlers on this screen)
        pairingManager.joinRoom(code: enteredCode, direction: "ko_to_en")
    }

    /// Both phones now share a room id: dismiss the keyboard and move on
    private func joinSucceeded(roomId: String) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isCodeFieldFocused = false
        isConnecting = false
        showError = false
        showErrorGlow = false
        onSuccess?(roomId)
    }

    private func joinFailed(_ failure: PairingWebSocketManager.JoinFailure) {
        #if DEBUG
        // Single-device debug flow without a backend (Create here, then switch to the partner's
        // Join screen): a code generated on this phone is accepted locally. A server that
        // answered "unknown code" is never overridden.
        if failure == .connection && sharedCodeManager.validateCode(enteredCode) {
            joinSucceeded(roomId: enteredCode)
            return
        }
        #if targetEnvironment(simulator)
        // Simulator UI work with no backend: keep the old rule, codes starting with "9" fail
        if failure == .connection && sharedCodeManager.generatedRoomCode.isEmpty && !enteredCode.hasPrefix("9") {
            joinSucceeded(roomId: enteredCode)
            return
        }
        #endif
        #endif

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
    }

    private func handleScannedCode(_ code: String) {
        qrScanner.stopScanning()
        enteredCode = code.filter { $0.isNumber }.prefix(6).description
        handleEnteredCode()
    }

    private func generateQRCode(from string: String) -> UIImage? {
        // Dotted QR with the Dari logo; encodes a pairing link (the Join scanner keeps the digits)
        StyledQRCode.image(for: StyledQRCode.pairingPayload(code: string, language: "ko"))
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
    @State private var showCheck = false

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                // Success checkmark
                SuccessCheckBadge(isShown: showCheck)

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
                    .padding(.top, 12)

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
                .padding(.top, LiveLayoutTuning.shared.languagesTop)  // level with the live screen's language row
                Spacer()
            }
            .hiddenWhileRecording()
            #endif
        }
        .onAppear {
            // Start animations 0.5 seconds after content loads
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                startSuccessAnimation()
            }

            // Auto-proceed 200ms after the check badge settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + SuccessCheckBadge.playDuration + 0.2) {
                guard !hasProceeded else { return }
                #if DEBUG
                if RecordingDemo.holdsOnSuccess { return }  // pairing demo: the take ends here
                #endif
                hasProceeded = true
                onProceed?()
            }
        }
    }

    private func startSuccessAnimation() {
        showCheck = true
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
