import Foundation

// MARK: - Translation Direction

enum TranslationDirection: String, Codable, CaseIterable {
    case koreanToEnglish = "ko_to_en"
    case englishToKorean = "en_to_ko"

    var displayName: String {
        switch self {
        case .koreanToEnglish:
            return "Korean → English"
        case .englishToKorean:
            return "English → Korean"
        }
    }

    var shortName: String {
        switch self {
        case .koreanToEnglish:
            return "KR→EN"
        case .englishToKorean:
            return "EN→KR"
        }
    }
}

// MARK: - User Language (for bidirectional sessions)

/// What language the user speaks - determines their output pipeline direction
enum UserLanguage: String, Codable {
    case english = "en"
    case korean = "ko"

    /// The direction MY voice goes through (my language → partner's language)
    var myOutputDirection: TranslationDirection {
        switch self {
        case .english:
            return .englishToKorean  // I speak English, partner hears Korean
        case .korean:
            return .koreanToEnglish  // I speak Korean, partner hears English
        }
    }

    /// The direction PARTNER's voice comes from (partner's language → my language)
    var partnerOutputDirection: TranslationDirection {
        switch self {
        case .english:
            return .koreanToEnglish  // Partner speaks Korean, I hear English
        case .korean:
            return .englishToKorean  // Partner speaks English, I hear Korean
        }
    }
}

// MARK: - Pairing Mode

enum PairingMode: String, Codable {
    case wifiAuto = "wifi_auto"
    case manual = "manual"
}

// MARK: - Session Config

struct SessionConfig: Codable {
    let honorificMode: Bool

    enum CodingKeys: String, CodingKey {
        case honorificMode = "honorific_mode"
    }

    init(honorificMode: Bool = false) {
        self.honorificMode = honorificMode
    }
}

// MARK: - Outgoing Messages (Client → Server)

/// Start session message for bidirectional translation with room support
struct StartSessionMessage: Codable {
    let type: String
    let pairingMode: String
    let roomId: String?
    let userLanguage: String
    let wifiIdentifier: String?
    let config: SessionConfig

    enum CodingKeys: String, CodingKey {
        case type
        case pairingMode = "pairing_mode"
        case roomId = "room_id"
        case userLanguage = "user_language"
        case wifiIdentifier = "wifi_identifier"
        case config
    }

    /// Initialize for WiFi auto-pairing
    init(userLanguage: UserLanguage, wifiIdentifier: String, honorificMode: Bool = false) {
        self.type = "start_session"
        self.pairingMode = PairingMode.wifiAuto.rawValue
        self.roomId = nil
        self.userLanguage = userLanguage.rawValue
        self.wifiIdentifier = wifiIdentifier
        self.config = SessionConfig(honorificMode: honorificMode)
    }

    /// Initialize for manual pairing (create room - no roomId)
    init(userLanguage: UserLanguage, honorificMode: Bool = false) {
        self.type = "start_session"
        self.pairingMode = PairingMode.manual.rawValue
        self.roomId = nil
        self.userLanguage = userLanguage.rawValue
        self.wifiIdentifier = nil
        self.config = SessionConfig(honorificMode: honorificMode)
    }

    /// Initialize for manual pairing (join existing room)
    init(roomId: String, userLanguage: UserLanguage, honorificMode: Bool = false) {
        self.type = "start_session"
        self.pairingMode = PairingMode.manual.rawValue
        self.roomId = roomId
        self.userLanguage = userLanguage.rawValue
        self.wifiIdentifier = nil
        self.config = SessionConfig(honorificMode: honorificMode)
    }

    /// Legacy initializer for backward compatibility
    init(direction: TranslationDirection) {
        self.type = "start_session"
        self.pairingMode = PairingMode.manual.rawValue
        self.roomId = nil
        // Infer user language from direction
        self.userLanguage = direction == .koreanToEnglish ? "ko" : "en"
        self.wifiIdentifier = nil
        self.config = SessionConfig(honorificMode: false)
    }
}

/// Audio chunk message sent to the backend
struct AudioChunkMessage: Codable {
    let type: String
    let direction: String
    let data: String  // Base64 encoded audio data
    let timestamp: Double

    init(direction: TranslationDirection, audioData: Data) {
        self.type = "audio_chunk"
        self.direction = direction.rawValue
        self.data = audioData.base64EncodedString()
        self.timestamp = Date().timeIntervalSince1970
    }
}

/// End of turn message (reserved for P1 walkie-talkie mode)
struct EndOfTurnMessage: Codable {
    let type: String
    let direction: String

    init(direction: TranslationDirection) {
        self.type = "end_of_turn"
        self.direction = direction.rawValue
    }
}

// MARK: - Incoming Messages (Server → Client)

/// Base message for determining message type
struct IncomingMessageBase: Codable {
    let type: String
}

/// Pairing status message for WiFi auto-pairing
struct PairingStatusMessage: Codable {
    let type: String
    let status: String  // "waiting", "timeout", "matched"
    let message: String?
    let roomId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case status
        case message
        case roomId = "room_id"
    }
}

/// Session started response
struct SessionStartedMessage: Codable {
    let type: String
    let roomId: String
    let pairedVia: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case roomId = "room_id"
        case pairedVia = "paired_via"
        case sessionId = "session_id"
    }
}

/// Partner event message (joined/left)
struct PartnerEventMessage: Codable {
    let type: String  // "partner_joined" or "partner_left"
}

/// Transcription result from STT (matches backend TranscriptInterim/TranscriptFinal)
struct TranscriptionMessage: Codable {
    let type: String
    let text: String
    let direction: String?
    let segmentId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case direction
        case segmentId = "segment_id"
    }

    var isFinal: Bool {
        type == "transcript_final"
    }
}

/// Translation result (matches backend TranslationResult)
struct TranslationMessage: Codable {
    let type: String
    let direction: String?
    let original: String?
    let translated: String
    let segmentId: String?
    let honorific: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case direction
        case original
        case translated
        case segmentId = "segment_id"
        case honorific
    }

    /// Convenience property for display
    var text: String { translated }
}

/// Audio response from TTS (for base64 encoded audio in JSON)
struct AudioResponseMessage: Codable {
    let type: String
    let data: String  // Base64 encoded audio
    let format: String?

    var audioData: Data? {
        Data(base64Encoded: data)
    }
}

/// Audio metadata header (backend sends this before binary audio)
struct AudioOutMessage: Codable {
    let type: String
    let direction: String?
    let format: String?
}

/// Error message from server
struct ErrorMessage: Codable {
    let type: String
    let message: String
    let code: String?
}

/// Status/connection message
struct StatusMessage: Codable {
    let type: String
    let status: String
    let message: String?
}

/// Gender detection result from server
struct GenderDetectedMessage: Codable {
    let type: String
    let gender: String
    let direction: String?
}

// MARK: - Parsed Incoming Message

/// Enum representing all possible incoming message types
enum ParsedMessage {
    case pairingStatus(PairingStatusMessage)
    case sessionStarted(SessionStartedMessage)
    case partnerJoined
    case partnerLeft
    case transcription(TranscriptionMessage)
    case translation(TranslationMessage)
    case audio(AudioResponseMessage)
    case audioOut(AudioOutMessage)  // Header before binary audio
    case error(ErrorMessage)
    case status(StatusMessage)
    case genderDetected(GenderDetectedMessage)
    case unknown(String)

    static func parse(from data: Data) -> ParsedMessage? {
        guard let baseMessage = try? JSONDecoder().decode(IncomingMessageBase.self, from: data) else {
            return nil
        }

        switch baseMessage.type {
        case "pairing_status":
            if let msg = try? JSONDecoder().decode(PairingStatusMessage.self, from: data) {
                return .pairingStatus(msg)
            }
        case "session_started":
            if let msg = try? JSONDecoder().decode(SessionStartedMessage.self, from: data) {
                return .sessionStarted(msg)
            }
        case "partner_joined":
            return .partnerJoined
        case "partner_left":
            return .partnerLeft
        case "transcription", "transcript", "transcript_interim", "transcript_final":
            if let msg = try? JSONDecoder().decode(TranscriptionMessage.self, from: data) {
                return .transcription(msg)
            }
        case "translation":
            if let msg = try? JSONDecoder().decode(TranslationMessage.self, from: data) {
                return .translation(msg)
            }
        case "audio", "audio_response":
            if let msg = try? JSONDecoder().decode(AudioResponseMessage.self, from: data) {
                return .audio(msg)
            }
        case "audio_out":
            if let msg = try? JSONDecoder().decode(AudioOutMessage.self, from: data) {
                return .audioOut(msg)
            }
        case "error":
            if let msg = try? JSONDecoder().decode(ErrorMessage.self, from: data) {
                return .error(msg)
            }
        case "status", "connected":
            if let msg = try? JSONDecoder().decode(StatusMessage.self, from: data) {
                return .status(msg)
            }
        case "gender_detected":
            if let msg = try? JSONDecoder().decode(GenderDetectedMessage.self, from: data) {
                return .genderDetected(msg)
            }
        default:
            break
        }

        return .unknown(baseMessage.type)
    }
}
