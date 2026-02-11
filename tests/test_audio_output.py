#!/usr/bin/env python3
"""Test script to generate audio samples using ElevenLabs TTS with all 4 voices."""

import asyncio
import os
import sys

# Add src to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src.services.tts import TTSService
from src.services.voice_detection import VOICES


async def main():
    """Generate test audio files for all voice combinations."""

    # Create audio directory
    output_dir = os.path.join(os.path.dirname(__file__), "audio")
    os.makedirs(output_dir, exist_ok=True)
    print(f"Output directory: {output_dir}")

    # Initialize TTS service
    tts = TTSService()
    await tts.start()

    # Test cases: (filename, text, language, gender)
    # Note: Adding period at end ensures ElevenLabs completes the sentence
    test_cases = [
        ("en_female.mp3", "Hello, nice to meet you.", "en", "female"),
        ("en_male.mp3", "Hello, nice to meet you.", "en", "male"),
        ("ko_female.mp3", "안녕하세요, 만나서 반갑습니다.", "ko", "female"),
        ("ko_male.mp3", "안녕하세요, 만나서 반갑습니다.", "ko", "male"),
    ]

    print("\nGenerating audio samples...")
    print("-" * 60)

    for filename, text, language, gender in test_cases:
        filepath = os.path.join(output_dir, filename)
        voice_id = VOICES[(language, gender)]

        print(f"\nGenerating: {filename}")
        print(f"  Text: {text}")
        print(f"  Language: {language}, Gender: {gender}")
        print(f"  Voice ID: {voice_id}")

        try:
            # Set gender and synthesize
            tts.set_gender(gender)
            audio_data = await tts.synthesize(text, language=language, gender_override=gender)

            if audio_data:
                with open(filepath, "wb") as f:
                    f.write(audio_data)
                    f.flush()  # Ensure all data is written
                file_size = os.path.getsize(filepath)
                # Estimate duration: MP3 at 128kbps = 16KB per second
                est_duration = file_size / (128 * 1024 / 8)
                print(f"  Saved: {filepath}")
                print(f"  Size: {file_size:,} bytes, Est. duration: {est_duration:.2f}s")
            else:
                print(f"  ERROR: No audio data returned")

        except Exception as e:
            print(f"  ERROR: {e}")

    await tts.stop()

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)

    for filename, text, language, gender in test_cases:
        filepath = os.path.join(output_dir, filename)
        if os.path.exists(filepath):
            size = os.path.getsize(filepath)
            print(f"  [OK] {filename} ({size:,} bytes)")
        else:
            print(f"  [MISSING] {filename}")

    print("\nDone!")


if __name__ == "__main__":
    asyncio.run(main())
