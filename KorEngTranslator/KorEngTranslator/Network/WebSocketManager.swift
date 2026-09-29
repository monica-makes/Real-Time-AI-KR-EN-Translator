import Foundation
import Combine

/// Backend server location - single source of truth for /ws/translate and /ws/pair
/// Override from the Xcode scheme's launch arguments: -serverHost 192.168.x.x -serverPort 8001
enum ServerConfig {
    static var host: String {
        if let override = UserDefaults.standard.string(forKey: "serverHost")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        #if targetEnvironment(simulator)
        return "localhost"
        #else
        return "monicas-MacBook-Pro.local"  // This Mac's Bonjour name (survives IP changes); override with -serverHost
        #endif
    }

    static var port: Int {
        let override = UserDefaults.standard.integer(forKey: "serverPort")
        return override > 0 ? override : 8001
    }

    /// Translation session endpoint
    static var translateURL: String {
        "ws://\(host):\(port)/ws/translate"
    }

    /// WiFi pairing endpoint (same server as translation)
    /// - Parameters:
    ///   - direction: Pairing direction (e.g. "ko_to_en")
    ///   - host: Optional host override (defaults to ServerConfig.host)
    ///   - manual: Codes only (create_room / join_room), no Wi-Fi matching or timeout
    static func pairURL(direction: String, host: String? = nil, manual: Bool = false) -> String {
        "ws://\(host ?? self.host):\(port)/ws/pair?direction=\(direction)&mode=\(manual ? "manual" : "wifi")"
    }
}

/// Connection state for the WebSocket
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var displayText: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

/// Pairing status for WiFi auto-pairing
enum PairingStatus: Equatable {
    case idle
    case attemptingWiFiPair
    case waitingForPartner
    case paired(roomId: String, method: String)
    case failed(message: String)
}

/// Protocol for receiving WebSocket events
protocol WebSocketManagerDelegate: AnyObject {
    func webSocketManager(_ manager: WebSocketManager, didReceiveMessage message: ParsedMessage)
    func webSocketManager(_ manager: WebSocketManager, didChangeState state: ConnectionState)
    func webSocketManager(_ manager: WebSocketManager, didReceiveError error: Error)
}

/// Manages WebSocket connection to the translation backend
@MainActor
class WebSocketManager: ObservableObject {
    // MARK: - Singleton (optional - can also create instances)

    static let shared = WebSocketManager()

    // MARK: - Published Properties

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var pairingStatus: PairingStatus = .idle
    @Published var lastTranscription: String = ""
    @Published var lastTranslation: String = ""
    @Published private(set) var isPartnerConnected: Bool = false
    @Published private(set) var roomId: String?

    // MARK: - Public Properties

    weak var delegate: WebSocketManagerDelegate?

    /// Callback for received audio data (translated audio to play)
    var onAudioReceived: ((Data) -> Void)?

    /// Callbacks for session events
    var onSessionStarted: ((String) -> Void)?  // roomId
    var onPartnerJoined: (() -> Void)?
    var onPartnerLeft: (() -> Void)?
    var onPairingTimeout: (() -> Void)?
    var onError: ((String) -> Void)?  // Server-reported session/connection error; the socket stays up
    var onDisconnected: ((String) -> Void)?  // Transport failure (socket dropped / unreachable)

    /// Callbacks for the conversation text. The server sends every transcript and translation
    /// to both phones in a room, tagged with the speaker's direction, so the chat can show both
    /// sides: my line with its translation, and the partner's line with its translation.
    /// Nothing is filtered here - the screen decides what to display.
    var onMyTranscript: ((TranscriptEvent) -> Void)?         // My words, in my language (interim + final)
    var onPartnerTranscript: ((TranscriptEvent) -> Void)?    // The partner's words, in their language
    var onMyTranslation: ((TranslationEvent) -> Void)?       // My words translated (what the partner hears)
    var onPartnerTranslation: ((TranslationEvent) -> Void)?  // The partner's words translated into my language
    /// A segment (mine or the partner's) the server couldn't translate; both phones get this
    var onTranslationFailed: ((TranslationFailureEvent, ConversationSide) -> Void)?

    // MARK: - Private Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var serverURL: URL?

    /// User's language - determines audio routing direction
    private(set) var userLanguage: UserLanguage = .english

    // Default backend URL (read at connect time so launch-argument overrides apply)
    private static var defaultURL: String { ServerConfig.translateURL }

    // MARK: - Computed Properties

    /// The direction MY voice goes through (my language → partner's language)
    var myOutputDirection: TranslationDirection {
        userLanguage.myOutputDirection
    }

    /// The direction PARTNER's voice comes from (partner's language → my language)
    var partnerOutputDirection: TranslationDirection {
        userLanguage.partnerOutputDirection
    }

    /// Which side of the conversation a message with this speaker direction belongs to
    func side(of direction: TranslationDirection?) -> ConversationSide {
        guard let direction else { return .me }
        return direction == myOutputDirection ? .me : .partner
    }

    // MARK: - Initialization

    init() {}

    /// Set the language without connecting (command-line harness and previews)
    func configure(userLanguage: UserLanguage) {
        self.userLanguage = userLanguage
    }

    // MARK: - Public Connection Methods

    /// Connect with WiFi auto-pairing
    /// - Parameters:
    ///   - userLanguage: The language this user speaks ("en" or "kr")
    ///   - wifiIdentifier: Hash of the WiFi BSSID/SSID
    ///   - honorificMode: Whether to use honorific translations
    ///   - urlString: WebSocket URL (defaults to ServerConfig.translateURL)
    func connectWithWiFiAutoPairing(
        userLanguage: UserLanguage,
        wifiIdentifier: String,
        honorificMode: Bool = false,
        to urlString: String? = nil
    ) {
        self.userLanguage = userLanguage
        self.pairingStatus = .attemptingWiFiPair

        let serverURLString = (urlString ?? Self.defaultURL).trimmingCharacters(in: .whitespacesAndNewlines)
        print("[WebSocketManager] WiFi auto-pairing to: \(serverURLString)")

        guard let url = URL(string: serverURLString) else {
            print("[WebSocketManager] Invalid URL")
            connectionState = .error("Invalid URL")
            pairingStatus = .failed(message: "Invalid URL")
            return
        }

        disconnect()
        establishConnection(to: url)

        // Send start session with WiFi auto mode after connection
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
            if self.webSocketTask?.state == .running {
                self.connectionState = .connected
                self.delegate?.webSocketManager(self, didChangeState: .connected)

                let message = StartSessionMessage(
                    userLanguage: userLanguage,
                    wifiIdentifier: wifiIdentifier,
                    honorificMode: honorificMode
                )
                self.sendCodable(message)
            }
        }
    }

    /// Create a new room (manual pairing - user shows QR/code)
    /// - Parameters:
    ///   - userLanguage: The language this user speaks
    ///   - honorificMode: Whether to use honorific translations
    ///   - urlString: WebSocket URL (defaults to ServerConfig.translateURL)
    func createRoom(
        userLanguage: UserLanguage,
        honorificMode: Bool = false,
        to urlString: String? = nil
    ) {
        self.userLanguage = userLanguage
        self.pairingStatus = .waitingForPartner

        let serverURLString = (urlString ?? Self.defaultURL).trimmingCharacters(in: .whitespacesAndNewlines)
        print("[WebSocketManager] Creating room at: \(serverURLString)")

        guard let url = URL(string: serverURLString) else {
            print("[WebSocketManager] Invalid URL")
            connectionState = .error("Invalid URL")
            pairingStatus = .failed(message: "Invalid URL")
            return
        }

        disconnect()
        establishConnection(to: url)

        // Send start session without roomId (server generates it)
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if self.webSocketTask?.state == .running {
                self.connectionState = .connected
                self.delegate?.webSocketManager(self, didChangeState: .connected)

                let message = StartSessionMessage(
                    userLanguage: userLanguage,
                    honorificMode: honorificMode
                )
                self.sendCodable(message)
            }
        }
    }

    /// Join an existing room (manual pairing - user enters code)
    /// - Parameters:
    ///   - roomId: The room code to join
    ///   - userLanguage: The language this user speaks
    ///   - honorificMode: Whether to use honorific translations
    ///   - urlString: WebSocket URL (defaults to ServerConfig.translateURL)
    func joinRoom(
        roomId: String,
        userLanguage: UserLanguage,
        honorificMode: Bool = false,
        to urlString: String? = nil
    ) {
        self.userLanguage = userLanguage
        self.pairingStatus = .waitingForPartner

        let serverURLString = (urlString ?? Self.defaultURL).trimmingCharacters(in: .whitespacesAndNewlines)
        print("[WebSocketManager] Joining room \(roomId) at: \(serverURLString)")

        guard let url = URL(string: serverURLString) else {
            print("[WebSocketManager] Invalid URL")
            connectionState = .error("Invalid URL")
            pairingStatus = .failed(message: "Invalid URL")
            onDisconnected?("Invalid URL")  // Let the caller reset its joining state
            return
        }

        // Socket still up (e.g. re-join after Stop): start a new session on it instead of
        // reconnecting, so the translation/audio the server is still flushing from the
        // previous session isn't lost. The server handles start_session after that flush.
        if let task = webSocketTask, task.state == .running,
           connectionState.isConnected, serverURL == url {
            let message = StartSessionMessage(
                roomId: roomId,
                userLanguage: userLanguage,
                honorificMode: honorificMode
            )
            sendCodable(message)
            return
        }

        disconnect()
        establishConnection(to: url)
        let joinTask = webSocketTask

        // Send start session with roomId
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Skip if this socket already failed or was replaced by a newer join
            if let joinTask, self.webSocketTask === joinTask, joinTask.state == .running {
                self.connectionState = .connected
                self.delegate?.webSocketManager(self, didChangeState: .connected)

                let message = StartSessionMessage(
                    roomId: roomId,
                    userLanguage: userLanguage,
                    honorificMode: honorificMode
                )
                self.sendCodable(message)
            }
        }
    }

    /// Legacy connect method for backward compatibility
    /// - Parameters:
    ///   - urlString: WebSocket URL (defaults to ServerConfig.translateURL)
    ///   - direction: Translation direction for the session
    func connect(to urlString: String? = nil, direction: TranslationDirection = .koreanToEnglish) {
        // Infer user language from direction
        let inferredLanguage: UserLanguage = direction == .koreanToEnglish ? .korean : .english
        self.userLanguage = inferredLanguage

        let serverURLString = (urlString ?? Self.defaultURL).trimmingCharacters(in: .whitespacesAndNewlines)
        print("[WebSocketManager] Connecting to: \(serverURLString)")

        guard let url = URL(string: serverURLString) else {
            print("[WebSocketManager] Invalid URL")
            connectionState = .error("Invalid URL")
            return
        }

        disconnect()
        establishConnection(to: url)

        // Send start_session message after connection
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if self.webSocketTask?.state == .running {
                self.connectionState = .connected
                self.delegate?.webSocketManager(self, didChangeState: .connected)
                print("[WebSocketManager] Connected")

                self.sendStartSession(direction: direction)
            }
        }
    }

    /// Send start_session message to initialize the translation session
    func sendStartSession(direction: TranslationDirection) {
        guard connectionState.isConnected else {
            print("[WebSocketManager] Cannot send start_session: not connected")
            return
        }

        let message = StartSessionMessage(direction: direction)

        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[WebSocketManager] Failed to encode start_session message")
            return
        }

        print("[WebSocketManager] Sending start_session: \(jsonString)")

        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                print("[WebSocketManager] Failed to send start_session: \(error)")
            } else {
                print("[WebSocketManager] start_session sent successfully")
            }
        }
    }

    /// Disconnect from the WebSocket server
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        connectionState = .disconnected
        pairingStatus = .idle
        isPartnerConnected = false
        roomId = nil
        delegate?.webSocketManager(self, didChangeState: .disconnected)

        print("[WebSocketManager] Disconnected")
    }

    /// Send an audio chunk to the server
    /// - Parameter audioData: PCM 16-bit audio data
    func sendAudioChunk(_ audioData: Data) {
        guard connectionState.isConnected else {
            print("[WebSocketManager] Cannot send: not connected")
            return
        }

        // Tag with MY output direction (my language → partner's language)
        let message = AudioChunkMessage(direction: myOutputDirection, audioData: audioData)

        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[WebSocketManager] Failed to encode message")
            return
        }

        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                print("[WebSocketManager] Send error: \(error)")
            }
        }
    }

    /// Send an audio chunk with explicit direction (legacy support)
    /// - Parameters:
    ///   - audioData: PCM 16-bit audio data
    ///   - direction: Translation direction
    func sendAudioChunk(_ audioData: Data, direction: TranslationDirection) {
        guard connectionState.isConnected else {
            print("[WebSocketManager] Cannot send: not connected")
            return
        }

        let message = AudioChunkMessage(direction: direction, audioData: audioData)

        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[WebSocketManager] Failed to encode message")
            return
        }

        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                print("[WebSocketManager] Send error: \(error)")
            }
        }
    }

    /// Send end of turn message (reserved for P1 walkie-talkie mode)
    /// - Parameter direction: Translation direction
    func sendEndOfTurn(direction: TranslationDirection) {
        guard connectionState.isConnected else { return }

        let message = EndOfTurnMessage(direction: direction)

        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                print("[WebSocketManager] Send end_of_turn error: \(error)")
            }
        }
    }

    /// Send session end message
    func sendSessionEnd() {
        guard connectionState.isConnected else { return }

        let message = ["type": "session_end"]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        webSocketTask?.send(.string(jsonString)) { _ in }
    }

    // MARK: - Private Methods

    private func establishConnection(to url: URL) {
        connectionState = .connecting

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        self.urlSession = session
        self.serverURL = url

        // Start receiving messages
        receiveMessage()
    }

    private func sendCodable<T: Codable>(_ message: T) {
        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[WebSocketManager] Failed to encode message")
            return
        }

        print("[WebSocketManager] Sending: \(jsonString)")

        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                print("[WebSocketManager] Send error: \(error)")
            }
        }
    }

    private func receiveMessage() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                // Ignore results from a socket we already closed or replaced (e.g. re-join),
                // otherwise its cancellation error would tear down the new connection's state
                guard let self, self.webSocketTask === task else { return }
                self.handleReceiveResult(result)
            }
        }
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            handleMessage(message)
            // Continue receiving
            receiveMessage()

        case .failure(let error):
            print("[WebSocketManager] Receive error: \(error)")

            // Transport failure - the only place (besides connect/disconnect) that changes connectionState
            if (error as NSError).code == 57 {  // Socket not connected
                connectionState = .disconnected
            } else {
                connectionState = .error(error.localizedDescription)
            }
            isPartnerConnected = false

            // Socket is dead - release it so pending start tasks don't treat it as running
            webSocketTask = nil
            urlSession?.invalidateAndCancel()
            urlSession = nil

            delegate?.webSocketManager(self, didReceiveError: error)
            onDisconnected?(error.localizedDescription)
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleTextMessage(text)

        case .data(let data):
            // Binary data - might be raw audio
            print("[WebSocketManager] Received binary data: \(data.count) bytes")
            onAudioReceived?(data)

        @unknown default:
            print("[WebSocketManager] Unknown message type")
        }
    }

    /// Handle one JSON text frame from the server (internal so the command-line harness can inject frames)
    func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let parsed = ParsedMessage.parse(from: data) else {
            print("[WebSocketManager] Failed to parse message: \(text.prefix(100))")
            return
        }

        switch parsed {
        case .pairingStatus(let msg):
            handlePairingStatus(msg)

        case .sessionStarted(let msg):
            handleSessionStarted(msg)

        case .partnerJoined:
            print("[WebSocketManager] Partner joined")
            isPartnerConnected = true
            onPartnerJoined?()

        case .partnerLeft:
            print("[WebSocketManager] Partner left")
            isPartnerConnected = false
            onPartnerLeft?()

        case .transcription(let msg):
            print("[WebSocketManager] Transcript (\(msg.type)): \(msg.text)")
            lastTranscription = msg.text

            // The direction is the speaker's: mine for my words, the partner's for theirs.
            // A legacy frame without one is treated as mine.
            let direction = TranslationDirection(rawValue: msg.direction ?? "") ?? myOutputDirection
            let event = TranscriptEvent(
                text: msg.text,
                isFinal: msg.isFinal,
                segmentId: msg.segmentId,
                direction: direction
            )
            if side(of: direction) == .me {
                onMyTranscript?(event)
            } else {
                onPartnerTranscript?(event)
            }

        case .translation(let msg):
            print("[WebSocketManager] Translation: \(msg.translated)")
            lastTranslation = msg.translated

            // Both my own translations and the partner's arrive here (the server sends every
            // translation to both phones). Deliver each to its own callback; nothing is dropped,
            // so solo mode needs no special case.
            let direction = TranslationDirection(rawValue: msg.direction ?? "") ?? myOutputDirection
            let event = TranslationEvent(
                original: msg.original ?? "",
                translated: msg.translated,
                segmentId: msg.segmentId,
                direction: direction,
                honorific: msg.honorific
            )
            if side(of: direction) == .me {
                onMyTranslation?(event)
            } else {
                onPartnerTranslation?(event)
            }

        case .audio(let msg):
            print("[WebSocketManager] Audio received: \(msg.data.count) chars (base64)")
            if let audioData = msg.audioData {
                onAudioReceived?(audioData)
            }

        case .audioOut(let msg):
            // This is just a header - binary audio follows in next message
            print("[WebSocketManager] Audio out header: direction=\(msg.direction ?? "unknown"), format=\(msg.format ?? "unknown")")

        case .error(let msg):
            if msg.isTranslationFailure {
                // One segment couldn't be translated (mine or the partner's); the session goes on
                print("[WebSocketManager] Segment not translated (\(msg.code ?? "-")): \(msg.message)")
                let direction = msg.direction.flatMap(TranslationDirection.init(rawValue:))
                let event = TranslationFailureEvent(
                    message: msg.message,
                    code: msg.code,
                    segmentId: msg.segmentId,
                    original: msg.original,
                    direction: direction
                )
                onTranslationFailed?(event, side(of: direction))
            } else {
                // Server-side error (e.g. "No active session") - the socket is still usable,
                // so keep connectionState; only transport failures change it
                print("[WebSocketManager] Server error: \(msg.message)")
                onError?(msg.message)
            }

        case .status(let msg):
            print("[WebSocketManager] Status: \(msg.status)")

        case .genderDetected(let msg):
            print("[WebSocketManager] Gender detected: \(msg.gender)")

        case .unknown(let type):
            print("[WebSocketManager] Unknown message type: \(type)")
        }

        delegate?.webSocketManager(self, didReceiveMessage: parsed)
    }

    private func handlePairingStatus(_ msg: PairingStatusMessage) {
        print("[WebSocketManager] Pairing status: \(msg.status)")

        switch msg.status {
        case "waiting":
            pairingStatus = .waitingForPartner

        case "timeout":
            pairingStatus = .failed(message: msg.message ?? "Pairing timeout")
            onPairingTimeout?()

        case "matched":
            if let roomId = msg.roomId {
                self.roomId = roomId
                pairingStatus = .paired(roomId: roomId, method: "wifi_auto")
            }

        default:
            print("[WebSocketManager] Unknown pairing status: \(msg.status)")
        }
    }

    private func handleSessionStarted(_ msg: SessionStartedMessage) {
        print("[WebSocketManager] Session started - Room: \(msg.roomId)")
        self.roomId = msg.roomId

        let method = msg.pairedVia ?? "manual"
        pairingStatus = .paired(roomId: msg.roomId, method: method)
        onSessionStarted?(msg.roomId)
    }
}
