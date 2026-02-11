# Real-Time Korean → English Speech Translator

A WebSocket-based backend that receives Korean audio, transcribes it, detects clause boundaries, classifies clause safety, translates via Claude API, and returns English audio.

## Architecture

```
Audio In → STT (Deepgram) → Clause Detector → Safety Classifier → Translator (Claude) → Phrase Buffer → TTS (ElevenLabs) → Audio Out
```

The key innovation is **clause-level buffering** with a **safety classifier** to handle the Korean (SOV) to English (SVO) word order difference. This prevents incorrect translations by waiting for complete clauses before translating.

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

3. Run the server:
```bash
uvicorn src.main:app --reload
```

4. Connect via WebSocket at `ws://localhost:8000/ws/translate`

## WebSocket Protocol

### Client → Server

**Start session:**
```json
{"type": "control", "command": "start"}
```

**Send audio (binary):**
Send raw PCM audio bytes (16-bit, 16kHz, mono)

**Stop session:**
```json
{"type": "control", "command": "stop"}
```

**Flush buffers:**
```json
{"type": "control", "command": "flush"}
```

### Server → Client

**Interim transcription:**
```json
{"type": "transcript_interim", "text": "안녕하세..."}
```

**Clause detected:**
```json
{"type": "clause_detected", "text": "안녕하세요", "connector": "요", "decision": "SAFE"}
```

**Translation:**
```json
{"type": "translation", "original": "안녕하세요", "translated": "Hello", "latency_ms": 450}
```

**Audio output (binary):**
MP3 audio chunks

## Running Tests

```bash
pytest tests/ -v
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `DEEPGRAM_API_KEY` | Deepgram API key for STT | Required |
| `ANTHROPIC_API_KEY` | Anthropic API key for translation | Required |
| `ELEVENLABS_API_KEY` | ElevenLabs API key for TTS | Required |
| `ELEVENLABS_VOICE_ID` | ElevenLabs voice ID | `21m00Tcm4TlvDq8ikWAM` |
| `LOG_LEVEL` | Logging level | `INFO` |

## How the Clause Safety Classifier Works

The classifier determines when it's safe to translate a clause:

**Always SAFE:**
- Sentence-final endings: `습니다`, `어요`, `다`, etc.
- Question markers: `습니까`, `까요`, etc.
- Timeout/buffer limit triggers

**Always WAIT:**
- Modifiers: `는`, `은`, `ㄴ`, `을`, `ㄹ` (noun coming next)
- Intent/purpose: `려고`, `려면`, `도록`

**Context-dependent:**
- `-고` (and): SAFE if past tense, WAIT if perception verb
- `-서` (because): WAIT for effect
- `-면` (if/when): SAFE
- `-지만` (but): SAFE

### Why This Matters

```
Korean:  저는 그 영화를 보고 싶지 않아요
         I    that movie  watch-and want-NEG
         "I don't want to watch that movie"

Without classifier (translating at 보고):
→ "I watched that movie and..." ❌

With classifier (WAIT at 보고, translate at 않아요):
→ "I don't want to watch that movie" ✓
```
