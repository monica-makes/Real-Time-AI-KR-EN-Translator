"""Base pipeline interface for translation pipelines."""

from abc import ABC, abstractmethod
from contextlib import asynccontextmanager
from typing import AsyncIterator, Callable, Optional
import asyncio
import logging
import time

from ..models import TranslationDirection, AudioOut, TranslationResult
from ..session.context import SharedTranslationContext
from ..services import STTService, TTSService, TranslatorService, PhraseBuffer

logger = logging.getLogger(__name__)


class WordBoundaryPhraseBuffer(PhraseBuffer):
    """
    PhraseBuffer whose timeout release never ends a phrase mid-word.

    Each phrase becomes its own TTS clip, so a timeout flush between streamed
    tokens ("주문" + "할게요.") would be spoken as two clips with a gap inside
    the word. The last, possibly incomplete, word is kept for the next phrase.
    """

    def add_token(self, token: str) -> Optional[str]:
        """Add a token; returns a phrase ending at a word boundary or natural break."""
        buffer_start = self._buffer_start if self._buffer_start is not None else time.time()
        phrase = super().add_token(token)
        if (
            not phrase
            or phrase[-1].isspace()
            or phrase.rstrip().endswith(tuple(self.BREAK_CHARS))
        ):
            return phrase

        # Released by the timeout: hold back the last word (or everything if
        # there is no word boundary yet) and keep the original start time so
        # it is released as soon as the next boundary arrives
        head, _, tail = phrase.rpartition(" ")
        if len(head) < self.min_chars:
            head, tail = "", phrase
        self._buffer = [tail]
        self._buffer_start = buffer_start
        return head or None


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
        self.phrase_buffer = WordBoundaryPhraseBuffer()
        self._is_running = False
        self._is_stopping = False  # True while stop() finalizes; new audio is rejected
        self._tasks: list[asyncio.Task] = []
        # Held while the results loop processes one STT result so stop() can flush after it
        self._results_lock = asyncio.Lock()
        self._results_in_flight = 0  # Results taken off the STT queue but not yet processed
        self.stop_wait_timeout_s = 10.0  # Max time stop() waits for trailing results

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

    @abstractmethod
    async def _flush_remaining(self, utterance_end_ms: Optional[int] = None) -> None:
        """
        Flush any remaining content in buffers.

        Args:
            utterance_end_ms: For an UtteranceEnd flush, where Deepgram says the
                utterance's last word ended (stream time).
        """
        pass

    @asynccontextmanager
    async def _processing_result(self) -> AsyncIterator[None]:
        """Hold the results lock while one STT result is processed.

        Entered right after the result is taken off the queue, so stop() can
        tell a result is pending even while it waits for the lock.
        """
        self._results_in_flight += 1
        try:
            async with self._results_lock:
                yield
        finally:
            self._results_in_flight -= 1

    def _has_pending_results(self) -> bool:
        """True while the results loop is alive and still has STT results to process."""
        return any(not task.done() for task in self._tasks) and (
            not self.stt.result_queue.empty() or self._results_in_flight > 0
        )

    async def _finalize_and_flush(self) -> None:
        """
        Finalize STT and flush buffers while the results loop is still running.

        Called from stop() before _is_running is cleared, so final transcripts
        Deepgram returns for the finalize signal are still translated.
        """
        # Signal end of audio to get final transcripts
        await self.stt.finalize()

        loop = asyncio.get_running_loop()
        deadline = loop.time() + self.stop_wait_timeout_s
        while True:
            # Let the results loop pick up and finish any trailing results (bounded)
            while self._has_pending_results() and loop.time() < deadline:
                await asyncio.sleep(0.02)

            if self._results_in_flight:
                logger.warning(
                    f"{self.direction.value}: timed out waiting for STT results, skipping flush"
                )
                return

            # Flush remaining content
            async with self._results_lock:
                await self._flush_remaining()

            # A late final can arrive while the flush translates; go round again
            # so it isn't dropped when stop() cancels the results loop
            if not self._has_pending_results():
                return
            if loop.time() >= deadline:
                logger.warning(
                    f"{self.direction.value}: timed out waiting for STT results, "
                    f"dropping late results"
                )
                return

    async def _synthesize_and_emit(self, text: str, target_lang: str) -> None:
        """Synthesize text and emit it as one complete MP3 clip."""
        try:
            # Clients play each audio message as a standalone file, so collect
            # the whole phrase instead of emitting each streamed chunk
            chunks: list[bytes] = []
            async for audio_chunk in self.tts.synthesize_stream(text, target_lang):
                if audio_chunk:
                    chunks.append(audio_chunk)

            audio_data = b"".join(chunks)
            if audio_data and self.on_audio:
                msg = AudioOut(
                    direction=self.direction,
                    data=audio_data,
                    format="mp3",
                )
                self.on_audio(msg)
        except Exception as e:
            logger.error(f"Error synthesizing audio: {e}")

    @property
    def is_running(self) -> bool:
        """Check if the pipeline is running."""
        return self._is_running
