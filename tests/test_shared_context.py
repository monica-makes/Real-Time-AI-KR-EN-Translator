"""Tests for shared translation context."""

import pytest
from src.session.context import SharedTranslationContext
from src.models import TranslationDirection


class TestSharedTranslationContext:
    """Tests for SharedTranslationContext."""

    @pytest.fixture
    def context(self):
        """Create a context for testing."""
        return SharedTranslationContext(max_exchanges=5)

    def test_add_exchange(self, context):
        """Should add exchange to context."""
        context.add_exchange(
            direction=TranslationDirection.KO_TO_EN,
            source_text="안녕하세요",
            translated_text="Hello",
        )
        assert len(context) == 1

    def test_max_exchanges(self, context):
        """Should respect max exchanges limit."""
        for i in range(10):
            context.add_exchange(
                direction=TranslationDirection.KO_TO_EN,
                source_text=f"Korean {i}",
                translated_text=f"English {i}",
            )

        assert len(context) == 5

    def test_get_context_for_kr_to_en(self, context):
        """Should format context for KO->EN direction."""
        context.add_exchange(
            direction=TranslationDirection.KO_TO_EN,
            source_text="안녕하세요",
            translated_text="Hello",
        )

        prompt = context.get_context_for_prompt(TranslationDirection.KO_TO_EN)
        assert "Korean: 안녕하세요" in prompt
        assert "English: Hello" in prompt

    def test_get_context_for_en_to_kr(self, context):
        """Should format context for EN->KO direction."""
        context.add_exchange(
            direction=TranslationDirection.EN_TO_KO,
            source_text="Hello",
            translated_text="안녕하세요",
        )

        prompt = context.get_context_for_prompt(TranslationDirection.EN_TO_KO)
        assert "English: Hello" in prompt
        assert "Korean: 안녕하세요" in prompt

    def test_empty_context(self, context):
        """Should handle empty context."""
        prompt = context.get_context_for_prompt(TranslationDirection.KO_TO_EN)
        assert "No previous context" in prompt

    def test_clear(self, context):
        """Should clear all exchanges."""
        context.add_exchange(
            direction=TranslationDirection.KO_TO_EN,
            source_text="test",
            translated_text="test",
        )
        context.clear()
        assert len(context) == 0

    def test_bidirectional_context(self, context):
        """Should track both directions in context."""
        # Add KO->EN
        context.add_exchange(
            direction=TranslationDirection.KO_TO_EN,
            source_text="안녕하세요",
            translated_text="Hello",
        )

        # Add EN->KO
        context.add_exchange(
            direction=TranslationDirection.EN_TO_KO,
            source_text="Nice to meet you",
            translated_text="만나서 반갑습니다",
        )

        assert len(context) == 2

        # Both should appear in context for either direction
        ko_prompt = context.get_context_for_prompt(TranslationDirection.KO_TO_EN)
        assert "안녕하세요" in ko_prompt
        assert "Nice to meet you" in ko_prompt

        en_prompt = context.get_context_for_prompt(TranslationDirection.EN_TO_KO)
        assert "안녕하세요" in en_prompt
        assert "Nice to meet you" in en_prompt
