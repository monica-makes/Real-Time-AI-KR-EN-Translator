#!/usr/bin/env python3
"""Test backend VAD by sending audio via WebSocket."""

import asyncio
import json
import os
import time
import wave
import websockets

# Get directory of this script for relative paths
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
AUDIO_FILE = os.path.join(SCRIPT_DIR, "audio/VAD-test_korean_male.wav")
WS_URL = "ws://localhost:8000/ws/translate?direction=ko_to_en"
CHUNK_MS = 100  # Send 100ms chunks
SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2  # 16-bit audio


async def test_vad():
    """Send audio to backend and observe responses."""
    print(f"\n{'=' * 60}")
    print("BACKEND VAD TEST")
    print(f"{'=' * 60}")
    print(f"Audio file: {AUDIO_FILE}")
    print(f"WebSocket URL: {WS_URL}")
    print()

    # Read audio file
    with wave.open(AUDIO_FILE, 'rb') as wf:
        channels = wf.getnchannels()
        sample_width = wf.getsampwidth()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()
        audio_data = wf.readframes(n_frames)
        duration = n_frames / framerate

    print(f"Audio info:")
    print(f"  Channels: {channels}")
    print(f"  Sample width: {sample_width} bytes")
    print(f"  Sample rate: {framerate} Hz")
    print(f"  Duration: {duration:.2f} seconds")
    print(f"  Total bytes: {len(audio_data)}")
    print()

    # Calculate chunk size
    chunk_bytes = int(SAMPLE_RATE * BYTES_PER_SAMPLE * (CHUNK_MS / 1000))
    total_chunks = len(audio_data) // chunk_bytes
    print(f"Chunk size: {chunk_bytes} bytes ({CHUNK_MS}ms)")
    print(f"Total chunks: {total_chunks}")
    print()

    try:
        print("Connecting to backend...")
        async with websockets.connect(WS_URL) as ws:
            print("Connected!")
            print()

            # Send session start message
            start_msg = {
                "type": "session_start",
                "directions": ["ko_to_en"]
            }
            await ws.send(json.dumps(start_msg))
            print(f"Sent: {json.dumps(start_msg)}")
            print()

            # Wait for session_started response before sending audio
            print("Waiting for session_started...")
            session_ready = False
            while not session_ready:
                response = await asyncio.wait_for(ws.recv(), timeout=30.0)
                try:
                    data = json.loads(response)
                    if data.get('type') == 'session_started':
                        print(f"SESSION STARTED: {data}")
                        session_ready = True
                except json.JSONDecodeError:
                    pass
            print()

            # Track timing
            last_response_time = time.time()
            responses_received = []
            audio_sent = False
            audio_output_chunks = []  # Collect audio output

            async def send_audio():
                """Send audio chunks."""
                nonlocal audio_sent
                print("-" * 60)
                print("Sending audio chunks...")

                for i in range(0, len(audio_data), chunk_bytes):
                    chunk = audio_data[i:i + chunk_bytes]
                    await ws.send(chunk)

                    # Print progress every 10 chunks
                    chunk_num = i // chunk_bytes
                    if chunk_num % 10 == 0:
                        elapsed_ms = chunk_num * CHUNK_MS
                        print(f"  Sent chunk {chunk_num}/{total_chunks} ({elapsed_ms}ms of audio)")

                    # Simulate real-time streaming
                    await asyncio.sleep(CHUNK_MS / 1000 * 0.5)  # Send at 2x real-time

                print(f"\nAll audio sent! ({len(audio_data)} bytes)")
                print("-" * 60)
                audio_sent = True

            async def receive_responses():
                """Receive and print responses."""
                nonlocal last_response_time

                while True:
                    try:
                        # Wait for response with timeout
                        response = await asyncio.wait_for(ws.recv(), timeout=1.0)
                        last_response_time = time.time()

                        # Try to parse as JSON
                        try:
                            data = json.loads(response)
                            responses_received.append(data)

                            msg_type = data.get('type', 'unknown')

                            if msg_type == 'transcript_interim':
                                text = data.get('text', '')
                                print(f"INTERIM: \"{text}\"")
                            elif msg_type == 'transcript_final':
                                text = data.get('text', '')
                                print(f"FINAL: \"{text}\"")
                            elif msg_type == 'utterance_end':
                                print(">>> UTTERANCE_END <<<")
                            elif msg_type == 'translation':
                                translated = data.get('translated', '')
                                print(f"TRANSLATION: \"{translated}\"")
                            elif msg_type == 'audio_out':
                                audio_len = len(data.get('data', ''))
                                print(f"AUDIO_OUT: {audio_len} bytes")
                            elif msg_type == 'session_started':
                                print(f"SESSION STARTED: {data}")
                            elif msg_type == 'error':
                                print(f"ERROR: {data.get('message', data)}")
                            else:
                                print(f"RECEIVED [{msg_type}]: {json.dumps(data)[:100]}")

                        except (json.JSONDecodeError, UnicodeDecodeError):
                            # Binary data (audio)
                            audio_output_chunks.append(response)
                            print(f"AUDIO_OUT (binary): {len(response)} bytes")

                    except asyncio.TimeoutError:
                        # Check if we should exit (5 seconds of no response after audio sent)
                        if audio_sent and (time.time() - last_response_time) > 5.0:
                            print("\n5 seconds with no response - test complete")
                            return
                        continue
                    except websockets.exceptions.ConnectionClosed:
                        print("Connection closed by server")
                        return

            # Run send and receive concurrently
            await asyncio.gather(
                send_audio(),
                receive_responses(),
            )

            # Save audio output if any
            if audio_output_chunks:
                output_file = os.path.join(SCRIPT_DIR, "audio/output_english.mp3")
                with open(output_file, 'wb') as f:
                    for chunk in audio_output_chunks:
                        f.write(chunk)
                print(f"\nAudio output saved to: {output_file}")
                print(f"Total audio size: {sum(len(c) for c in audio_output_chunks)} bytes")

    except ConnectionRefusedError:
        print("ERROR: Could not connect to backend. Is the server running?")
        print("Start it with: python -m uvicorn src.main:app --reload")
        return
    except Exception as e:
        print(f"ERROR: {e}")
        raise

    # Summary
    print()
    print("=" * 60)
    print("SUMMARY")
    print("=" * 60)

    type_counts = {}
    for r in responses_received:
        t = r.get('type', 'unknown')
        type_counts[t] = type_counts.get(t, 0) + 1

    for msg_type, count in sorted(type_counts.items()):
        print(f"  {msg_type}: {count}")

    print()

    # Verdict
    has_utterance_end = any(r.get('type') == 'utterance_end' for r in responses_received)
    has_final = any(r.get('type') == 'transcript_final' for r in responses_received)

    if has_utterance_end and has_final:
        print("VAD appears to be WORKING correctly!")
        print("  - Received final transcripts")
        print("  - Received utterance_end event")
    elif has_final and not has_utterance_end:
        print("PARTIAL: Got transcripts but no utterance_end event")
        print("  VAD may not be fully configured")
    else:
        print("WARNING: VAD may not be working correctly")
        print("  Check backend logs for errors")


if __name__ == "__main__":
    asyncio.run(test_vad())
