"""English to Korean translation pipeline."""

import asyncio
import logging
import uuid
from typing import Callable, Optional

from ..base import BasePipeline
from .sentence_detector import EnglishSentenceDetector
from .formality import FormalityConfig
from ...models import (
    TranslationDirection,
    TranslationResult,
    AudioOut,
    TranscriptInterim,
    TranscriptFinal,
    ErrorMessage,
    ERROR_CODE_TRANSLATION_REFUSED,
    ERROR_CODE_TRANSLATION_FAILED,
)
from ...session.context import SharedTranslationContext
from ...services import STTService, TTSService, TranslatorService
from ...services.translator import TranslationRefused

logger = logging.getLogger(__name__)


class EnToKrPipeline(BasePipeline):
    """
    English to Korean translation pipeline.

    Flow: English Audio -> STT -> Sentence Detector -> Translator -> TTS -> Korean Audio

    Note: No safety classifier needed - English is SVO so word order is simpler.
    Formality toggle controls whether output uses 해요체 or 높임말.
    """

    def __init__(
        self,
        context: SharedTranslationContext,
        stt: STTService,
        translator: TranslatorService,
        tts: TTSService,
        honorific_mode: bool = False,
        on_interim: Optional[Callable[[TranscriptInterim], None]] = None,
        on_final: Optional[Callable[[TranscriptFinal], None]] = None,
        on_translation: Optional[Callable[[TranslationResult], None]] = None,
        on_audio: Optional[Callable[[AudioOut], None]] = None,
        on_translation_failed: Optional[Callable[[ErrorMessage], None]] = None,
    ):
        """
        Initialize EN->KO pipeline.

        Args:
            context: Shared translation context.
            stt: English STT service.
            translator: Translation service.
            tts: Korean TTS service.
            honorific_mode: Whether to use honorific Korean.
            on_interim: Callback for interim transcripts.
            on_final: Callback for final transcripts.
            on_translation: Callback for translations.
            on_audio: Callback for audio output.
            on_translation_failed: Callback for a segment that couldn't be translated.
        """
        super().__init__(
            direction=TranslationDirection.EN_TO_KO,
            context=context,
            stt=stt,
            translator=translator,
            tts=tts,
            on_translation=on_translation,
            on_audio=on_audio,
            on_translation_failed=on_translation_failed,
        )
        self.on_interim = on_interim
        self.on_final = on_final
        self.sentence_detector = EnglishSentenceDetector()
        self.formality = FormalityConfig(honorific_mode=honorific_mode)
        self._last_interim_text: Optional[str] = None  # Track last interim for short audio handling
        self._last_interim_ms = 0  # Start of the last interim (Deepgram stream time)
        self._had_final_since_interim = False  # Track if we got a final after interim

    async def start(self) -> None:
        """Start the pipeline."""
        if self._is_running:
            logger.warning("EN->KO pipeline already running")
            return

        self._is_running = True
        await self.stt.connect()

        # Start processing loop
        self._tasks = [
            asyncio.create_task(self._process_stt_results()),
        ]

        logger.info(
            f"EN->KO pipeline started (honorific={self.formality.honorific_mode})"
        )

    async def stop(self) -> None:
        """Stop the pipeline."""
        if not self._is_running or self._is_stopping:
            return

        # Reject new audio but keep the results loop running so final
        # transcripts returned for the finalize signal are still translated
        self._is_stopping = True
        try:
            await self._finalize_and_flush()
        except Exception as e:
            logger.error(f"EN->KO: error flushing on stop: {e}")
        finally:
            # Always tear down, even if the flush failed or stop() was cancelled,
            # so KeepAlive doesn't hold an orphaned Deepgram stream open
            self._is_running = False
            self._is_stopping = False

            # Cancel tasks
            for task in self._tasks:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass

            await self.stt.disconnect()
            logger.info("EN->KO pipeline stopped")

    async def process_audio(self, audio_data: bytes, timestamp_ms: int = 0) -> None:
        """Process incoming English audio."""
        if not self._is_running or self._is_stopping:
            return
        await self.stt.send_audio(audio_data)

    def set_honorific(self, enabled: bool) -> None:
        """
        Set honorific mode.

        Args:
            enabled: Whether to enable honorific Korean.
        """
        self.formality.set_honorific(enabled)

    async def _process_stt_results(self) -> None:
        """Process STT results and route through pipeline."""
        try:
            async for result in self.stt.get_results():
                if not self._is_running:
                    break

                # Hold the results lock so stop() flushes only after this result is done
                async with self._processing_result():
                    # Handle utterance end event - flush any buffered content
                    if result.is_utterance_end:
                        logger.debug("EN->KO: Utterance ended, flushing buffers")
                        await self._flush_remaining(utterance_end_ms=result.last_word_end_ms)
                        continue

                    # Handle interim results (for UI feedback)
                    if not result.is_final:
                        if result.text:
                            # Track last interim for short audio handling
                            self._last_interim_text = result.text
                            self._last_interim_ms = result.timestamp_ms
                            self._had_final_since_interim = False
                            if self.on_interim:
                                # Live caption: words still waiting for a segment boundary
                                # (Deepgram's interims restart after each final), then what's
                                # being said now
                                pending = self.sentence_detector.current_buffer
                                msg = TranscriptInterim(
                                    direction=TranslationDirection.EN_TO_KO,
                                    text=f"{pending} {result.text}".strip(),
                                )
                                self.on_interim(msg)
                        continue

                    # Skip empty results (silence filtered by VAD)
                    if not result.text:
                        continue

                    # Mark that we got a final result
                    self._had_final_since_interim = True

                    # Process final result through sentence detector
                    words = result.text.split()
                    for word in words:
                        sentence = self.sentence_detector.add_word(
                            word, result.timestamp_ms
                        )
                        if sentence:
                            await self._process_sentence(sentence)

                    # Deepgram marked the end of speech: translate what's buffered now
                    # rather than waiting for UtteranceEnd, which needs more audio
                    # and never comes if the user pauses the mic
                    if result.speech_final:
                        await self._flush_remaining()

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Error processing STT results: {e}")

    async def _process_sentence(self, sentence: str) -> None:
        """Process a detected sentence through translation."""
        segment_id = str(uuid.uuid4())[:8]
        self._emit_final(sentence, segment_id)

        # Translate and synthesize
        await self._translate_and_speak(sentence, segment_id)

    def _emit_final(self, text: str, segment_id: str) -> None:
        """Emit the final transcript of a segment about to be translated."""
        if self.on_final:
            self.on_final(TranscriptFinal(
                direction=TranslationDirection.EN_TO_KO,
                text=text,
                segment_id=segment_id,
            ))

    async def _translate_and_speak(self, english_text: str, segment_id: str) -> None:
        """Translate English text and synthesize Korean speech."""
        translation_sent = False
        try:
            full_translation = ""

            # Stream translation tokens through phrase buffer
            async for token in self.translator.translate_stream(
                english_text,
                TranslationDirection.EN_TO_KO,
                self.context,
                honorific_mode=self.formality.honorific_mode,
            ):
                full_translation += token
                phrase = self.phrase_buffer.add_token(token)
                if phrase:
                    await self._synthesize_and_emit(phrase, "ko")

            # The stream has ended without a refusal: send the text now, before
            # the trailing phrase's TTS, so the chat isn't a whole clip behind the audio
            self._emit_translation(
                english_text, full_translation, segment_id,
                honorific=self.formality.honorific_mode,
            )
            translation_sent = True

            # Flush remaining phrase buffer
            remaining = self.phrase_buffer.force_flush()
            if remaining:
                await self._synthesize_and_emit(remaining, "ko")

        except TranslationRefused as e:
            # Expected policy decline (already logged by the translator) - drop the partial
            logger.warning(f"EN->KO segment {segment_id} not translated: {e}")
            self.phrase_buffer.clear()
            self._emit_translation_failed(english_text, segment_id, ERROR_CODE_TRANSLATION_REFUSED)
        except Exception as e:
            logger.error(f"Error in translate_and_speak: {e}")
            # Drop partial tokens so they don't leak into the next utterance's audio
            self.phrase_buffer.clear()
            if not translation_sent:
                self._emit_translation_failed(english_text, segment_id, ERROR_CODE_TRANSLATION_FAILED)

    async def _flush_remaining(self, utterance_end_ms: Optional[int] = None) -> None:
        """Flush any remaining content in buffers."""
        # Handle pending interim text (for short audio that never got a final).
        # Skip an interim that started after the utterance Deepgram just ended
        # (late UtteranceEnd after a mic pause): it's the next utterance and its
        # final is still coming, so processing it here would glue and duplicate it
        if (
            self._last_interim_text
            and not self._had_final_since_interim
            and (utterance_end_ms is None or self._last_interim_ms < utterance_end_ms)
        ):
            logger.info(f"EN->KO: Processing pending interim as final: {self._last_interim_text}")
            # Process the interim text as if it were final
            words = self._last_interim_text.split()
            for word in words:
                sentence = self.sentence_detector.add_word(word, 0)
                if sentence:
                    await self._process_sentence(sentence)
            self._last_interim_text = None

        # Flush sentence detector
        sentence = self.sentence_detector.force_flush()
        if sentence:
            segment_id = str(uuid.uuid4())[:8]
            self._emit_final(sentence, segment_id)
            await self._translate_and_speak(sentence, segment_id)

        # Flush phrase buffer
        remaining = self.phrase_buffer.force_flush()
        if remaining:
            await self._synthesize_and_emit(remaining, "ko")
