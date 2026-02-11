#!/usr/bin/env python3
"""Test script for gender detection from audio files."""

import os
import sys

# Add src to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
import librosa

from src.services.voice_detection import detect_gender, FEMALE_PITCH_THRESHOLD


def load_audio_as_pcm(filepath: str, target_sr: int = 16000) -> bytes:
    """
    Load an audio file and convert to PCM 16-bit bytes.

    Args:
        filepath: Path to audio file (MP3, WAV, etc.)
        target_sr: Target sample rate

    Returns:
        PCM 16-bit audio bytes
    """
    # Load audio with librosa (automatically converts to mono float32)
    audio_float, sr = librosa.load(filepath, sr=target_sr, mono=True)

    # Convert float32 [-1, 1] to int16 [-32768, 32767]
    audio_int16 = (audio_float * 32767).astype(np.int16)

    return audio_int16.tobytes()


def get_pitch_info(filepath: str, target_sr: int = 16000) -> tuple[float, float, float]:
    """
    Get pitch statistics from audio file for debugging.

    Returns:
        Tuple of (min_pitch, median_pitch, max_pitch)
    """
    audio_float, sr = librosa.load(filepath, sr=target_sr, mono=True)

    f0, voiced_flag, voiced_probs = librosa.pyin(
        audio_float,
        fmin=50,
        fmax=400,
        sr=target_sr,
        frame_length=2048,
    )

    voiced_pitches = f0[~np.isnan(f0)]

    if len(voiced_pitches) == 0:
        return (0.0, 0.0, 0.0)

    return (
        float(np.min(voiced_pitches)),
        float(np.median(voiced_pitches)),
        float(np.max(voiced_pitches)),
    )


def main():
    """Test gender detection with all test audio files."""

    print("=" * 70)
    print("Gender Detection Test")
    print(f"Threshold: >= {FEMALE_PITCH_THRESHOLD} Hz = female, < {FEMALE_PITCH_THRESHOLD} Hz = male")
    print("=" * 70)

    test_files = [
        ("audio/en_female.mp3", "female"),
        ("audio/en_male.mp3", "male"),
        ("audio/kr_female.mp3", "female"),
        ("audio/kr_male.mp3", "male"),
    ]

    results = []

    for filepath, expected in test_files:
        print(f"\n[Test] {filepath}")
        print("-" * 50)

        if not os.path.exists(filepath):
            print(f"  ERROR: File not found")
            results.append((filepath, expected, "N/A", "SKIP", 0.0))
            continue

        try:
            # Get pitch info for debugging
            min_pitch, median_pitch, max_pitch = get_pitch_info(filepath)
            print(f"  Pitch: min={min_pitch:.1f} Hz, median={median_pitch:.1f} Hz, max={max_pitch:.1f} Hz")

            # Load and convert audio
            audio_bytes = load_audio_as_pcm(filepath)
            print(f"  Audio: {len(audio_bytes):,} bytes PCM16")

            # Detect gender
            detected = detect_gender(audio_bytes, sample_rate=16000)
            status = "PASS" if detected == expected else "FAIL"

            print(f"  Expected: {expected}")
            print(f"  Detected: {detected}")
            print(f"  Status:   {status}")

            results.append((filepath, expected, detected, status, median_pitch))

        except Exception as e:
            print(f"  ERROR: {e}")
            results.append((filepath, expected, "ERROR", "FAIL", 0.0))

    # Summary table
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print(f"{'File':<25} {'Expected':<10} {'Detected':<10} {'Pitch (Hz)':<12} {'Status':<8}")
    print("-" * 70)

    pass_count = 0
    for filepath, expected, detected, status, pitch in results:
        filename = os.path.basename(filepath)
        pitch_str = f"{pitch:.1f}" if pitch > 0 else "N/A"
        print(f"{filename:<25} {expected:<10} {detected:<10} {pitch_str:<12} {status:<8}")
        if status == "PASS":
            pass_count += 1

    print("-" * 70)
    print(f"Results: {pass_count}/{len(results)} passed")
    print("\nDone!")


if __name__ == "__main__":
    main()
