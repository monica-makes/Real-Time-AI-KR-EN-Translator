# Handoff: two-phone text + status report

Written 2026-09-29 for a new Claude Code chat. Repo: `/Users/monicalin/Projects/KR-EN-Translator` (Python backend in `src/`, SwiftUI app in `KorEngTranslator/`).

## Your task

**Make translated text reach the other phone in a two-phone conversation.** Right now, when two phones are in the same room, the listener hears the translated audio but never sees any text, and neither phone shows the other person's words. Solo testing (one phone) looks fine only because of a workaround.

Second, if time allows: **fix pairing so two real phones can end up in the same room**, since there's no way to test the first task on devices without it. See "Related: pairing".

The user's next big goal after this is redesigning the chat visuals (a transcript-style chat). Build the data path so the chat can show **both sides**: my line + its translation, and the partner's line + its translation.

## Why it's missing: never built, not a regression

Git history (`8750fe7` initial commit → `5f50130` → `d75c004`) shows this was half-built from day one:

- **The app expects it.** `WebSocketManager.swift` (`case .translation`, ~line 575) only shows translations whose direction is the *partner's* (`partnerOutputDirection`), so the app was designed to receive the partner's translated text from the server.
- **The server never sends it.** `BidirectionalOrchestrator._schedule_send` (`src/main.py` ~415) sends every transcript and translation only to the speaker's own socket (`self.ws`). Only audio is routed to the partner (`_send_audio` → `ConversationRoom.route_translation_output`, ~431 / ~99). `ConversationRoom.notify_partner` (~90) exists but has never been called in any commit.
- **The solo workaround hides it.** Commit `5f50130` changed the iOS filter to `direction == partnerOutputDirection || !isPartnerConnected`, so a solo phone shows its own translation. As soon as a partner connects, each phone drops its own translation and receives none from the partner. Result: no text on either phone.

## What to change

### Backend (`src/main.py`)

- When the speaker is in a room **and a partner is connected**, also deliver `translation` (`TranslationResult`, `src/models/schemas.py` ~99) and `transcript_final` (~83) to the partner. Keep sending them to the speaker too, since the chat needs both sides. Optionally forward `transcript_interim` for live captions later.
- **Send through the partner's orchestrator** (`room.orchestrators[partner_lang]._send_json`) so it goes through that socket's `_send_lock`. Don't write to the partner's raw websocket concurrently. Note that the existing audio routing (`route_translation_output`) writes to the raw socket with no lock; consider fixing that the same way.
- The `direction` field stays the speaker's direction (e.g. `ko_to_en` when the Korean speaker talks). The English listener's app already treats `ko_to_en` as `partnerOutputDirection`.
- Optional: translation text is currently emitted only *after* all TTS audio for the segment is generated (`_translate_and_speak` in both pipelines), so text lags the audio. Emitting it before or with the first audio would help the chat.

### iOS (`Network/WebSocketManager.swift`)

- Replace the solo workaround with explicit callbacks, e.g. `onMyTranslation(original, translated)` for my direction and `onPartnerTranslation` for the partner's, so nothing is silently dropped.
- Also pass through `isFinal` and `segmentId` (currently dropped in `MessageTypes.swift`), plus the partner's `transcript_final`. The chat can then join a transcript with its translation by `segment_id`.
- `LiveTranslationScreen` (in `Views/PairingFlow.swift`) currently stores only the last partner line (`partnerLastUtterance` / `partnerTranslation`). `myLastUtterance` is stored but never shown. Keep UI changes minimal: the chat redesign is a separate task. A simple message array in state is enough.

### Tests

- Extend `tests/test_ws_rooms.py`, which drives the real `websocket_translate` handler with scripted sockets and a fake orchestrator. Assert the partner socket receives the speaker's `translation` / `transcript_final`, and that the solo path is unchanged.
- Run a live two-client check against a local backend: two Python websocket clients in the same `room_id`, one `user_language: "en"` and one `"ko"`, streaming 16 kHz PCM16 speech as base64 `audio_chunk` messages. Each client must receive the other's `translation`. For the iOS side, compile the real `WebSocketManager.swift` + `MessageTypes.swift` with `xcrun swiftc -swift-version 5` into a small command-line harness; this worked well for the audio work.

## Related: pairing (two phones can't get into the same room)

All in `Views/PairingFlow.swift` unless noted (line numbers drift because other sessions are editing this file):

1. `PairingWebSocketManager()` is created without the user's direction (`PairingScreen` ~408, `PairingScreenKorean` ~3384; the init default is `"ko_to_en"` ~226). Both phones claim the same direction, and `/ws/pair` only matches opposite directions (`src/main.py` ~926).
2. Headphone status is only sent from `.onChange` (~512 / ~3500), so headphones that were already connected are never reported. `check_match` requires both sides' headphones (`src/main.py` ~940).
3. `debugMode = true` (~418 / ~3394) skips `connect()` in Debug builds.
4. Manual pairing is a local mock: there's a `TODO: Connect to WebSocket with entered code` (~1809), codes are validated only on the device (`validateCode`), and the creator's only way forward is "Simulate Success" with `DEBUG-ROOM-…`. The two phones end up in different rooms.
5. `/ws/pair`: after the 6 s match timeout, `match_timeout` stays in the `done` set and the loop keeps re-sending `no_match` (`src/main.py` ~976–990).
6. Direction strings are inconsistent: onboarding uses `en_to_kr` / `kr_to_en`, while the protocol uses `en_to_ko` / `ko_to_en`.

Quick way to test two phones before pairing is fixed: have both flows open `LiveTranslationScreen` with the same hardcoded room ID in DEBUG. The user's uncommitted shortcut already does this for the English flow with `"ABC123"`.

## Status report (what's done)

Both branches point to the same commits. Nothing has been pushed; `origin/main` is behind.

| Commit | What |
|---|---|
| `5f50130` | (earlier, user) solo-testing fixes, model → `claude-sonnet-5` |
| `d75c004` | Audio pipeline fixes (below) |
| `87942c1` | Translation on Claude Sonnet 5.5 (below) |

**Audio fixes (`d75c004`), verified live with real Deepgram + ElevenLabs and in the Simulator:**
- **Complete MP3s.** The backend sends one complete MP3 per phrase. It used to send 1 KB fragments, and the app could only play about 26 ms of each phrase.
- **STT survives pauses.** It reconnects when Deepgram drops the stream, sends KeepAlive while the mic is paused, and backs off on repeated failures.
- **Last phrase isn't stuck.** The final phrase before a mic pause is flushed on Deepgram end-of-speech or an idle Finalize.
- **Stop keeps the trailing phrase.** `stop()` finalizes before shutting down, and cleanup always runs.
- **Quick re-join stays in the room.** Room cleanup only removes the socket it owns.
- **One configurable address.** Backend `HOST`/`PORT` defaults to `0.0.0.0:8001`. iOS has `ServerConfig` (top of `WebSocketManager.swift`): Simulator → `localhost`; device → `monicas-MacBook-Pro.local`; override with the launch arguments `-serverHost` / `-serverPort`. `/ws/pair` uses the same host and port.
- **Mic recovers.** Server errors no longer block the mic. A transport drop resets the screen so the next mic tap re-joins; after Stop, the re-join restarts the session on the same socket.
- **Echo guard.** The app sends silence while translated speech plays through the phone speaker.
- **Cleaner mic audio.** One reused `AVAudioConverter` per capture session; the mic permission request moved to the live screen.

**Sonnet 5.5 (`87942c1`), verified with 59 live API calls and 32 offline tests:**
- **Request settings.** `src/services/translator.py` uses `claude-sonnet-5-5` via `client.beta.messages.stream`: `max_tokens=1024`, `thinking={"type": "between_tools"}` (thinking off; `{"type": "disabled"}` is a 400 on 5.5, and `between_tools` is 5.5-only), `output_config={"effort": "low"}`, and a server-side fallback (`betas=["server-side-fallback-2026-07-01"]`, `fallbacks="default"`) that retries cyber and frontier_llm declines on Sonnet 5.
- **Quality and speed.** Translations were correct in KO→EN, EN→KO and EN→KO honorific, and shared context works. Median time to first token is about 0.8 s (p95 about 1.4 s), no different from adaptive thinking at low effort on this workload. `between_tools` was kept because it guarantees no thinking delay on harder sentences.
- **Refusals.** The stop reason is checked after streaming. A refusal raises `TranslationRefused` and is never saved to the shared context; the pipelines log it as a warning and drop the partial. `max_tokens` truncation and fallback-served replies are logged.
- **Follow-up for you.** A refused segment is currently silent: the listener may hear a phrase that was already spoken, and neither phone gets text or a notice. When you route text between phones, also send an `ErrorMessage` ("couldn't translate that - please rephrase") to both phones. The pipelines' `except TranslationRefused` blocks in `_translate_and_speak` are the hook.
- **Optional prompt tweaks.** "My sister" became 언니 (a female speaker's older sister) when the gender and age are unknown; a rule preferring 동생 would be safer. For elders, the honorific prompt could add a 진지 드시다 example.

**Still open (not part of your task unless the user asks):**
- **Chat visuals redesign.** The user's next goal. The status pill shows a red "Connecting..." after Stop until the mic is tapped; that belongs to this work.
- **Slow first phrase.** About 3.5 s extra on the first utterance after server start: gender detection (librosa `yin` + numba warm-up) runs on the event loop (`main.py` `handle_audio`, `services/voice_detection.py`). Fix with `asyncio.to_thread` or a warm-up at startup.
- **Korean clause detector.** A comma blocks connector detection, and Korean spacing is stripped by `"".join` (`src/pipelines/kr_to_en/clause_detector.py`).
- **Not yet checked on a physical iPhone:** `.local` host resolution, the Local Network prompt, the echo guard, and mic permission.
- **Minor cleanup.** The README protocol section is out of date (`audio_out` + binary frames). The voice IDs in `.env` are ignored (hardcoded `VOICES` table in `voice_detection.py`).

## Working rules for this repo

- **Other Claude sessions edit the iOS UI at the same time** (orb effects, Liquid Glass, layout). Their work is uncommitted: `DesignSystem.swift`, `project.pbxproj` (deployment target now 26.0), `KorEngTranslatorApp.swift`, `OrganicBubble.swift`, `SiriGlassBubble.swift`, parts of `PairingFlow.swift`, and `WelcomeScreenLangSelect.swift`.
- **Commit only your own changes.** Stage by path. For a file that also holds others' edits, build a patch with only your hunks and `git apply --cached` it. **Never commit** the user's preview shortcut in `WelcomeScreenLangSelect.swift` (`EnglishSelectedScreen` starts at `.liveTranslation(roomId: "ABC123")`).
- **Branches.** Work on `debug-prototyping` and don't switch branches. The user wants changes on both branches: after committing, run `git fetch . debug-prototyping:main` (fast-forward only). Commit only with the user's go-ahead. Don't push unless asked.
- **Leave port 8000 alone.** It's held by an unrelated static server (`rangeserver.py`, PID 51071, from another project). Run the backend on 8001:
  ```bash
  .venv/bin/python -m uvicorn src.main:app --host 0.0.0.0 --port 8001
  ```
- **Backend tests.** Baseline is 188 passed:
  ```bash
  .venv/bin/python -m pytest -q -p no:cacheprovider tests --ignore=tests/frontend --deselect tests/test_vad.py::test_vad_with_silence --deselect tests/test_vad.py::test_vad_with_file --deselect tests/test_edge_cases.py::test_file --deselect tests/test_backend_vad.py::test_vad
  ```
- **iOS build** (use a scratch DerivedData path):
  ```bash
  xcodebuild -project KorEngTranslator/KorEngTranslator.xcodeproj -scheme KorEngTranslator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/kr-dd CODE_SIGNING_ALLOWED=NO build
  ```
