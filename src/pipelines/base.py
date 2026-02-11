"""Base pipeline interface for translation pipelines."""

from abc import ABC, abstractmethod
from typing import Callable, Optional
import asyncio
import logging

from ..models import TranslationDirection, AudioOut, TranslationResult
from ..session.context import SharedTranslationContext
from ..services import STTService, TTSService, TranslatorService, PhraseBuffer

logger = logging.getLogger(__name__)


class BasePipeline(ABC):
    """Abstract base class for translation pipelines."""

    def __init__(
        self,
        direction: TranslationDirection,
        context: SharedTranslationContext,
        stt: STTService,
        translator: TranslatorService,
        tts: TTSService,
        on_translation: Optional[Callable[[TranslationResult], None]] = None,
        on_audio: Optional[Callable[[AudioOut], None]] = None,
    ):
        """
        Initialize the pipeline.

        Args:
            direction: Translation direction.
            context: Shared translation context.
            stt: Speech-to-text service.
            translator: Translation service.
            tts: Text-to-speech service.
            on_translation: Callback for translation results.
            on_audio: Callback for audio output.
        """
        self.direction = direction
        self.context = context
        self.stt = stt
        self.translator = translator
        self.tts = tts
        self.on_translation = on_translation
        self.on_audio = on_audio
        self.phrase_buffer = PhraseBuffer()
        self._is_running = False
        self._tasks: list[asyncio.Task] = []

    @abstractmethod
    async def start(self) -> None:
        """Start the pipeline."""
        pass

    @abstractmethod
    async def stop(self) -> None:
        """Stop the pipeline."""
        pass

    @abstractmethod
    async def process_audio(self, audio_data: bytes, timestamp_ms: int = 0) -> None:
        """Process incoming audio data."""
        pass

    async def _synthesize_and_emit(self, text: str, target_lang: str) -> None:
        """Synthesize text and emit audio chunks."""
        try:
            async for audio_chunk in self.tts.synthesize_stream(text, target_lang):
                if self.on_audio:
                    msg = AudioOut(
                        direction=self.direction,
                        data=audio_chunk,
                        format="mp3",
                    )
                    self.on_audio(msg)
        except Exception as e:
            logger.error(f"Error synthesizing audio: {e}")

    @property
    def is_running(self) -> bool:
        """Check if the pipeline is running."""
        return self._is_running
