#!/usr/bin/env python3
"""Test script for the Claude translation service."""

import asyncio
import os
import sys

# Add src to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src.services.translator import TranslatorService
from src.models import TranslationDirection
from src.session.context import SharedTranslationContext


async def main():
    """Test translation in both directions."""

    print("=" * 60)
    print("Translation Service Test")
    print("=" * 60)

    # Initialize translator and shared context
    translator = TranslatorService()
    context = SharedTranslationContext()

    # Test 1: English → Korean
    print("\n[Test 1] English → Korean")
    print("-" * 40)
    en_text = "Hello, how are you today?"
    print(f"Input (EN):  {en_text}")

    ko_result = await translator.translate(
        text=en_text,
        direction=TranslationDirection.EN_TO_KO,
        context=context,
        honorific_mode=False,
    )
    print(f"Output (KO): {ko_result}")

    # Test 2: Korean → English
    print("\n[Test 2] Korean → English")
    print("-" * 40)
    ko_text = "오늘 날씨가 좋네요"
    print(f"Input (KO):  {ko_text}")

    en_result = await translator.translate(
        text=ko_text,
        direction=TranslationDirection.KO_TO_EN,
        context=context,
        honorific_mode=False,
    )
    print(f"Output (EN): {en_result}")

    # Test 3: English → Korean (Honorific mode)
    print("\n[Test 3] English → Korean (Honorific)")
    print("-" * 40)
    en_text2 = "Did you eat lunch?"
    print(f"Input (EN):  {en_text2}")

    ko_honorific = await translator.translate(
        text=en_text2,
        direction=TranslationDirection.EN_TO_KO,
        context=context,
        honorific_mode=True,
    )
    print(f"Output (KO): {ko_honorific}")

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  EN→KO: \"{en_text}\"")
    print(f"      →  \"{ko_result}\"")
    print()
    print(f"  KO→EN: \"{ko_text}\"")
    print(f"      →  \"{en_result}\"")
    print()
    print(f"  EN→KO (honorific): \"{en_text2}\"")
    print(f"      →  \"{ko_honorific}\"")
    print("\nDone!")


if __name__ == "__main__":
    asyncio.run(main())
