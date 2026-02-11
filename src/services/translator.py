"""Translation service using Claude API."""

import logging
from typing import AsyncIterator

import anthropic

from ..config import get_settings
from ..models import TranslationDirection
from ..session.context import SharedTranslationContext

logger = logging.getLogger(__name__)


KO_TO_EN_PROMPT = """You are a real-time Korean to English translator.

RULES:
1. Output ONLY the English translation - no explanations, no Korean
2. Translate meaning, not word-for-word
3. Korean is SOV, English is SVO - reorder appropriately
4. Korean often drops subjects - infer from context
5. Match the tone: formal Korean -> formal English
6. Keep translations concise for spoken delivery
7. Translate Korean idioms to their English equivalent meanings:
   - 발이 넓다 = well-connected, knows many people
   - 눈이 높다 = has high standards
   - 식은 죽 먹기 = a piece of cake, very easy
   - 손이 크다 = generous
   - 입이 가볍다 = can't keep a secret
   - 눈치가 빠르다 = perceptive, quick to read situations
   - 귀가 얇다 = easily influenced by others

{context}"""


EN_TO_KO_BASE_PROMPT = """You are a real-time English to Korean translator.

Translate to natural Korean using 해요체 (polite informal).

RULES:
1. Output ONLY the Korean translation - no explanations, no English
2. Use -요 endings
3. Use standard verbs: 먹다, 자다, 있다, 말하다, 주다, 보다
4. Drop pronouns (I, you) where contextually clear
5. Reorder to Korean SOV structure
6. Keep translations concise for spoken delivery

{context}"""


EN_TO_KO_HONORIFIC_PROMPT = """You are a real-time English to Korean translator.

Translate to Korean using honorific speech (높임말).

RULES:
1. Output ONLY the Korean translation - no explanations, no English
2. Use honorific verb forms:
   - 먹다 → 드시다 (eat)
   - 자다 → 주무시다 (sleep)
   - 있다 → 계시다 (be/exist)
   - 말하다 → 말씀하시다 (speak)
   - 주다 → 드리다 (give)
   - 보다 → 뵙다 (see/meet)
3. Use -요 or -습니다 endings as appropriate
4. Drop pronouns where contextually clear
5. Reorder to Korean SOV structure
6. Keep translations concise for spoken delivery

{context}"""


class TranslatorService:
    """Unified translation service for both directions."""

    def __init__(self):
        """Initialize translator service."""
        self.settings = get_settings()
        self._client = anthropic.AsyncAnthropic(
            api_key=self.settings.anthropic_api_key
        )

    def _get_prompt(
        self,
        direction: TranslationDirection,
        honorific_mode: bool,
        context: SharedTranslationContext,
    ) -> str:
        """Build system prompt based on direction and settings."""
        context_str = context.get_context_for_prompt(direction)

        if direction == TranslationDirection.KO_TO_EN:
            return KO_TO_EN_PROMPT.format(context=context_str)
        else:
            base = EN_TO_KO_HONORIFIC_PROMPT if honorific_mode else EN_TO_KO_BASE_PROMPT
            return base.format(context=context_str)

    async def translate(
        self,
        text: str,
        direction: TranslationDirection,
        context: SharedTranslationContext,
        honorific_mode: bool = False,
    ) -> str:
        """
        Translate text and return full translation.

        Args:
            text: Text to translate.
            direction: Translation direction.
            context: Shared translation context.
            honorific_mode: Whether to use honorific Korean.

        Returns:
            The translated text.
        """
        full_translation = ""
        async for token in self.translate_stream(
            text, direction, context, honorific_mode
        ):
            full_translation += token
        return full_translation

    async def translate_stream(
        self,
        text: str,
        direction: TranslationDirection,
        context: SharedTranslationContext,
        honorific_mode: bool = False,
    ) -> AsyncIterator[str]:
        """
        Stream translation tokens.

        Args:
            text: Text to translate.
            direction: Translation direction.
            context: Shared translation context.
            honorific_mode: Whether to use honorific Korean.

        Yields:
            Translation tokens as they are generated.
        """
        system_prompt = self._get_prompt(direction, honorific_mode, context)

        try:
            full_translation = []

            async with self._client.messages.stream(
                model="claude-sonnet-4-20250514",
                max_tokens=200,
                system=system_prompt,
                messages=[{"role": "user", "content": f"Translate: {text}"}]
            ) as stream:
                async for token in stream.text_stream:
                    full_translation.append(token)
                    yield token

            # Add to shared context
            translated_text = "".join(full_translation)
            context.add_exchange(
                direction=direction,
                source_text=text,
                translated_text=translated_text,
            )

            logger.info(
                f"Translation ({direction.value}): '{text}' -> '{translated_text}'"
            )

        except Exception as e:
            logger.error(f"Translation error: {e}")
            raise
