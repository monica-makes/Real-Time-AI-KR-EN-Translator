// Command-line harness for the app's network layer (WebSocketManager.swift + MessageTypes.swift).
//
// Builds with plain swiftc, no Xcode project needed - see run.sh.
//
//   harness offline
//       Injects server frames into a WebSocketManager and checks that my/partner transcripts,
//       translations and "couldn't translate" errors reach the right callbacks, and that
//       ConversationLog joins them by segment id.
//
//   harness live <room_id> <speech.wav> [ws://host:port/ws/translate]
//       Joins <room_id> on a running backend as the ENGLISH speaker, streams <speech.wav>
//       (16 kHz mono PCM16) as audio_chunk messages the way the app does, and prints every
//       conversation event. Exits 0 once it has received its own en_to_ko translation and,
//       if a Korean partner spoke, that partner's ko_to_en translation.

import Foundation

// MARK: - Helpers

var failures = 0

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        failures += 1
        print("  FAIL \(what)")
    }
}

func finish() -> Never {
    if failures == 0 {
        print("PASS")
        exit(0)
    }
    print("FAIL (\(failures) checks)")
    exit(1)
}

/// PCM16 payload of a RIFF WAV file (the data chunk); the header is assumed to be 16 kHz mono
func pcmData(fromWavAt path: String) -> Data? {
    guard let file = FileManager.default.contents(atPath: path), file.count > 12 else { return nil }
    var offset = 12  // after "RIFF", size, "WAVE"
    while offset + 8 <= file.count {
        let id = String(decoding: file[offset..<offset + 4], as: UTF8.self)
        let size = Int(file[offset + 4]) | Int(file[offset + 5]) << 8 | Int(file[offset + 6]) << 16 | Int(file[offset + 7]) << 24
        if id == "data" {
            let end = min(file.count, offset + 8 + size)
            return file.subdata(in: (offset + 8)..<end)
        }
        offset += 8 + size + (size & 1)
    }
    return nil
}

// MARK: - Offline checks (no server)

@MainActor
func runOffline() {
    print("offline: routing + conversation log")
    let manager = WebSocketManager()
    manager.configure(userLanguage: .english)  // I speak English: my direction en_to_ko, partner's ko_to_en

    var log = ConversationLog()
    var myTranscripts: [TranscriptEvent] = []
    var partnerTranscripts: [TranscriptEvent] = []
    var myTranslations: [TranslationEvent] = []
    var partnerTranslations: [TranslationEvent] = []
    var failuresSeen: [(TranslationFailureEvent, ConversationSide)] = []
    var genericErrors: [String] = []

    manager.onMyTranscript = { myTranscripts.append($0); log.apply($0, side: .me) }
    manager.onPartnerTranscript = { partnerTranscripts.append($0); log.apply($0, side: .partner) }
    manager.onMyTranslation = { myTranslations.append($0); log.apply($0, side: .me) }
    manager.onPartnerTranslation = { partnerTranslations.append($0); log.apply($0, side: .partner) }
    manager.onTranslationFailed = { failuresSeen.append(($0, $1)); log.apply($0, side: $1) }
    manager.onError = { genericErrors.append($0) }

    // The Korean partner speaks: transcript, then translation (as the server now forwards them)
    manager.handleTextMessage(#"{"type":"transcript_interim","direction":"ko_to_en","text":"안녕"}"#)
    manager.handleTextMessage(#"{"type":"transcript_final","direction":"ko_to_en","text":"안녕하세요","segment_id":"k1"}"#)
    manager.handleTextMessage(#"{"type":"translation","direction":"ko_to_en","original":"안녕하세요","translated":"Hello","segment_id":"k1","honorific":null}"#)

    // I speak: my own transcript and translation come back to me too
    manager.handleTextMessage(#"{"type":"transcript_final","direction":"en_to_ko","text":"Nice to meet you","segment_id":"e1"}"#)
    manager.handleTextMessage(#"{"type":"translation","direction":"en_to_ko","original":"Nice to meet you","translated":"만나서 반가워요","segment_id":"e1","honorific":false}"#)

    // The partner's next sentence can't be translated (both phones get this error)
    manager.handleTextMessage(#"{"type":"transcript_final","direction":"ko_to_en","text":"문제의 문장","segment_id":"k2"}"#)
    manager.handleTextMessage(#"{"type":"error","direction":"ko_to_en","message":"Couldn't translate that - please rephrase.","recoverable":true,"code":"translation_refused","segment_id":"k2","original":"문제의 문장"}"#)

    // A translation whose transcript never arrived (trailing clause on an old server) still shows up
    manager.handleTextMessage(#"{"type":"translation","direction":"en_to_ko","original":"See you","translated":"또 봐요","segment_id":"e2"}"#)

    // A session-level error is not a translation failure
    manager.handleTextMessage(#"{"type":"error","message":"No active session","recoverable":true}"#)

    check(partnerTranscripts.map { $0.text } == ["안녕", "안녕하세요", "문제의 문장"], "partner transcripts (interim + finals) routed by ko_to_en")
    check(partnerTranscripts.map { $0.isFinal } == [false, true, true], "isFinal passed through")
    check(partnerTranscripts[1].segmentId == "k1", "segment id passed through on transcript")
    check(myTranscripts.map { $0.text } == ["Nice to meet you"], "my transcript routed by en_to_ko")
    check(partnerTranslations.map { $0.translated } == ["Hello"], "partner translation routed to onPartnerTranslation")
    check(myTranslations.map { $0.translated } == ["만나서 반가워요", "또 봐요"], "my translations routed to onMyTranslation (nothing dropped)")
    check(myTranslations[0].segmentId == "e1" && myTranslations[0].honorific == false, "segment id and honorific passed through on translation")
    check(failuresSeen.count == 1 && failuresSeen[0].0.isRefusal && failuresSeen[0].0.segmentId == "k2" && failuresSeen[0].1 == .partner,
          "refusal delivered to onTranslationFailed as the partner's segment")
    check(genericErrors == ["No active session"], "generic error still goes to onError")

    let lines = log.lines
    check(lines.map { $0.id } == ["k1", "e1", "k2", "e2"], "log has one line per segment in arrival order")
    check(lines[0].side == .partner && lines[0].original == "안녕하세요" && lines[0].translated == "Hello", "partner line joined with its translation by segment id")
    check(lines[1].side == .me && lines[1].original == "Nice to meet you" && lines[1].translated == "만나서 반가워요", "my line joined with its translation")
    check(lines[2].failure != nil && lines[2].translated == nil && lines[2].original == "문제의 문장", "refused segment marked failed, not pending")
    check(lines[3].original == "See you" && lines[3].translated == "또 봐요" && lines[3].side == .me, "translation without a transcript starts its own line")
    check(log.latest?.id == "e2", "latest line is the newest")

    // Solo phone: my own translation is delivered (the old code dropped it once a partner joined)
    let solo = WebSocketManager()
    solo.configure(userLanguage: .korean)
    var soloMine: [TranslationEvent] = []
    solo.onMyTranslation = { soloMine.append($0) }
    solo.handleTextMessage(#"{"type":"translation","direction":"ko_to_en","original":"안녕","translated":"Hi","segment_id":"s1"}"#)
    check(soloMine.map { $0.translated } == ["Hi"], "Korean solo phone gets its own ko_to_en translation as mine")

    // Log keeps the newest lines only
    var small = ConversationLog()
    small.maxLines = 2
    for i in 0..<5 {
        small.apply(TranscriptEvent(text: "t\(i)", isFinal: true, segmentId: "s\(i)", direction: .koreanToEnglish), side: .partner)
    }
    check(small.lines.map { $0.id } == ["s3", "s4"], "log is capped at maxLines")

    finish()
}

// MARK: - Live check against a running backend (as the English speaker)

@MainActor
func runLive(roomId: String, wavPath: String, url: String) async {
    guard let pcm = pcmData(fromWavAt: wavPath) else {
        print("could not read PCM data from \(wavPath)")
        exit(2)
    }
    print("live: joining \(roomId) at \(url) as English speaker, \(pcm.count) bytes of speech")

    let manager = WebSocketManager()
    var log = ConversationLog()
    var sawMyTranslation = false
    var sawPartnerTranslation = false
    var partnerSpoke = false
    var partnerConnected = false

    manager.onSessionStarted = { print("  session_started room=\($0)") }
    manager.onPartnerJoined = { partnerConnected = true; print("  partner_joined") }
    manager.onPartnerLeft = { print("  partner_left") }
    manager.onMyTranscript = { event in
        log.apply(event, side: .me)
        if event.isFinal { print("  my transcript_final [\(event.segmentId ?? "-")]: \(event.text)") }
    }
    manager.onPartnerTranscript = { event in
        log.apply(event, side: .partner)
        if event.isFinal { partnerSpoke = true; print("  partner transcript_final [\(event.segmentId ?? "-")]: \(event.text)") }
    }
    manager.onMyTranslation = { event in
        log.apply(event, side: .me)
        sawMyTranslation = true
        print("  my translation [\(event.segmentId ?? "-")] \(event.direction.rawValue): \(event.original) -> \(event.translated)")
    }
    manager.onPartnerTranslation = { event in
        log.apply(event, side: .partner)
        sawPartnerTranslation = true
        print("  partner translation [\(event.segmentId ?? "-")] \(event.direction.rawValue): \(event.original) -> \(event.translated)")
    }
    manager.onTranslationFailed = { event, side in
        log.apply(event, side: side)
        print("  not translated (\(side)) [\(event.segmentId ?? "-")]: \(event.message)")
    }
    manager.onAudioReceived = { data in print("  audio \(data.count) bytes") }
    manager.onError = { print("  server error: \($0)") }
    manager.onDisconnected = { print("  disconnected: \($0)"); exit(3) }

    manager.joinRoom(roomId: roomId, userLanguage: .english, honorificMode: false, to: url)

    // Give the join a moment (the manager sends start_session 0.5 s after connecting)
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    guard manager.connectionState.isConnected else {
        print("not connected: \(manager.connectionState.displayText)")
        exit(3)
    }

    // Let a Korean partner (the Python client) join and speak first, if one is coming
    let waitForPartnerUntil = Date().addingTimeInterval(6)
    while !partnerConnected && Date() < waitForPartnerUntil {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    if partnerConnected {
        let waitForPartnerSpeechUntil = Date().addingTimeInterval(25)
        while !sawPartnerTranslation && Date() < waitForPartnerSpeechUntil {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // Stream the English speech in 100 ms chunks like the app (16 kHz * 2 bytes * 0.1 s), then silence
    let chunk = 3200
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + chunk, pcm.count)
        manager.sendAudioChunk(pcm.subdata(in: offset..<end))
        offset = end
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    for _ in 0..<25 {
        manager.sendAudioChunk(Data(count: chunk))
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    let deadline = Date().addingTimeInterval(25)
    while Date() < deadline {
        if sawMyTranslation && (!partnerSpoke || sawPartnerTranslation) { break }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    manager.sendSessionEnd()
    try? await Task.sleep(nanoseconds: 500_000_000)
    manager.disconnect()

    print("conversation log:")
    for line in log.lines {
        let status = line.failure != nil ? "FAILED: \(line.failure!.message)" : (line.translated ?? "(pending)")
        print("  [\(line.side == .me ? "me" : "partner")] \(line.original) -> \(status)")
    }
    check(sawMyTranslation, "received my own en_to_ko translation")
    if partnerSpoke {
        check(sawPartnerTranslation, "received the Korean partner's ko_to_en translation")
        check(log.lines.contains { $0.side == .partner && $0.translated != nil }, "partner line joined with its translation")
    } else {
        print("  (no Korean partner spoke - solo run)")
    }
    finish()
}

// MARK: - Entry

let args = CommandLine.arguments
Task { @MainActor in
    switch args.dropFirst().first {
    case "offline":
        runOffline()
    case "live":
        let rest = Array(args.dropFirst(2))
        guard rest.count >= 2 else {
            print("usage: harness live <room_id> <speech.wav> [ws://host:port/ws/translate]")
            exit(2)
        }
        await runLive(roomId: rest[0], wavPath: rest[1], url: rest.count > 2 ? rest[2] : "ws://localhost:8001/ws/translate")
    default:
        print("usage: harness offline | harness live <room_id> <speech.wav> [url]")
        exit(2)
    }
}
RunLoop.main.run()
