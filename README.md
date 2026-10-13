# Dari – Real-Time Korean ↔ English Voice Translator

<a href="assets/dari-reel.mp4"><img src="assets/dari-reel.gif" alt="Dari reel: an English sentence is held until the Korean verb arrives, then spoken as one natural sentence" width="100%" height="auto"/></a>

<p align="center"><a href="assets/dari-reel.mp4"><strong>▶ Watch the full 45-second reel</strong></a> &nbsp;·&nbsp; <a href="portfolio/hold-or-commit.html"><strong>Try the clause gate in your browser</strong></a></p>

Dari is a live voice translator for conversations between a Korean speaker and an English speaker. Each person holds their own phone and hears the other in their own language, with the conversation shown as a two-sided chat on both screens. It is an iOS app (SwiftUI) backed by a Python streaming pipeline: Deepgram speech-to-text, Claude for translation, ElevenLabs for speech.

What sets it apart is that it was **built around the shape of the Korean language** rather than treating Korean as just another language in a list.

---

## Why Korean needs its own translator

Korean puts the verb last. The subject, the object, the time and the place all arrive first, and the word that decides what the sentence *means* (ate, didn't eat, want to eat, was told to eat) comes at the very end. Negation, tense, intent and politeness all live in that final verb ending.

Spoken audio can't be taken back. A translator that commits as soon as it has a clause produces confident, fluent, wrong sentences:

```
Korean:  저는 그 영화를 보고 싶지 않아요
         I    that movie  watch-and want-NEG
         "I don't want to watch that movie"

Translating as soon as the clause looks complete (at 보고):
→ "I watched that movie and..."      ✗

Holding at 보고 until the verb ending arrives:
→ "I don't want to watch that movie"  ✓
```

Waiting for the whole sentence every time fixes this, but makes the translator feel sluggish and robotic. Dari does neither. It reads each clause as it ends and decides, word by word, whether it is **safe to commit** or should **hold** for more.

### The clause gate: hold or commit

Before any Korean reaches the translation model, a rule-based gate inspects how the clause ends. It runs in well under a millisecond, so the decision costs nothing in latency.

| What the clause ends with | Decision | Why |
|---|---|---|
| Sentence-final endings: `-요`, `-습니다`, `-다`, `-어`, questions `-까요`, `-나요`, `-니` | **Commit** | The verb has landed; the sentence is complete |
| Modifiers: `-는`, `-은`, `-ㄴ`, `-을`, `-ㄹ` | **Hold** | A noun is coming; this is the first half of a phrase |
| `-고` after an action verb (가고, 먹고) or a past tense | **Commit** | A completed action followed by "and" |
| `-고` after a perception verb (보고, 듣고, 만나고) | **Hold** | "want to", "tried to" or an emotion usually follows |
| `-서` / `-아서` / `-어서` | **Hold** | Cause and effect; the effect decides the meaning |
| `-면`, `-지만`, `-니까` | **Commit** | The condition, contrast or reason is self-contained |
| `-는데` | Commit if long, else hold | Background clause; short ones usually set up a twist |
| `-려고` | **Hold** | "in order to" with the intent still unsaid |
| Short affirmations: 네, 아니요, 맞아요, 그래 | **Commit** | One-word answers shouldn't wait |

Three safety valves make sure a held clause never stalls the conversation:

- a **pause** longer than 300 ms flushes whatever is buffered (the speaker stopped, so translate it),
- a **timeout** of 3 s forces the buffer out,
- a **buffer cap** of 100 characters does the same for run-on speech.

The result is a translator that commits as often as it safely can and waits only when Korean grammar says the meaning isn't decided yet. The same rules are ported to the browser in [`portfolio/hold-or-commit.html`](portfolio/hold-or-commit.html), where you can step through a sentence word by word and watch each decision.

English → Korean doesn't need the gate: English puts the verb early, so punctuation and a 500 ms pause are enough to find a sentence boundary.

### Honorifics are a conversation setting

Korean has levels of speech, and picking the wrong one is a social mistake, not a grammatical one. Dari exposes this as a single **Honorifics** (존댓말) card on the live screen:

| | Register | Example for "Did you eat?" |
|---|---|---|
| **OFF** | 반말, casual speech between friends and peers | 밥 먹었어? |
| **ON** | 존댓말, polite speech for elders, strangers and customers, with honorific verb forms (드시다, 계시다, 주무시다) and humble forms (드리다, 뵙다) | 진지 드셨어요? |

The setting belongs to the **room**, not to one phone. Either person can change it mid-conversation, both phones show the same state, and it applies to the English speaker's words from the next sentence on. A phone that joins later inherits the room's setting.

### One conversation, both directions

Both directions share one translation context, so pronouns, names and topics carry across turns regardless of who is speaking. Translation streams token by token from Claude; a phrase buffer groups the stream into natural spoken chunks so the synthesized voice doesn't stutter word by word. Translated text reaches both phones as soon as it is complete, before the last audio clip, so the chat never lags the voice.

---

## How it works

```
Korean speaker's phone                               English speaker's phone
        │ Korean audio                                        │ English audio
        ▼                                                     ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  FastAPI WebSocket server · one room per conversation · one socket per phone │
└──────────────────┬─────────────────────────────────────────┬──────────────┘
                   ▼                                         ▼
┌──────────────────────────────────┐      ┌──────────────────────────────────┐
│   KOREAN → ENGLISH PIPELINE      │      │   ENGLISH → KOREAN PIPELINE      │
│                                  │      │                                  │
│   Deepgram STT (ko)              │      │   Deepgram STT (en)              │
│        ↓                         │      │        ↓                         │
│   Clause detector                │      │   Sentence detector              │
│   (endings · connectors · pause) │      │   (punctuation · pause)          │
│        ↓                         │      │        ↓                         │
│   Clause gate: hold or commit    │      │   Claude translation (streamed)  │
│        ↓                         │      │   + Honorifics (반말 / 존댓말)    │
│   Claude translation (streamed)  │      │        ↓                         │
│        ↓                         │      │   Phrase buffer → ElevenLabs TTS │
│   Phrase buffer → ElevenLabs TTS │      │                                  │
└──────────────────┬───────────────┘      └───────────────┬──────────────────┘
                   │ English voice + text                   │ Korean voice + text
                   ▼                                        ▼
        English speaker's phone                   Korean speaker's phone
```

| | Korean → English | English → Korean |
|---|---|---|
| Word order | SOV → SVO: meaning is decided by the final verb | SVO → SOV |
| Boundary detection | Grammatical endings and connectors | Punctuation and pauses |
| Clause gate | **Yes**, rule-based, before the model | Not needed |
| Register | Follows the speaker | **Honorifics toggle** (반말 / 존댓말) |

**Stack:** SwiftUI iOS app · Python 3 / FastAPI backend · Deepgram Nova-2 streaming STT · Claude Sonnet 5.5 streaming translation (with server-side fallback) · ElevenLabs Turbo v2.5 TTS · voice-based gender detection to pick a matching voice.

**Latency budget** (per clause, either direction):

| Component | Time |
|---|---|
| Speech-to-text | ~300 ms |
| Boundary detection + clause gate | <10 ms |
| Claude translation (first token) | ~400 ms |
| Phrase buffer | <500 ms |
| Text-to-speech | ~250 ms |
| **Total** | **~1.5 s** |

---

## Repository layout

```
KorEngTranslator/   iOS app (SwiftUI): pairing flow, live screen, two-speaker chat, audio capture/playback
src/                Backend
  main.py           WebSocket server, rooms, orchestrator
  pipelines/        kr_to_en (clause detector, clause gate/classifier) and en_to_kr (sentence detector, formality)
  korean/           Korean grammatical patterns the gate is built on
  services/         STT, translation, TTS, phrase buffer, voice detection
  session/          Session manager and the shared translation context
tests/              Backend tests (pytest) and a command-line harness for the iOS network layer
portfolio/          "Hold or commit": the clause gate, ported to the browser
assets/             The reel
```

---

## Quick start

1. Install dependencies:
```bash
pip install -r requirements.txt
```

2. Set up environment variables:
```bash
cp .env.example .env
# Edit .env with your API keys
```

3. Run the server from the repo root:
```bash
.venv/bin/python -m uvicorn src.main:app --host 0.0.0.0 --port 8001
```

- Port `8001` matches the iOS app's default server address.
- `--host 0.0.0.0` is needed for a physical iPhone to reach the Mac over Wi-Fi (the default `127.0.0.1` only accepts connections from the Mac itself).
- Both WebSocket endpoints are served on this port: `/ws/translate` (translation) and `/ws/pair` (Wi-Fi pairing).
- `.venv/bin/python -m src.main` starts the same server using `HOST`/`PORT` from `.env` (defaults `0.0.0.0` and `8001`).

4. Open `KorEngTranslator/KorEngTranslator.xcodeproj` in Xcode and run the app:
- **Simulator:** connects to `localhost`, i.e. `ws://localhost:8001/ws/translate`.
- **Physical iPhone:** connects to the Mac's Bonjour name (`monicas-MacBook-Pro.local`, see `ServerConfig` in `WebSocketManager.swift`); the phone and Mac must be on the same Wi-Fi network. If that name doesn't resolve on your network, pass the Mac's LAN IP with the app's `-serverHost` launch argument (Xcode > Edit Scheme > Run > Arguments), e.g. `-serverHost 192.168.1.23`. Get the IP with `ipconfig getifaddr en0`. If you run the server on a port other than 8001, also pass `-serverPort <port>`.

### Configuration

| Variable | Description |
|----------|-------------|
| `DEEPGRAM_API_KEY` | Deepgram API key for STT |
| `ANTHROPIC_API_KEY` | Anthropic API key for translation |
| `ELEVENLABS_API_KEY` | ElevenLabs API key for TTS |
| `ELEVENLABS_KOREAN_VOICE_ID` | Korean voice ID |
| `ELEVENLABS_ENGLISH_VOICE_ID` | English voice ID |
| `LOG_LEVEL` | Logging level (default: INFO) |

The gate's thresholds (`KO_PAUSE_THRESHOLD_MS`, `KO_CLAUSE_TIMEOUT_MS`, `KO_MAX_BUFFER_CHARS`), the English detector's, the phrase buffer's and the context window (`MAX_CONTEXT_EXCHANGES`) can all be overridden in `.env`; see `src/config.py`.

### Running tests

```bash
pytest tests/ -v
```

`tests/ios_harness/run.sh offline` compiles the app's network layer standalone (no Xcode project needed) and checks message routing and the conversation log; `run.sh live ROOM01 speech.wav` joins a running server as the English speaker.

---

## WebSocket protocol

### `/ws/translate` – rooms

A conversation is a **room** with one Korean and one English speaker. Each phone opens its own
socket and starts a session with its language; the second phone to name the same `room_id`
joins the first.

```json
{
  "type": "start_session",
  "pairing_mode": "manual",
  "user_language": "ko",
  "room_id": "ABC123",
  "config": {"honorific_mode": true}
}
```

The server answers `{"type": "session_started", "room_id": "ABC123", "paired_via": "manual"}`,
then a `config_updated` status with the room's settings (see below), and, once both are in,
`{"type": "partner_joined"}` to both (`{"type": "partner_left"}` when one leaves). Without
`room_id` the server creates a room and returns its id. The legacy form
(`"directions": ["ko_to_en"]`, no `user_language`) still starts a solo session.

### Send audio

16 kHz mono PCM16, tagged with the speaker's direction (`ko_to_en` for the Korean speaker,
`en_to_ko` for the English speaker):

```json
{
  "type": "audio_chunk",
  "direction": "ko_to_en",
  "data": "<base64 encoded audio>",
  "timestamp_ms": 0
}
```

### Honorifics (mid-session)

```json
{"type": "config_update", "honorific_mode": true}
```

`honorific_mode` is room-wide: the first phone to join sets it, a later joiner inherits it, and
either phone can change it. The server applies the change to both sessions and answers **both**
phones with the room's current state, so the other phone's Honorifics card updates too:

```json
{"type": "status", "status": "config_updated", "honorific_mode": true, "gender": null}
```

The same status follows every `session_started`, carrying the setting the joiner should show.
`gender_override` (`"male"` / `"female"`) may be sent in the same message and stays per phone.

### End session

```json
{"type": "session_end"}
```

### Server responses

`direction` is always the **speaker's** direction. In a room, transcripts, translations and
untranslatable-segment errors go to **both** phones (so the chat can show both sides); audio goes
to the listener only; classifier and gender messages stay with the speaker. Solo, the speaker
gets everything including the audio.

**Transcripts:**
```json
{"type": "transcript_interim", "direction": "ko_to_en", "text": "안녕하세..."}
{"type": "transcript_final", "direction": "ko_to_en", "text": "안녕하세요.", "segment_id": "30b9835c"}
```

**Translation** (same `segment_id` as its transcript; sent as soon as the text is complete,
before the last audio clip; `honorific` is the mode the Korean was produced in, `null` for English):
```json
{
  "type": "translation",
  "direction": "en_to_ko",
  "original": "Did you eat?",
  "translated": "진지 드셨어요?",
  "segment_id": "30b9835c",
  "honorific": true
}
```

**Audio** (one complete MP3 per phrase, base64 in JSON):
```json
{"type": "audio", "direction": "ko_to_en", "format": "mp3", "data": "<base64 mp3>"}
```

**Segment that couldn't be translated** (Claude declined, or the translation call broke);
both phones receive it:
```json
{
  "type": "error",
  "direction": "ko_to_en",
  "message": "Couldn't translate that - please rephrase.",
  "recoverable": true,
  "code": "translation_refused",
  "segment_id": "30b9835c",
  "original": "..."
}
```
`code` is `translation_refused` or `translation_failed`. Other errors (`"No active session"`,
invalid direction, ...) have no `code` and go to the speaker only.

**Clause gate decision (KO→EN only, speaker only):**
```json
{"type": "classifier_decision", "clause": "그 영화를 보고", "connector": "고", "decision": "wait"}
```

### `/ws/pair` – finding a partner

Connect with `?direction=ko_to_en` or `?direction=en_to_ko` (`kr_to_en` / `en_to_kr` are
accepted too) and `?mode=wifi` (default) or `?mode=manual`.

- **Wi-Fi mode**: clients on the same network with opposite directions are introduced
  (`searching`, `partner_connected`, `partner_ready`); send
  `{"type": "headphone_status", "connected": true}` - once both have headphones both get
  `{"type": "matched", "room_id": "..."}`. After 6 s without a match the client gets one
  `{"type": "no_match", "room_code": "123456"}` and may keep waiting for a manual join.
- **Manual mode**: the creator sends `{"type": "create_room", "room_code": "208098"}` (answer
  `room_created`, or `create_failed` if another live creator holds the code); the partner sends
  `{"type": "join_room", "room_code": "208098"}`. Both get `matched` with the same `room_id`, or
  the joiner gets `{"type": "join_failed", "reason": "unknown_code"}` and can retry. A code is
  single-use and dies when its creator disconnects.

Both phones then open `/ws/translate` with that `room_id`.
