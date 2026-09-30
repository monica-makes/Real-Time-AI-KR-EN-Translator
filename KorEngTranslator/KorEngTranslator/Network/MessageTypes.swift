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

/// Error message from server (matches backend ErrorMessage)
///
/// For a segment the server couldn't translate, `code` says why, `segmentId` matches that
/// segment's transcript_final and `original` repeats what was said.
struct ErrorMessage: Codable {
    let type: String
    let message: String
    let code: String?
    let direction: String?
    let segmentId: String?
    let original: String?
    let recoverable: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case message
        case code
        case direction
        case segmentId = "segment_id"
        case original
        case recoverable
    }

    /// Backend ErrorMessage.code values for a segment that couldn't be translated
    static let translationRefusedCode = "translation_refused"  // Claude declined (policy)
    static let translationFailedCode = "translation_failed"    // The translation call broke mid-stream

    /// True when this error is about one segment rather than the session or connection
    var isTranslationFailure: Bool {
        code == Self.translationRefusedCode || code == Self.translationFailedCode
    }
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

// MARK: - Conversation Events (both sides of the chat)

/// Whose words a conversation line holds
enum ConversationSide: Hashable {
    case me
    case partner
}

/// A transcript from the server (interim or final). Only finals carry a segment id.
struct TranscriptEvent: Equatable {
    let text: String
    let isFinal: Bool
    let segmentId: String?
    /// The speaker's direction (mine for my words, the partner's for theirs)
    let direction: TranslationDirection
}

/// A finished translation for one segment
struct TranslationEvent: Equatable {
    let original: String
    let translated: String
    let segmentId: String?
    /// The speaker's direction (mine for my words, the partner's for theirs)
    let direction: TranslationDirection
    let honorific: Bool?
}

/// A segment the server could not translate (policy refusal or a failed translation call)
struct TranslationFailureEvent: Equatable {
    let message: String
    let code: String?
    let segmentId: String?
    let original: String?
    let direction: TranslationDirection?

    var isRefusal: Bool { code == ErrorMessage.translationRefusedCode }
}

/// One spoken segment as the chat shows it: what was said, and its translation once it arrives
struct ConversationLine: Identifiable, Equatable {
    /// The server's segment_id (a fresh UUID for a translation that arrived without one)
    let id: String
    let side: ConversationSide
    /// The chat bubble this segment shows in (a speaker's consecutive segments share one)
    let turn: String
    var original: String
    var translated: String? = nil
    /// Set when the server reported it couldn't translate this segment
    var failure: TranslationFailureEvent? = nil

    /// Still waiting for the translation (or a failure notice)
    var isPending: Bool { translated == nil && failure == nil }
}

/// What a speaker is saying right now (the server's interim transcript), before it becomes a segment
struct LiveCaption: Equatable {
    var text: String
    /// The chat bubble it shows at the end of
    let turn: String
    let startedAt: Date
}

/// One chat bubble: a speaker's consecutive segments, then whatever they're still saying
struct ConversationTurn: Identifiable, Equatable {
    let id: String
    let side: ConversationSide
    /// In the speaker's language: the finished segments, then the live caption
    var original: String = ""
    /// The finished segments' translations so far
    var translated: String = ""
    /// The newest segment in this bubble the server couldn't translate
    var failure: TranslationFailureEvent? = nil
    /// The speaker is still talking into this bubble
    var isLive: Bool = false
    /// A finished segment is still waiting for its translation
    var isAwaitingTranslation: Bool = false

    fileprivate mutating func add(_ line: ConversationLine) {
        original = Self.joined(original, line.original)
        if let translation = line.translated { translated = Self.joined(translated, translation) }
        if let lineFailure = line.failure { failure = lineFailure }
        if line.isPending { isAwaitingTranslation = true }
    }

    fileprivate mutating func add(_ caption: LiveCaption) {
        original = Self.joined(original, caption.text)
        isLive = true
    }

    private static func joined(_ text: String, _ more: String) -> String {
        if more.isEmpty { return text }
        return text.isEmpty ? more : text + " " + more
    }
}

/// Both sides of the conversation, joined by the server's segment_id.
///
/// A final transcript starts a line; the matching translation (or failure) fills it in.
/// A translation or failure for an unknown segment starts its own line, so nothing is
/// dropped. Interim transcripts are each side's live caption until their final arrives.
/// `turns` groups a speaker's consecutive lines, and their live caption, into chat bubbles.
struct ConversationLog: Equatable {
    private(set) var lines: [ConversationLine] = []
    /// What each side is saying right now (not yet a finished segment)
    private(set) var liveCaptions: [ConversationSide: LiveCaption] = [:]
    /// Oldest lines are dropped beyond this many
    var maxLines: Int = 200
    /// A speaker's next words join their last bubble if they spoke this recently...
    var turnGap: TimeInterval = 4
    /// ...and nobody else spoke since, and the bubble holds fewer segments than this
    var maxSegmentsPerTurn: Int = 4
    /// When each side last said something (interim or final)
    private var lastSpokeAt: [ConversationSide: Date] = [:]

    var latest: ConversationLine? { lines.last }

    mutating func apply(_ event: TranscriptEvent, side: ConversationSide, at now: Date = Date()) {
        guard event.isFinal else {
            // Live caption: what's being said right now (the server includes words it's holding back)
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if liveCaptions[side] != nil {
                liveCaptions[side]?.text = text
            } else {
                liveCaptions[side] = LiveCaption(text: text, turn: turnForNewSpeech(by: side, at: now), startedAt: now)
            }
            lastSpokeAt[side] = now
            return
        }
        guard let id = event.segmentId else { return }
        if let index = index(of: id, side: side) {
            lines[index].original = event.text
        } else {
            append(ConversationLine(id: id, side: side, turn: turnForNewSpeech(by: side, at: now), original: event.text))
        }
        consumeCaption(event.text, side: side)
        lastSpokeAt[side] = now
    }

    mutating func apply(_ event: TranslationEvent, side: ConversationSide, at now: Date = Date()) {
        if let id = event.segmentId, let index = index(of: id, side: side) {
            if lines[index].original.isEmpty { lines[index].original = event.original }
            lines[index].translated = event.translated
            lines[index].failure = nil
        } else {
            append(ConversationLine(
                id: event.segmentId ?? UUID().uuidString,
                side: side,
                turn: turnForNewSpeech(by: side, at: now),
                original: event.original,
                translated: event.translated
            ))
            consumeCaption(event.original, side: side)
            lastSpokeAt[side] = now
        }
    }

    mutating func apply(_ event: TranslationFailureEvent, side: ConversationSide, at now: Date = Date()) {
        if let id = event.segmentId, let index = index(of: id, side: side) {
            if lines[index].original.isEmpty, let original = event.original {
                lines[index].original = original
            }
            lines[index].failure = event
        } else {
            append(ConversationLine(
                id: event.segmentId ?? UUID().uuidString,
                side: side,
                turn: turnForNewSpeech(by: side, at: now),
                original: event.original ?? "",
                failure: event
            ))
            consumeCaption(event.original ?? "", side: side)
            lastSpokeAt[side] = now
        }
    }

    /// Drops live captions whose final will never come (the partner left, the connection dropped,
    /// or the session ended). Nil ends both sides'.
    mutating func endLiveCaptions(of side: ConversationSide? = nil) {
        if let side {
            liveCaptions[side] = nil
        } else {
            liveCaptions.removeAll()
        }
    }

    /// The chat bubbles, oldest first. A live caption ends its speaker's bubble; one whose
    /// bubble has no finished segment yet is a new bubble at the bottom.
    var turns: [ConversationTurn] {
        var result: [ConversationTurn] = []
        var position: [String: Int] = [:]
        for line in lines {
            if position[line.turn] == nil {
                position[line.turn] = result.count
                result.append(ConversationTurn(id: line.turn, side: line.side))
            }
            result[position[line.turn]!].add(line)
        }
        for (side, caption) in liveCaptions.sorted(by: { $0.value.startedAt < $1.value.startedAt }) {
            if position[caption.turn] == nil {
                position[caption.turn] = result.count
                result.append(ConversationTurn(id: caption.turn, side: side))
            }
            result[position[caption.turn]!].add(caption)
        }
        return result
    }

    /// The bubble a side's new words go in: the one they're speaking into, else their last bubble
    /// if it's still the newest, recent and not full, else a new one
    private func turnForNewSpeech(by side: ConversationSide, at now: Date) -> String {
        if let caption = liveCaptions[side] { return caption.turn }
        if let last = lines.last, last.side == side,
           let spoke = lastSpokeAt[side], now.timeIntervalSince(spoke) < turnGap,
           lines.filter({ $0.turn == last.turn }).count < maxSegmentsPerTurn {
            return last.turn
        }
        return UUID().uuidString
    }

    /// A final segment replaces the start of the live caption; what's left is still being said
    private mutating func consumeCaption(_ spoken: String, side: ConversationSide) {
        guard let caption = liveCaptions[side] else { return }
        if let rest = Self.remainder(of: caption.text, after: spoken), !rest.isEmpty {
            liveCaptions[side]?.text = rest
        } else {
            liveCaptions[side] = nil
        }
    }

    /// The words of `caption` after `prefix`, matching letters and digits only (finals add
    /// punctuation and capitals). Nil when the caption doesn't start with those words.
    static func remainder(of caption: String, after prefix: String) -> String? {
        let wanted = prefix.lowercased().filter { $0.isLetter || $0.isNumber }
        var next = wanted.startIndex
        var index = caption.startIndex
        while next < wanted.endIndex, index < caption.endIndex {
            let character = caption[index]
            if character.isLetter || character.isNumber {
                guard character.lowercased() == String(wanted[next]) else { return nil }
                next = wanted.index(after: next)
            }
            index = caption.index(after: index)
        }
        guard next == wanted.endIndex else { return nil }
        // The prefix must end on a word boundary: skip its trailing punctuation, then expect a space
        while index < caption.endIndex, !caption[index].isWhitespace {
            if caption[index].isLetter || caption[index].isNumber { return nil }
            index = caption.index(after: index)
        }
        return caption[index...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func index(of id: String, side: ConversationSide) -> Int? {
        lines.firstIndex { $0.id == id && $0.side == side }
    }

    private mutating func append(_ line: ConversationLine) {
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
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
