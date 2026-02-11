"""Text-to-Speech service using ElevenLabs."""

import asyncio
import logging
from typing import AsyncGenerator, Optional, Callable

from elevenlabs import AsyncElevenLabs

from ..config import get_settings

logger = logging.getLogger(__name__)


class TTSService:
    """Streaming TTS service using ElevenLabs."""

    def __init__(
        self,
        on_audio: Optional[Callable[[bytes], None]] = None,
        voice_id: Optional[str] = None,
    ):
        """
        Initialize TTS service.

        Args:
            on_audio: Callback for audio chunks
            voice_id: ElevenLabs voice ID to use
        """
        self.settings = get_settings()
        self.on_audio = on_audio
        self.voice_id = voice_id or self.settings.elevenlabs_voice_id
        self._client = AsyncElevenLabs(api_key=self.settings.elevenlabs_api_key)
        self._audio_queue: asyncio.Queue[bytes] = asyncio.Queue()
        self._is_running: bool = False

    async def start(self) -> None:
        """Start the TTS service."""
        self._is_running = True
        logger.info("TTS service started")

    async def stop(self) -> None:
        """Stop the TTS service."""
        self._is_running = False
        logger.info("TTS service stopped")

    async def synthesize(self, text: str) -> bytes:
        """
        Synthesize text to audio.

        Args:
            text: The text to synthesize

        Returns:
            Audio bytes (mp3 format)
        """
        if not self._is_running:
            logger.warning("TTS service not running")
            return b""

        if not text.strip():
            return b""

        try:
            audio_data = b""

            # Use streaming synthesis
            async for chunk in self._client.text_to_speech.convert_as_stream(
                voice_id=self.voice_id,
                text=text,
                model_id="eleven_turbo_v2_5",
                output_format="mp3_44100_128",
            ):
                audio_data += chunk
                await self._audio_queue.put(chunk)
                if self.on_audio:
                    self.on_audio(chunk)

            logger.debug(f"TTS synthesized {len(audio_data)} bytes for: '{text[:50]}...'")
            return audio_data

        except Exception as e:
            logger.error(f"TTS synthesis error: {e}")
            raise

    async def synthesize_stream(self, text: str) -> AsyncGenerator[bytes, None]:
        """
        Stream synthesized audio chunks.

        Args:
            text: The text to synthesize

        Yields:
            Audio chunks as they are generated
        """
        if not self._is_running:
            logger.warning("TTS service not running")
            return

        if not text.strip():
            return

        try:
            async for chunk in self._client.text_to_speech.convert_as_stream(
                voice_id=self.voice_id,
                text=text,
                model_id="eleven_turbo_v2_5",
                output_format="mp3_44100_128",
            ):
                yield chunk

        except Exception as e:
            logger.error(f"TTS stream error: {e}")
            raise

    @property
    def audio_queue(self) -> asyncio.Queue[bytes]:
        """Get the audio queue for external consumption."""
        return self._audio_queue

    @property
    def is_running(self) -> bool:
        """Check if the service is running."""
        return self._is_running
