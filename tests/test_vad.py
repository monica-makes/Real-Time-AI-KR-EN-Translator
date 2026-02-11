#!/usr/bin/env python3
"""Test script to verify Deepgram VAD (Voice Activity Detection) configuration."""

import os
import sys
import time
import threading
from queue import Queue, Empty

# Add src to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from deepgram import DeepgramClient
from src.config import get_settings


def test_vad_with_file(filepath: str, language: str = "en"):
    """
    Test VAD by streaming an audio file to Deepgram.

    This simulates what the backend does - streaming audio and observing
    what events Deepgram returns.
    """
    print(f"\n{'=' * 60}")
    print(f"Testing VAD with: {filepath}")
    print(f"Language: {language}")
    print(f"{'=' * 60}\n")

    if not os.path.exists(filepath):
        print(f"ERROR: File not found: {filepath}")
        return False

    settings = get_settings()
    client = DeepgramClient(api_key=settings.deepgram_api_key)

    # Counters for event types
    event_counts = {
        "SpeechStarted": 0,
        "UtteranceEnd": 0,
        "Transcript (interim)": 0,
        "Transcript (final)": 0,
    }

    # Connect with VAD options (using same API as stt.py)
    print("Connecting to Deepgram with VAD options:")
    print("  - endpointing: 300ms")
    print("  - utterance_end_ms: 1000ms")
    print("  - vad_events: true")
    print("  - interim_results: true")
    print()

    # Read and convert audio file first
    import librosa
    import numpy as np

    print(f"Loading audio file...")
    audio_float, sr = librosa.load(filepath, sr=16000, mono=True)
    audio_int16 = (audio_float * 32768.0).astype(np.int16)
    audio_bytes = audio_int16.tobytes()

    duration = len(audio_float) / 16000
    print(f"  Duration: {duration:.2f}s")
    print(f"  Samples: {len(audio_float)}")
    print(f"  Bytes: {len(audio_bytes)}")
    print()

    chunk_size = 3200  # 100ms at 16kHz, 16-bit = 3200 bytes

    print("Streaming audio to Deepgram...")
    print("-" * 60)

    # Use context manager for connection
    with client.listen.v1.connect(
        model="nova-2",
        language=language,
        encoding="linear16",
        sample_rate="16000",
        channels="1",
        punctuate="true",
        interim_results="true",
        # VAD (Voice Activity Detection) settings
        endpointing="300",
        utterance_end_ms="1000",
        vad_events="true",
        smart_format="true",
    ) as connection:

        chunks_sent = 0

        # Start a thread to send audio while we read responses
        def send_audio():
            nonlocal chunks_sent
            # Send all audio chunks
            for i in range(0, len(audio_bytes), chunk_size):
                chunk = audio_bytes[i:i + chunk_size]
                connection.send_media(chunk)
                chunks_sent += 1
                time.sleep(0.05)  # Small delay to simulate real-time streaming

            print(f"\nSent {chunks_sent} chunks ({len(audio_bytes)} bytes total)")

            # Add some silence at the end to trigger utterance end
            print("Sending 2 seconds of silence to trigger utterance end...")
            silence = bytes(chunk_size)
            for _ in range(20):  # 2 seconds
                connection.send_media(silence)
                time.sleep(0.05)

        # Start sending audio in background
        send_thread = threading.Thread(target=send_audio)
        send_thread.start()

        # Read responses (with timeout)
        start_time = time.time()
        timeout_seconds = 15  # Total time to wait for responses

        try:
            for response in connection:
                # Check timeout
                if time.time() - start_time > timeout_seconds:
                    print("\nTimeout reached, stopping...")
                    break

                # Get response type for VAD event handling
                response_type = getattr(response, 'type', None)

                # Handle VAD events
                if response_type == 'SpeechStarted':
                    event_counts["SpeechStarted"] += 1
                    print(f"  VAD EVENT: SpeechStarted")
                    continue

                if response_type == 'UtteranceEnd':
                    event_counts["UtteranceEnd"] += 1
                    print(f"  VAD EVENT: UtteranceEnd")
                    continue

                # Parse transcription results
                if hasattr(response, 'channel'):
                    channel = response.channel
                    if hasattr(channel, 'alternatives') and channel.alternatives:
                        alt = channel.alternatives[0]
                        transcript = getattr(alt, 'transcript', '')

                        if transcript:
                            is_final = getattr(response, 'is_final', False)
                            if is_final:
                                event_counts["Transcript (final)"] += 1
                                print(f"  FINAL: \"{transcript}\"")
                            else:
                                event_counts["Transcript (interim)"] += 1
                                print(f"  interim: \"{transcript}\"")

        except Exception as e:
            print(f"Error reading responses: {e}")

        # Wait for send thread to finish
        send_thread.join()

    # Summary
    print()
    print("=" * 60)
    print("SUMMARY")
    print("=" * 60)
    for event_type, count in event_counts.items():
        print(f"  {event_type}: {count}")

    print()
    success = True
    if event_counts["UtteranceEnd"] > 0:
        print("SUCCESS: VAD is working - UtteranceEnd event received")
    else:
        print("WARNING: VAD may not be working - no UtteranceEnd event")
        success = False

    if event_counts["Transcript (final)"] > 0:
        print("SUCCESS: Transcription working - final transcript received")
    else:
        print("WARNING: No final transcript received")
        success = False

    return success


def test_vad_with_silence():
    """Test that pure silence doesn't generate transcriptions."""
    print(f"\n{'=' * 60}")
    print("Testing VAD with pure silence (3 seconds)")
    print(f"{'=' * 60}\n")

    settings = get_settings()
    client = DeepgramClient(api_key=settings.deepgram_api_key)

    transcript_count = 0

    chunk_size = 3200  # 100ms
    silence_chunks = 30  # 3 seconds

    with client.listen.v1.connect(
        model="nova-2",
        language="en",
        encoding="linear16",
        sample_rate="16000",
        channels="1",
        punctuate="true",
        interim_results="true",
        endpointing="300",
        utterance_end_ms="1000",
        vad_events="true",
        smart_format="true",
    ) as connection:

        # Send silence in a thread
        def send_silence():
            print(f"Sending {silence_chunks} chunks of silence...")
            for _ in range(silence_chunks):
                connection.send_media(bytes(chunk_size))
                time.sleep(0.05)

        send_thread = threading.Thread(target=send_silence)
        send_thread.start()

        # Read responses with timeout
        start_time = time.time()
        timeout_seconds = 8

        try:
            for response in connection:
                if time.time() - start_time > timeout_seconds:
                    break

                if hasattr(response, 'channel'):
                    channel = response.channel
                    if hasattr(channel, 'alternatives') and channel.alternatives:
                        alt = channel.alternatives[0]
                        transcript = getattr(alt, 'transcript', '')
                        if transcript:
                            transcript_count += 1
                            print(f"  Unexpected transcript: \"{transcript}\"")

        except Exception as e:
            print(f"Error: {e}")

        send_thread.join()

    print()
    if transcript_count == 0:
        print("SUCCESS: VAD correctly filtered silence - no transcripts generated")
        return True
    else:
        print(f"WARNING: VAD issue - {transcript_count} transcripts from silence")
        return False


def main():
    """Run VAD tests."""
    print("\n" + "#" * 60)
    print("#" + " DEEPGRAM VAD CONFIGURATION TEST ".center(58) + "#")
    print("#" * 60)

    # Test 1: With an actual audio file
    test_files = [
        ("audio/en_female.mp3", "en"),
        ("audio/ko_female.mp3", "ko"),
    ]

    for filepath, language in test_files:
        if os.path.exists(filepath):
            test_vad_with_file(filepath, language)
            break
    else:
        print("\nNo test audio files found. Skipping file test.")
        print("Expected files: audio/en_female.mp3 or audio/ko_female.mp3")

    # Test 2: With silence
    test_vad_with_silence()

    print("\n" + "=" * 60)
    print("VAD TESTS COMPLETE")
    print("=" * 60)


if __name__ == "__main__":
    main()
