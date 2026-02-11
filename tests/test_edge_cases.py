#!/usr/bin/env python3
"""Test edge cases with full pipeline latency tracking."""

import asyncio
import json
import os
import time
import wave
import websockets
from dataclasses import dataclass, field
from typing import List, Dict, Optional

# Get directory of this script for relative paths
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
EDGE_CASES_DIR = os.path.join(SCRIPT_DIR, "audio/edge-cases")
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "audio/edge-cases-outputs")

WS_URL = "ws://localhost:8000/ws/translate?direction={direction}"
CHUNK_MS = 100
SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2


@dataclass
class TimingResult:
    """Timing result for a single step."""
    step: str
    start_ms: float
    end_ms: float
    duration_ms: float
    details: str = ""


@dataclass
class TestResult:
    """Result of running a single test file."""
    filename: str
    direction: str
    success: bool
    error: Optional[str] = None
    audio_duration_ms: float = 0

    # Timing results
    timings: List[TimingResult] = field(default_factory=list)

    # Pipeline outputs
    transcripts: List[Dict] = field(default_factory=list)
    translations: List[Dict] = field(default_factory=list)
    gender_detected: Optional[str] = None
    classifier_decisions: List[Dict] = field(default_factory=list)

    # Audio output
    audio_output_bytes: int = 0

    def add_timing(self, step: str, start_ms: float, end_ms: float, details: str = ""):
        self.timings.append(TimingResult(
            step=step,
            start_ms=start_ms,
            end_ms=end_ms,
            duration_ms=end_ms - start_ms,
            details=details
        ))

    def total_latency_ms(self) -> float:
        """Total pipeline latency from first audio to last output."""
        if not self.timings:
            return 0
        return max(t.end_ms for t in self.timings) - min(t.start_ms for t in self.timings)

    def to_dict(self) -> dict:
        return {
            "filename": self.filename,
            "direction": self.direction,
            "success": self.success,
            "error": self.error,
            "audio_duration_ms": self.audio_duration_ms,
            "total_latency_ms": self.total_latency_ms(),
            "timings": [
                {
                    "step": t.step,
                    "duration_ms": round(t.duration_ms, 1),
                    "details": t.details
                }
                for t in self.timings
            ],
            "transcripts": self.transcripts,
            "translations": self.translations,
            "gender_detected": self.gender_detected,
            "classifier_decisions": self.classifier_decisions,
            "audio_output_bytes": self.audio_output_bytes
        }


async def test_file(wav_path: str, direction: str, output_dir: str) -> TestResult:
    """Test a single audio file through the pipeline with timing."""

    filename = os.path.basename(wav_path)
    result = TestResult(filename=filename, direction=direction, success=False)

    print(f"\n{'='*60}")
    print(f"Testing: {filename} ({direction})")
    print(f"{'='*60}")

    # Read audio file
    try:
        with wave.open(wav_path, 'rb') as wf:
            audio_data = wf.readframes(wf.getnframes())
            framerate = wf.getframerate()
            n_frames = wf.getnframes()
            result.audio_duration_ms = (n_frames / framerate) * 1000
    except Exception as e:
        result.error = f"Failed to read audio: {e}"
        print(f"ERROR: {result.error}")
        return result

    print(f"Audio duration: {result.audio_duration_ms:.0f}ms")

    # Calculate chunk size
    chunk_bytes = int(SAMPLE_RATE * BYTES_PER_SAMPLE * (CHUNK_MS / 1000))

    # Track timing
    test_start_time = time.time() * 1000  # Convert to ms
    audio_output_chunks = []

    try:
        ws_url = WS_URL.format(direction=direction)
        async with websockets.connect(ws_url) as ws:
            # Send session start
            start_msg = {"type": "session_start", "directions": [direction]}
            await ws.send(json.dumps(start_msg))

            # Wait for session_started
            session_start_time = time.time() * 1000
            while True:
                response = await asyncio.wait_for(ws.recv(), timeout=30.0)
                try:
                    data = json.loads(response)
                    if data.get('type') == 'session_started':
                        session_ready_time = time.time() * 1000
                        result.add_timing(
                            "session_start",
                            session_start_time - test_start_time,
                            session_ready_time - test_start_time,
                            f"session_id={data.get('session_id', 'unknown')[:8]}..."
                        )
                        break
                except json.JSONDecodeError:
                    pass

            # Track when we start sending audio
            audio_send_start = time.time() * 1000
            audio_sent_complete = False
            first_transcript_time = None
            first_translation_time = None

            async def send_audio():
                nonlocal audio_sent_complete
                for i in range(0, len(audio_data), chunk_bytes):
                    chunk = audio_data[i:i + chunk_bytes]
                    await ws.send(chunk)
                    await asyncio.sleep(CHUNK_MS / 1000 * 0.5)  # 2x real-time
                audio_sent_complete = True

            async def receive_responses():
                nonlocal first_transcript_time, first_translation_time
                last_response_time = time.time()

                while True:
                    try:
                        response = await asyncio.wait_for(ws.recv(), timeout=1.0)
                        current_time = time.time() * 1000
                        last_response_time = time.time()

                        try:
                            data = json.loads(response)
                            msg_type = data.get('type', 'unknown')

                            if msg_type == 'gender_detected':
                                result.gender_detected = data.get('gender')
                                result.add_timing(
                                    "gender_detection",
                                    audio_send_start - test_start_time,
                                    current_time - test_start_time,
                                    f"gender={data.get('gender')}"
                                )
                                print(f"  Gender: {data.get('gender')}")

                            elif msg_type == 'transcript_interim':
                                text = data.get('text', '')
                                print(f"  [interim] {text}")

                            elif msg_type == 'transcript_final':
                                text = data.get('text', '')
                                if first_transcript_time is None:
                                    first_transcript_time = current_time
                                    result.add_timing(
                                        "stt_first_final",
                                        audio_send_start - test_start_time,
                                        current_time - test_start_time,
                                        f"text={text[:30]}..."
                                    )
                                result.transcripts.append({
                                    "text": text,
                                    "time_ms": current_time - test_start_time
                                })
                                print(f"  [FINAL] {text}")

                            elif msg_type == 'classifier_decision':
                                result.classifier_decisions.append({
                                    "clause": data.get('clause'),
                                    "decision": data.get('decision'),
                                    "time_ms": current_time - test_start_time
                                })

                            elif msg_type == 'translation':
                                translated = data.get('translated', '')
                                original = data.get('original', '')
                                if first_translation_time is None:
                                    first_translation_time = current_time
                                    result.add_timing(
                                        "translation_first",
                                        audio_send_start - test_start_time,
                                        current_time - test_start_time,
                                        f"translated={translated[:30]}..."
                                    )
                                result.translations.append({
                                    "original": original,
                                    "translated": translated,
                                    "time_ms": current_time - test_start_time
                                })
                                print(f"  [TRANSLATION] {original} -> {translated}")

                            elif msg_type == 'audio_out':
                                pass  # JSON audio_out messages (ignore)

                        except (json.JSONDecodeError, UnicodeDecodeError):
                            # Binary audio data
                            audio_output_chunks.append(response)

                    except asyncio.TimeoutError:
                        # Wait longer (15s) for responses - must be longer than the
                        # pre-session_end wait (8s) to capture pending interims
                        if audio_sent_complete and (time.time() - last_response_time) > 15.0:
                            return
                        continue
                    except websockets.exceptions.ConnectionClosed:
                        return

            # Create tasks for parallel execution
            send_task = asyncio.create_task(send_audio())
            receive_task = asyncio.create_task(receive_responses())

            # Wait for audio sending to complete
            await send_task

            # Give time for final transcripts and translations from Deepgram
            # Need enough time for STT to finalize and translation to complete
            # Longer wait (8s) needed for multi-utterance audio to fully process
            await asyncio.sleep(8.0)

            # Send session_end to trigger flush of pending interims
            try:
                end_msg = {"type": "session_end"}
                await ws.send(json.dumps(end_msg))

                # Wait up to 10 seconds more for translations to complete
                await asyncio.sleep(10.0)
            except websockets.exceptions.ConnectionClosed:
                pass

            # Cancel receive task if still running
            if not receive_task.done():
                receive_task.cancel()
                try:
                    await receive_task
                except asyncio.CancelledError:
                    pass

            # Record audio send timing
            audio_send_end = time.time() * 1000
            result.add_timing(
                "audio_streaming",
                audio_send_start - test_start_time,
                audio_send_end - test_start_time,
                f"sent {len(audio_data)} bytes"
            )

            # Save audio output
            if audio_output_chunks:
                result.audio_output_bytes = sum(len(c) for c in audio_output_chunks)
                output_filename = os.path.splitext(filename)[0] + "_output.mp3"
                output_path = os.path.join(output_dir, output_filename)
                with open(output_path, 'wb') as f:
                    for chunk in audio_output_chunks:
                        f.write(chunk)
                print(f"  Audio output saved: {output_filename} ({result.audio_output_bytes} bytes)")

            result.success = True

    except ConnectionRefusedError:
        result.error = "Could not connect to backend"
        print(f"ERROR: {result.error}")
    except Exception as e:
        result.error = str(e)
        print(f"ERROR: {result.error}")

    return result


async def run_all_tests():
    """Run all edge case tests."""

    results = []

    # Test kr_to_en files
    kr_to_en_dir = os.path.join(EDGE_CASES_DIR, "kr_to_en")
    kr_to_en_output = os.path.join(OUTPUT_DIR, "kr_to_en")
    os.makedirs(kr_to_en_output, exist_ok=True)

    if os.path.exists(kr_to_en_dir):
        for filename in sorted(os.listdir(kr_to_en_dir)):
            if filename.endswith('.wav'):
                wav_path = os.path.join(kr_to_en_dir, filename)
                result = await test_file(wav_path, "ko_to_en", kr_to_en_output)
                results.append(result)

    # Test en_to_kr files
    en_to_kr_dir = os.path.join(EDGE_CASES_DIR, "en_to_kr")
    en_to_kr_output = os.path.join(OUTPUT_DIR, "en_to_kr")
    os.makedirs(en_to_kr_output, exist_ok=True)

    if os.path.exists(en_to_kr_dir):
        for filename in sorted(os.listdir(en_to_kr_dir)):
            if filename.endswith('.wav'):
                wav_path = os.path.join(en_to_kr_dir, filename)
                result = await test_file(wav_path, "en_to_ko", en_to_kr_output)
                results.append(result)

    # Print summary
    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}\n")

    for result in results:
        status = "PASS" if result.success else "FAIL"
        print(f"{result.filename}: {status}")
        if result.success:
            print(f"  Audio duration: {result.audio_duration_ms:.0f}ms")
            print(f"  Transcripts: {len(result.transcripts)}")
            print(f"  Translations: {len(result.translations)}")
            print(f"  Audio output: {result.audio_output_bytes} bytes")
            print(f"  Timings:")
            for t in result.timings:
                print(f"    - {t.step}: {t.duration_ms:.0f}ms ({t.details})")
        else:
            print(f"  Error: {result.error}")
        print()

    # Save detailed results to JSON
    results_path = os.path.join(OUTPUT_DIR, "results.json")
    with open(results_path, 'w') as f:
        json.dump([r.to_dict() for r in results], f, indent=2, ensure_ascii=False)
    print(f"Detailed results saved to: {results_path}")

    return results


if __name__ == "__main__":
    asyncio.run(run_all_tests())
