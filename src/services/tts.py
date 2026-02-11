"""Text-to-Speech service using ElevenLabs."""

import asyncio
import logging
from typing import AsyncIterator, Literal, Optional

from elevenlabs import AsyncElevenLabs

from ..config import get_settings
from .voice_detection import VOICES, detect_language, get_voice_id

logger = logging.getLogger(__name__)


class TTSService:
    """Streaming TTS service using ElevenLabs for Korean and English."""

    def __init__(self):
        """Initialize TTS service."""
        self.settings = get_settings()
        self._client = AsyncElevenLabs(api_key=self.settings.elevenlabs_api_key)
        self._is_running = False
        # Current gender setting (can be overridden)
        self._current_gender: Literal["male", "female"] = "female"

    async def start(self) -> None:
        """Start the TTS service."""
        self._is_running = True
        logger.info("TTS service started")

    async def stop(self) -> None:
        """Stop the TTS service."""
        self._is_running = False
        logger.info("TTS service stopped")

    def set_gender(self, gender: Literal["male", "female"]) -> None:
        """
        Set the current gender for voice selection.

        Args:
            gender: Gender to use for voice selection.
        """
        self._current_gender = gender
        logger.info(f"TTS gender set to: {gender}")

    def get_voice_for_text(
        self,
        text: str,
        gender_override: Optional[Literal["male", "female"]] = None,
    ) -> str:
        """
        Get the appropriate voice ID for text based on language and gender.

        Args:
            text: Text to synthesize (used for language detection).
            gender_override: Optional gender override.

        Returns:
            ElevenLabs voice ID.
        """
        language = detect_language(text)
        gender = gender_override or self._current_gender
        voice_id = get_voice_id(language, gender)
        logger.debug(
            f"Voice selection: language={language}, gender={gender}, voice_id={voice_id}"
        )
        return voice_id

    async def synthesize(
        self,
        text: str,
        language: Optional[Literal["ko", "en"]] = None,
        gender_override: Optional[Literal["male", "female"]] = None,
    ) -> bytes:
        """
        Synthesize text to audio.

        Args:
            text: Text to synthesize.
            language: Target language. If None, auto-detect from text.
            gender_override: Optional gender override.

        Returns:
            Audio bytes (mp3 format).
        """
        if not self._is_running:
            logger.warning("TTS service not running")
            return b""

        if not text.strip():
            return b""

        try:
            # Auto-detect language if not provided
            if language is None:
                language = detect_language(text)

            # Get voice based on language and gender
            gender = gender_override or self._current_gender
            voice_id = get_voice_id(language, gender)

            # Use non-streaming convert and collect response as bytes
            # The convert method returns an async iterator, collect all chunks
            audio_generator = self._client.text_to_speech.convert(
                voice_id=voice_id,
                text=text,
                model_id="eleven_turbo_v2_5",
                output_format="mp3_44100_128",
            )

            # Collect all chunks into a list first to ensure complete consumption
            chunks: list[bytes] = []
            async for chunk in audio_generator:
                if chunk:  # Only append non-empty chunks
                    chunks.append(chunk)

            # Join all chunks after fully consuming the stream
            audio_data = b"".join(chunks)

            # Small delay to ensure stream is fully closed
            await asyncio.sleep(0.1)

            logger.debug(
                f"TTS ({language}/{gender}) synthesized {len(audio_data)} bytes "
                f"({len(chunks)} chunks) for: '{text[:50]}...'"
            )
            return audio_data

        except Exception as e:
            logger.error(f"TTS synthesis error: {e}")
            raise

    async def synthesize_stream(
        self,
        text: str,
        language: Optional[Literal["ko", "en"]] = None,
        gender_override: Optional[Literal["male", "female"]] = None,
    ) -> AsyncIterator[bytes]:
        """
        Stream synthesized audio chunks.

        Args:
            text: Text to synthesize.
            language: Target language. If None, auto-detect from text.
            gender_override: Optional gender override.

        Yields:
            Audio chunks as they are generated.
        """
        if not self._is_running:
            logger.warning("TTS service not running")
            return

        if not text.strip():
            return

        try:
            # Auto-detect language if not provided
            if language is None:
                language = detect_language(text)

            # Get voice based on language and gender
            gender = gender_override or self._current_gender
            voice_id = get_voice_id(language, gender)

            logger.debug(f"TTS streaming: language={language}, gender={gender}")

            async for chunk in self._client.text_to_speech.convert(
                voice_id=voice_id,
                text=text,
                model_id="eleven_turbo_v2_5",
                output_format="mp3_44100_128",
            ):
                yield chunk

        except Exception as e:
            logger.error(f"TTS stream error: {e}")
            raise

    @property
    def is_running(self) -> bool:
        """Check if the service is running."""
        return self._is_running

    @property
    def current_gender(self) -> Literal["male", "female"]:
        """Get the current gender setting."""
        return self._current_gender
