#!/usr/bin/env python3
"""Test script for Speech-to-Text using Deepgram prerecorded API."""

import os
import sys

# Add src to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from deepgram import DeepgramClient
from src.config import get_settings


def transcribe_file(client: DeepgramClient, filepath: str, language: str) -> str:
    """
    Transcribe an audio file using Deepgram prerecorded API.

    Args:
        client: Deepgram client
        filepath: Path to audio file
        language: Language code ("en" or "ko")

    Returns:
        Transcribed text
    """
    with open(filepath, "rb") as f:
        audio_data = f.read()

    response = client.listen.v1.media.transcribe_file(
        request=audio_data,
        model="nova-2",
        language=language,
        smart_format=True,
        punctuate=True,
    )

    # Extract transcript from response
    transcript = ""
    if response.results and response.results.channels:
        channel = response.results.channels[0]
        if channel.alternatives:
            transcript = channel.alternatives[0].transcript

    return transcript


def main():
    """Test STT with English and Korean audio files."""

    print("=" * 60)
    print("Speech-to-Text (Deepgram) Test")
    print("=" * 60)

    settings = get_settings()
    client = DeepgramClient(api_key=settings.deepgram_api_key)

    test_files = [
        ("audio/en_female.mp3", "en", "Hello, nice to meet you."),
        ("audio/ko_female.mp3", "ko", "안녕하세요, 만나서 반갑습니다."),
    ]

    results = []

    for filepath, language, expected in test_files:
        print(f"\n[Test] {filepath}")
        print("-" * 40)

        if not os.path.exists(filepath):
            print(f"  ERROR: File not found: {filepath}")
            continue

        file_size = os.path.getsize(filepath)
        print(f"  File size: {file_size:,} bytes")
        print(f"  Language: {language}")
        print(f"  Expected: {expected}")

        try:
            transcript = transcribe_file(client, filepath, language)
            print(f"  Result:   {transcript}")

            # Check if transcript matches expected (loosely)
            expected_clean = expected.lower().replace(",", "").replace(".", "").replace(" ", "")
            result_clean = transcript.lower().replace(",", "").replace(".", "").replace(" ", "")
            match = expected_clean in result_clean or result_clean in expected_clean
            status = "PASS" if match else "PARTIAL"
            print(f"  Status:   {status}")

            results.append((filepath, expected, transcript, status))

        except Exception as e:
            print(f"  ERROR: {e}")
            results.append((filepath, expected, str(e), "FAIL"))

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)

    for filepath, expected, result, status in results:
        lang = "EN" if "en_" in filepath else "KO"
        print(f"\n  [{status}] {lang}: {os.path.basename(filepath)}")
        print(f"       Expected: {expected}")
        print(f"       Got:      {result}")

    print("\nDone!")


if __name__ == "__main__":
    main()
