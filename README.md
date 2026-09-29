# Bidirectional Korean ↔ English Real-Time Speech Translator

A WebSocket-based backend for real-time bidirectional speech translation between Korean and English. Both directions can run simultaneously in a single session, enabling natural conversation between speakers of different languages.

## Architecture

```
Korean Speaker                                    English Speaker
     │                                                  │
     │ Korean Audio                          English Audio
     ▼                                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                     WEBSOCKET HANDLER                           │
│              Routes audio based on direction                    │
└─────────────────────┬───────────────────────────┬───────────────┘
                      │                           │
                      ▼                           ▼
┌─────────────────────────────────┐ ┌─────────────────────────────────┐
│    KOREAN → ENGLISH PIPELINE    │ │    ENGLISH → KOREAN PIPELINE    │
│                                 │ │                                 │
│  STT (Korean)                   │ │  STT (English)                  │
│       ↓                         │ │       ↓                         │
│  Clause Detector                │ │  Sentence Detector              │
│       ↓                         │ │  (simple punctuation)           │
│  Safety Classifier              │ │       ↓                         │
│  (SAFE/WAIT decision)           │ │  Translator (Claude)            │
│       ↓                         │ │  + Formality Toggle             │
│  Translator (Claude)            │ │       ↓                         │
│       ↓                         │ │  TTS (Korean Voice)             │
│  TTS (English Voice)            │ │                                 │
└─────────────────────────────────┘ └─────────────────────────────────┘
                      │                           │
                      ▼                           ▼
               English Audio                Korean Audio
                      │                           │
                      ▼                           ▼
              Korean Speaker                English Speaker
               (receives)                    (receives)
```

## Key Differences Between Directions

| Aspect | Korean → English | English → Korean |
|--------|------------------|------------------|
| Word Order | SOV → SVO (complex) | SVO → SOV (simpler) |
| Boundary Detection | Grammatical patterns | Punctuation |
| Safety Classifier | **Required** | Not needed |
| Formality | N/A | **Toggle (해요체/높임말)** |

### Why Korean → English Needs a Safety Classifier

Korean verbs come at the end of sentences, so translating too early can produce incorrect results:

```
Korean:  저는 그 영화를 보고 싶지 않아요
         I    that movie  watch-and want-NEG
         "I don't want to watch that movie"

Without classifier (translating at 보고):
→ "I watched that movie and..." ❌

With classifier (WAIT at 보고):
→ "I don't want to watch that movie" ✓
```

## Quick Start

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

4. Connect the iOS app:
- **Simulator:** connects to `localhost`, i.e. `ws://localhost:8001/ws/translate`.
- **Physical iPhone:** connects to the Mac's Bonjour name (`monicas-MacBook-Pro.local`, see `ServerConfig` in `WebSocketManager.swift`); the phone and Mac must be on the same Wi-Fi network. If that name doesn't resolve on your network, pass the Mac's LAN IP with the app's `-serverHost` launch argument (Xcode > Edit Scheme > Run > Arguments), e.g. `-serverHost 192.168.1.23`. Get the IP with `ipconfig getifaddr en0`. If you run the server on a port other than 8001, also pass `-serverPort <port>`.

## WebSocket Protocol

### `/ws/translate` - rooms

A conversation is a **room** with one Korean and one English speaker. Each phone opens its own
socket and starts a session with its language; the second phone to name the same `room_id`
joins the first.

```json
{
  "type": "start_session",
  "pairing_mode": "manual",
  "user_language": "ko",
  "room_id": "ABC123",
  "config": {"honorific_mode": false}
}
```

The server answers `{"type": "session_started", "room_id": "ABC123", "paired_via": "manual"}`
and, once both are in, `{"type": "partner_joined"}` to both (`{"type": "partner_left"}` when one
leaves). Without `room_id` the server creates a room and returns its id. The legacy form
(`"directions": ["ko_to_en"]`, no `user_language`) still starts a solo session.

### Send Audio

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

### Update Config (Mid-Session)

```json
{
  "type": "config_update",
  "honorific_mode": true
}
```

### End Session

```json
{
  "type": "session_end"
}
```

### Server Responses

`direction` is always the **speaker's** direction. In a room, transcripts, translations and
untranslatable-segment errors go to **both** phones (so a chat can show both sides); audio goes
to the listener only; classifier and gender messages stay with the speaker. Solo, the speaker
gets everything including the audio.

**Transcripts:**
```json
{"type": "transcript_interim", "direction": "ko_to_en", "text": "안녕하세..."}
{"type": "transcript_final", "direction": "ko_to_en", "text": "안녕하세요.", "segment_id": "30b9835c"}
```

**Translation** (same `segment_id` as its transcript; sent as soon as the text is complete,
before the last audio clip):
```json
{
  "type": "translation",
  "direction": "ko_to_en",
  "original": "안녕하세요.",
  "translated": "Hello.",
  "segment_id": "30b9835c",
  "honorific": null
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

**Classifier Decision (KO→EN only, speaker only):**
```json
{"type": "classifier_decision", "clause": "그 영화를 보고", "connector": "고", "decision": "wait"}
```

### `/ws/pair` - finding a partner

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

## Usage Scenarios

### Korean Speaker Only
```python
SessionConfig(
    directions=["ko_to_en"],
    honorific_mode=False  # Not used
)
```

### English Speaker to Elder
```python
SessionConfig(
    directions=["en_to_ko"],
    honorific_mode=True  # Use 높임말
)
```

### Full Bidirectional
```python
SessionConfig(
    directions=["ko_to_en", "en_to_ko"],
    honorific_mode=False  # Can toggle mid-session
)
```

## Formality Toggle (EN→KO)

**OFF (해요체 - polite informal):**
- 밥 먹었어요? (Did you eat?)
- 안녕하세요 (Hello)

**ON (높임말 - honorific):**
- 진지 드셨어요? (Did you eat? - honorific)
- 안녕하십니까 (Hello - honorific)

## Running Tests

```bash
pytest tests/ -v
```

## Configuration

| Variable | Description |
|----------|-------------|
| `DEEPGRAM_API_KEY` | Deepgram API key for STT |
| `ANTHROPIC_API_KEY` | Anthropic API key for translation |
| `ELEVENLABS_API_KEY` | ElevenLabs API key for TTS |
| `ELEVENLABS_KOREAN_VOICE_ID` | Korean voice ID |
| `ELEVENLABS_ENGLISH_VOICE_ID` | English voice ID |
| `LOG_LEVEL` | Logging level (default: INFO) |

## Latency Budget

| Component | KO→EN | EN→KO |
|-----------|-------|-------|
| STT | ~300ms | ~300ms |
| Boundary Detection | <10ms | <10ms |
| Safety Classifier | <5ms | N/A |
| Claude Translation | ~400ms | ~400ms |
| Phrase Buffer | <500ms | <500ms |
| TTS | ~250ms | ~250ms |
| **Total** | **~1.5s** | **~1.5s** |
