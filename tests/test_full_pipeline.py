#!/usr/bin/env python3
"""Test script for the complete translation pipeline."""

import asyncio
import os
import sys
from dataclasses import dataclass
from typing import Optional

# Add src to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import librosa
import numpy as np

from src.config import get_settings
from src.models import TranslationDirection
from src.services.translator import TranslatorService
from src.services.tts import TTSService
from src.services.voice_detection import (
    detect_gender,
    detect_language,
    get_voice_id,
    VOICES,
)
from src.session.context import SharedTranslationContext
from deepgram import DeepgramClient


@dataclass
class PipelineResult:
    """Result of a pipeline test."""
    test_name: str
    input_file: str
    output_file: str
    detected_gender: str
    expected_gender: Optional[str]
    transcription: str
    detected_lang: str
    direction: str
    translated_text: str
    voice_id: str
    output_lang: str
    output_size: int
    success: bool


def load_audio_as_pcm16(filepath: str, sample_rate: int = 16000) -> bytes:
    """Load audio file and convert to PCM16 bytes."""
    audio_float, sr = librosa.load(filepath, sr=sample_rate, mono=True)
    audio_int16 = (audio_float * 32768.0).astype(np.int16)
    return audio_int16.tobytes()


def transcribe_audio(client: DeepgramClient, filepath: str, language: str) -> str:
    """Transcribe audio file using Deepgram."""
    with open(filepath, "rb") as f:
        audio_data = f.read()

    response = client.listen.v1.media.transcribe_file(
        request=audio_data,
        model="nova-2",
        language=language,
        smart_format=True,
        punctuate=True,
    )

    transcript = ""
    if response.results and response.results.channels:
        channel = response.results.channels[0]
        if channel.alternatives:
            transcript = channel.alternatives[0].transcript

    return transcript


async def run_pipeline_test(
    test_name: str,
    input_file: str,
    output_file: str,
    dg_client: DeepgramClient,
    translator: TranslatorService,
    tts: TTSService,
    stt_language_hint: str = "en",
    expected_gender: Optional[str] = None,
) -> PipelineResult:
    """Run a complete pipeline test."""

    print(f"\n{'=' * 70}")
    print(f"  {test_name}")
    print(f"{'=' * 70}")
    print(f"Input:  {input_file}")
    print(f"Output: {output_file}")
    print("-" * 70)

    # Check input file exists
    if not os.path.exists(input_file):
        print(f"ERROR: Input file not found: {input_file}")
        return PipelineResult(
            test_name=test_name,
            input_file=input_file,
            output_file=output_file,
            detected_gender="N/A",
            expected_gender=expected_gender,
            transcription="N/A",
            detected_lang="N/A",
            direction="N/A",
            translated_text="N/A",
            voice_id="N/A",
            output_lang="N/A",
            output_size=0,
            success=False,
        )

    # Step 1: Load audio
    print("\n[Step 1] Loading audio...")
    audio_bytes = load_audio_as_pcm16(input_file)
    print(f"  Loaded: {len(audio_bytes):,} bytes PCM16")

    # Step 2: Gender detection
    print("\n[Step 2] Gender detection...")
    detected_gender = detect_gender(audio_bytes, sample_rate=16000)
    gender_status = ""
    if expected_gender:
        gender_status = " ✓" if detected_gender == expected_gender else " ✗ (expected: {})".format(expected_gender)
    print(f"  Detected gender: {detected_gender}{gender_status}")

    # Step 3: Speech-to-Text (Deepgram)
    print("\n[Step 3] Speech-to-Text (Deepgram)...")
    transcript = transcribe_audio(dg_client, input_file, stt_language_hint)
    if not transcript and stt_language_hint == "en":
        transcript = transcribe_audio(dg_client, input_file, "ko")
    elif not transcript and stt_language_hint == "ko":
        transcript = transcribe_audio(dg_client, input_file, "en")
    print(f"  Transcription: \"{transcript}\"")

    if not transcript:
        print("  ERROR: No transcription result")
        return PipelineResult(
            test_name=test_name,
            input_file=input_file,
            output_file=output_file,
            detected_gender=detected_gender,
            expected_gender=expected_gender,
            transcription="(no transcription)",
            detected_lang="N/A",
            direction="N/A",
            translated_text="N/A",
            voice_id="N/A",
            output_lang="N/A",
            output_size=0,
            success=False,
        )

    # Step 4: Language detection
    print("\n[Step 4] Language detection...")
    detected_lang = detect_language(transcript)
    print(f"  Detected language: {detected_lang}")

    # Step 5: Translation
    print("\n[Step 5] Translation...")
    if detected_lang == "en":
        direction = TranslationDirection.EN_TO_KO
        output_lang = "ko"
        print(f"  Direction: English → Korean")
    else:
        direction = TranslationDirection.KO_TO_EN
        output_lang = "en"
        print(f"  Direction: Korean → English")

    context = SharedTranslationContext()
    translated_text = await translator.translate(
        text=transcript,
        direction=direction,
        context=context,
        honorific_mode=False,
    )
    print(f"  Input:  \"{transcript}\"")
    print(f"  Output: \"{translated_text}\"")

    # Step 6: Voice selection
    print("\n[Step 6] Voice selection...")
    voice_id = get_voice_id(output_lang, detected_gender)
    print(f"  Output language: {output_lang}")
    print(f"  Detected gender: {detected_gender}")
    print(f"  Selected voice ID: {voice_id}")

    # Step 7: Text-to-Speech (ElevenLabs)
    print("\n[Step 7] Text-to-Speech (ElevenLabs)...")
    tts.set_gender(detected_gender)
    audio_output = await tts.synthesize(
        text=translated_text,
        language=output_lang,
        gender_override=detected_gender,
    )

    if not audio_output:
        print("  ERROR: No audio generated")
        return PipelineResult(
            test_name=test_name,
            input_file=input_file,
            output_file=output_file,
            detected_gender=detected_gender,
            expected_gender=expected_gender,
            transcription=transcript,
            detected_lang=detected_lang,
            direction=direction.value,
            translated_text=translated_text,
            voice_id=voice_id,
            output_lang=output_lang,
            output_size=0,
            success=False,
        )

    print(f"  Generated: {len(audio_output):,} bytes")

    # Step 8: Save output
    print("\n[Step 8] Saving output...")
    with open(output_file, "wb") as f:
        f.write(audio_output)

    file_size = os.path.getsize(output_file)
    est_duration = file_size / (128 * 1024 / 8)
    print(f"  Saved: {output_file}")
    print(f"  Size: {file_size:,} bytes")
    print(f"  Est. duration: {est_duration:.2f}s")

    return PipelineResult(
        test_name=test_name,
        input_file=input_file,
        output_file=output_file,
        detected_gender=detected_gender,
        expected_gender=expected_gender,
        transcription=transcript,
        detected_lang=detected_lang,
        direction=direction.value,
        translated_text=translated_text,
        voice_id=voice_id,
        output_lang=output_lang,
        output_size=file_size,
        success=True,
    )


def print_results_table(results: list[PipelineResult]):
    """Print a summary table of all test results."""
    print("\n" + "=" * 90)
    print("RESULTS SUMMARY")
    print("=" * 90)

    for r in results:
        status = "PASS" if r.success else "FAIL"
        gender_match = ""
        if r.expected_gender:
            gender_match = "✓" if r.detected_gender == r.expected_gender else "✗"

        print(f"\n[{status}] {r.test_name}")
        print(f"  Input:        {r.input_file}")
        print(f"  Gender:       {r.detected_gender} {gender_match}")
        print(f"  STT:          \"{r.transcription}\"")
        print(f"  Language:     {r.detected_lang}")
        print(f"  Direction:    {r.direction}")
        print(f"  Translation:  \"{r.translated_text}\"")
        print(f"  Voice:        {r.voice_id} ({r.output_lang}, {r.detected_gender})")
        print(f"  Output:       {r.output_file} ({r.output_size:,} bytes)")

    # Summary line
    passed = sum(1 for r in results if r.success)
    total = len(results)
    print("\n" + "-" * 90)
    print(f"Total: {passed}/{total} tests passed")
    print("=" * 90)


async def main():
    """Run all pipeline tests."""

    print("\n" + "#" * 70)
    print("#" + " " * 68 + "#")
    print("#" + "  FULL PIPELINE TESTS".center(68) + "#")
    print("#" + " " * 68 + "#")
    print("#" * 70)

    # Initialize shared services
    settings = get_settings()
    dg_client = DeepgramClient(api_key=settings.deepgram_api_key)
    translator = TranslatorService()
    tts = TTSService()
    await tts.start()

    results: list[PipelineResult] = []

    # Test 1: English Female → Korean Female
    result1 = await run_pipeline_test(
        test_name="Test 1: English Female → Korean (EN→KR)",
        input_file="audio/real_female.m4a",
        output_file="audio/pipeline_output.mp3",
        dg_client=dg_client,
        translator=translator,
        tts=tts,
        stt_language_hint="en",
        expected_gender="female",
    )
    results.append(result1)

    # Test 2: Korean Female → English Female (KR→EN)
    # Use kr_female.mp3 (TTS-generated Korean audio)
    result2 = await run_pipeline_test(
        test_name="Test 2: Korean Female → English (KR→EN)",
        input_file="audio/kr_female.mp3",
        output_file="audio/pipeline_output_kr_to_en.mp3",
        dg_client=dg_client,
        translator=translator,
        tts=tts,
        stt_language_hint="ko",
        expected_gender="female",
    )
    results.append(result2)

    # Test 3: Male Voice Pipeline
    result3 = await run_pipeline_test(
        test_name="Test 3: Male Voice Pipeline",
        input_file="audio/real_male.m4a",
        output_file="audio/pipeline_output_male.mp3",
        dg_client=dg_client,
        translator=translator,
        tts=tts,
        stt_language_hint="en",
        expected_gender="male",
    )
    results.append(result3)

    await tts.stop()

    # Print results table
    print_results_table(results)

    print("\nDone! Play the output files to hear the results.")


if __name__ == "__main__":
    asyncio.run(main())
