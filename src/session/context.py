"""Shared translation context between pipelines."""

from collections import deque
from datetime import datetime
from typing import Deque

from ..models import Exchange, TranslationDirection
from ..config import get_settings


class SharedTranslationContext:
    """
    Shared context between both pipelines.
    Enables pronoun resolution and consistency across translations.
    """

    def __init__(self, max_exchanges: int | None = None):
        """
        Initialize shared context.

        Args:
            max_exchanges: Maximum number of exchanges to keep in context.
        """
        settings = get_settings()
        self.max_exchanges = max_exchanges or settings.max_context_exchanges
        self.exchanges: Deque[Exchange] = deque(maxlen=self.max_exchanges)

    def add_exchange(
        self,
        direction: TranslationDirection,
        source_text: str,
        translated_text: str,
    ) -> None:
        """
        Add a translation exchange to the context.

        Args:
            direction: Direction of translation.
            source_text: Original text.
            translated_text: Translated text.
        """
        exchange = Exchange(
            timestamp=datetime.now(),
            direction=direction,
            source_text=source_text,
            translated_text=translated_text,
        )
        self.exchanges.append(exchange)

    def get_context_for_prompt(self, direction: TranslationDirection) -> str:
        """
        Format context for Claude prompt.

        Args:
            direction: Current translation direction.

        Returns:
            Formatted context string for the prompt.
        """
        if not self.exchanges:
            return "No previous context."

        lines = ["Recent conversation:"]

        for ex in self.exchanges:
            if direction == TranslationDirection.KO_TO_EN:
                # For KO->EN, show Korean and English in order
                if ex.direction == TranslationDirection.KO_TO_EN:
                    korean = ex.source_text
                    english = ex.translated_text
                else:
                    korean = ex.translated_text
                    english = ex.source_text
                lines.append(f"Korean: {korean}")
                lines.append(f"English: {english}")
            else:
                # For EN->KO, show English and Korean in order
                if ex.direction == TranslationDirection.EN_TO_KO:
                    english = ex.source_text
                    korean = ex.translated_text
                else:
                    english = ex.translated_text
                    korean = ex.source_text
                lines.append(f"English: {english}")
                lines.append(f"Korean: {korean}")

        return "\n".join(lines)

    def clear(self) -> None:
        """Clear all exchanges from context."""
        self.exchanges.clear()

    def __len__(self) -> int:
        """Return number of exchanges in context."""
        return len(self.exchanges)
