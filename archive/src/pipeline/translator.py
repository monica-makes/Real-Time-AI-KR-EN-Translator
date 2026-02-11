"""Translation service using Claude API."""

import asyncio
import logging
import time
from typing import AsyncGenerator, Optional, Callable

import anthropic

from ..config import get_settings
from ..models import Clause, SessionState

logger = logging.getLogger(__name__)


SYSTEM_PROMPT = """You are a real-time Korean to English translator for live conversation.

CRITICAL RULES:
1. Output ONLY the English translation - no explanations, no Korean text, no quotes
2. Translate the meaning, not word-for-word
3. Korean is SOV, English is SVO - reorder appropriately
4. Korean often drops subjects - infer from context when possible
5. Match the tone: formal Korean (습니다) → formal English, casual (반말) → casual English
6. Keep translations concise - this is for real-time speech
7. If a clause seems incomplete, provide your best natural translation

{formality_instruction}

{context_section}"""


class TranslatorService:
    """Translation service using Claude API with streaming."""

    def __init__(
        self,
        on_token: Optional[Callable[[str], None]] = None,
        formality: str = "auto",
    ):
        """
        Initialize translator service.

        Args:
            on_token: Callback for each streamed token
            formality: Translation formality level ('formal', 'casual', 'auto')
        """
        self.settings = get_settings()
        self.on_token = on_token
        self.formality = formality
        self._client = anthropic.AsyncAnthropic(
            api_key=self.settings.anthropic_api_key
        )
        self._token_queue: asyncio.Queue[str] = asyncio.Queue()
        self._context: list[dict] = []
        self._max_context = self.settings.translation_context_window

    def _build_system_prompt(self) -> str:
        """Build system prompt with formality and context."""
        # Formality instruction
        if self.formality == "formal":
            formality_instruction = "Use formal English throughout."
        elif self.formality == "casual":
            formality_instruction = "Use casual, conversational English."
        else:
            formality_instruction = "Match the formality level of the Korean input."

        # Context section
        if self._context:
            context_lines = [
                f"- Korean: {ex['korean']} → English: {ex['english']}"
                for ex in self._context[-self._max_context:]
            ]
            context_section = (
                "Recent translation context (for consistency):\n"
                + "\n".join(context_lines)
            )
        else:
            context_section = ""

        return SYSTEM_PROMPT.format(
            formality_instruction=formality_instruction,
            context_section=context_section,
        )

    async def translate(
        self,
        clause: Clause,
        session_state: Optional[SessionState] = None,
    ) -> str:
        """
        Translate a Korean clause to English.

        Args:
            clause: The clause to translate
            session_state: Optional session state for context

        Returns:
            The English translation
        """
        start_time = time.time()
        korean_text = clause.text

        # Use session context if available
        if session_state:
            self._context = session_state.translation_context.copy()

        system_prompt = self._build_system_prompt()

        try:
            full_translation = ""

            # Stream the response
            async with self._client.messages.stream(
                model="claude-sonnet-4-20250514",
                max_tokens=256,
                system=system_prompt,
                messages=[
                    {
                        "role": "user",
                        "content": f"Translate: {korean_text}",
                    }
                ],
            ) as stream:
                async for text in stream.text_stream:
                    full_translation += text
                    await self._token_queue.put(text)
                    if self.on_token:
                        self.on_token(text)

            # Signal end of translation
            await self._token_queue.put("")

            # Update context
            self._add_to_context(korean_text, full_translation)
            if session_state:
                session_state.add_to_context(
                    korean_text,
                    full_translation,
                    self._max_context,
                )

            latency_ms = int((time.time() - start_time) * 1000)
            logger.info(
                f"Translation completed in {latency_ms}ms: "
                f"'{korean_text}' → '{full_translation}'"
            )

            return full_translation

        except Exception as e:
            logger.error(f"Translation error: {e}")
            raise

    async def translate_stream(
        self,
        clause: Clause,
        session_state: Optional[SessionState] = None,
    ) -> AsyncGenerator[str, None]:
        """
        Stream translation tokens.

        Args:
            clause: The clause to translate
            session_state: Optional session state for context

        Yields:
            Translation tokens as they are generated
        """
        korean_text = clause.text

        # Use session context if available
        if session_state:
            self._context = session_state.translation_context.copy()

        system_prompt = self._build_system_prompt()

        try:
            full_translation = ""

            async with self._client.messages.stream(
                model="claude-sonnet-4-20250514",
                max_tokens=256,
                system=system_prompt,
                messages=[
                    {
                        "role": "user",
                        "content": f"Translate: {korean_text}",
                    }
                ],
            ) as stream:
                async for text in stream.text_stream:
                    full_translation += text
                    yield text

            # Update context
            self._add_to_context(korean_text, full_translation)
            if session_state:
                session_state.add_to_context(
                    korean_text,
                    full_translation,
                    self._max_context,
                )

        except Exception as e:
            logger.error(f"Translation stream error: {e}")
            raise

    def _add_to_context(self, korean: str, english: str) -> None:
        """Add translation pair to context window."""
        self._context.append({
            "korean": korean,
            "english": english,
        })
        if len(self._context) > self._max_context:
            self._context = self._context[-self._max_context:]

    @property
    def token_queue(self) -> asyncio.Queue[str]:
        """Get the token queue for external consumption."""
        return self._token_queue

    def clear_context(self) -> None:
        """Clear the translation context."""
        self._context = []
