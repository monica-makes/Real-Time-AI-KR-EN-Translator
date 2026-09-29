"""
Live two-phone check against a running backend (real Deepgram, Claude and ElevenLabs).

Two websocket clients join the same room, one Korean and one English speaker, and take
turns streaming 16 kHz PCM16 speech as base64 audio_chunk messages. The check passes when
each client receives the OTHER speaker's transcript_final and translation (with matching
segment ids), each speaker still receives its own, and the listener gets the audio.

Not collected by pytest (no test_ prefix). Run with the backend on port 8001:

    .venv/bin/python -m uvicorn src.main:app --host 0.0.0.0 --port 8001
    .venv/bin/python tests/live_two_client_check.py --ko-wav ko.wav --en-wav en.wav

WAVs must be 16 kHz mono PCM16 (afconvert -f WAVE -d LEI16@16000 -c 1 in.mp3 out.wav).
"""

import argparse
import asyncio
import base64
import json
import sys
import time
import uuid
import wave

import websockets

CHUNK_MS = 100
SILENCE_TAIL_S = 2.5  # Let Deepgram end the utterance after the speech


def read_pcm(path: str) -> bytes:
    with wave.open(path, "rb") as wav:
        assert wav.getframerate() == 16000 and wav.getnchannels() == 1 and wav.getsampwidth() == 2, \
            f"{path}: need 16 kHz mono PCM16, got {wav.getframerate()} Hz {wav.getnchannels()} ch {wav.getsampwidth() * 8} bit"
        return wav.readframes(wav.getnframes())


class Client:
    """One phone: a language, its socket and everything the server sent it."""

    def __init__(self, language: str, url: str, room_id: str):
        self.language = language
        self.direction = "ko_to_en" if language == "ko" else "en_to_ko"
        self.partner_direction = "en_to_ko" if language == "ko" else "ko_to_en"
        self.url = url
        self.room_id = room_id
        self.received: list[dict] = []
        self.ws = None
        self._reader = None

    async def connect(self) -> None:
        self.ws = await websockets.connect(self.url, max_size=None)
        self._reader = asyncio.create_task(self._read())
        await self.send({"type": "start_session", "pairing_mode": "manual", "user_language": self.language,
                         "room_id": self.room_id, "config": {"honorific_mode": False}})
        await self.wait_for(lambda m: m.get("type") == "session_started", 5, "session_started")

    async def _read(self) -> None:
        try:
            async for raw in self.ws:
                msg = json.loads(raw)
                self.received.append(msg)
                if msg.get("type") != "audio":
                    print(f"  [{self.language}] <- {json.dumps(msg, ensure_ascii=False)[:160]}")
                else:
                    print(f"  [{self.language}] <- audio {msg.get('direction')} ({len(msg.get('data', ''))} b64 chars)")
        except websockets.ConnectionClosed:
            pass

    async def send(self, msg: dict) -> None:
        await self.ws.send(json.dumps(msg))

    async def speak(self, pcm: bytes) -> None:
        """Stream speech in real time as the app does, then a silent tail."""
        chunk = 16000 * 2 * CHUNK_MS // 1000
        for offset in range(0, len(pcm), chunk):
            await self.send({"type": "audio_chunk", "direction": self.direction,
                             "data": base64.b64encode(pcm[offset:offset + chunk]).decode(),
                             "timestamp_ms": int(time.time() * 1000)})
            await asyncio.sleep(CHUNK_MS / 1000)
        for _ in range(int(SILENCE_TAIL_S * 1000 / CHUNK_MS)):
            await self.send({"type": "audio_chunk", "direction": self.direction,
                             "data": base64.b64encode(bytes(chunk)).decode(),
                             "timestamp_ms": int(time.time() * 1000)})
            await asyncio.sleep(CHUNK_MS / 1000)

    async def wait_for(self, predicate, timeout: float, what: str) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for msg in self.received:
                if predicate(msg):
                    return msg
            await asyncio.sleep(0.05)
        raise AssertionError(f"[{self.language}] did not receive {what} within {timeout:.0f}s")

    def of_type(self, msg_type: str, direction: str | None = None) -> list[dict]:
        return [m for m in self.received
                if m.get("type") == msg_type and (direction is None or m.get("direction") == direction)]

    async def close(self) -> None:
        try:
            await self.send({"type": "session_end"})
            await asyncio.sleep(0.3)
            await self.ws.close()
        except Exception:
            pass
        if self._reader:
            self._reader.cancel()


async def turn(speaker: Client, listener: Client, pcm: bytes, timeout: float) -> list[str]:
    """One person speaks; return a list of failed expectations."""
    print(f"\n{speaker.language} speaks ({len(pcm) / 32000:.1f}s of audio)")
    before = {c: len(c.received) for c in (speaker, listener)}
    await speaker.speak(pcm)

    problems = []
    try:
        await listener.wait_for(lambda m: m.get("type") == "translation" and m.get("direction") == speaker.direction,
                                timeout, f"{speaker.direction} translation")
    except AssertionError as e:
        problems.append(str(e))

    def new(client: Client, msg_type: str) -> list[dict]:
        return [m for m in client.received[before[client]:]
                if m.get("type") == msg_type and m.get("direction") == speaker.direction]

    listener_finals, listener_translations = new(listener, "transcript_final"), new(listener, "translation")
    speaker_finals, speaker_translations = new(speaker, "transcript_final"), new(speaker, "translation")
    listener_audio, speaker_audio = new(listener, "audio"), new(speaker, "audio")
    listener_errors = [m for m in listener.received[before[listener]:] if m.get("type") == "error"]

    if not listener_translations:
        problems.append(f"listener {listener.language} got no {speaker.direction} translation")
    if not listener_finals:
        problems.append(f"listener {listener.language} got no {speaker.direction} transcript_final")
    if not speaker_translations:
        problems.append(f"speaker {speaker.language} no longer gets its own translation")
    if not speaker_finals:
        problems.append(f"speaker {speaker.language} no longer gets its own transcript_final")
    if listener_translations != speaker_translations:
        problems.append("listener and speaker received different translation messages")
    if listener_finals != speaker_finals:
        problems.append("listener and speaker received different transcript_final messages")
    final_ids = {m["segment_id"] for m in listener_finals}
    for t in listener_translations:
        if t["segment_id"] not in final_ids:
            problems.append(f"translation segment {t['segment_id']} has no transcript_final on the listener")
    if not listener_audio:
        problems.append(f"listener {listener.language} got no audio")
    if speaker_audio:
        problems.append(f"speaker {speaker.language} received its own audio ({len(speaker_audio)} clips)")
    for err in listener_errors:
        if err.get("code") in ("translation_refused", "translation_failed"):
            print(f"  note: segment {err.get('segment_id')} reported as {err['code']} on both phones")
            if err not in speaker.received[before[speaker]:]:
                problems.append("untranslatable-segment error reached the listener but not the speaker")

    for t in listener_translations:
        print(f"  {listener.language} sees {speaker.language}'s line [{t['segment_id']}]: {t['original']} -> {t['translated']}")
    return problems


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="ws://localhost:8001/ws/translate")
    parser.add_argument("--room", default=None, help="room id (default: random)")
    parser.add_argument("--ko-wav", required=True, help="Korean speech, 16 kHz mono PCM16")
    parser.add_argument("--en-wav", required=True, help="English speech, 16 kHz mono PCM16")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for each translation")
    args = parser.parse_args()

    room_id = args.room or f"LIVE-{uuid.uuid4().hex[:6].upper()}"
    ko_pcm, en_pcm = read_pcm(args.ko_wav), read_pcm(args.en_wav)
    ko, en = Client("ko", args.url, room_id), Client("en", args.url, room_id)

    print(f"room {room_id} at {args.url}")
    await ko.connect()
    await en.connect()
    await ko.wait_for(lambda m: m.get("type") == "partner_joined", 5, "partner_joined")
    await en.wait_for(lambda m: m.get("type") == "partner_joined", 5, "partner_joined")
    await asyncio.sleep(1.0)  # let both STT streams open

    problems = []
    try:
        problems += await turn(ko, en, ko_pcm, args.timeout)
        problems += await turn(en, ko, en_pcm, args.timeout)
    finally:
        await ko.close()
        await en.close()

    print()
    if problems:
        print("FAIL")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("PASS: each phone received the other's transcript and translation, and its own")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
