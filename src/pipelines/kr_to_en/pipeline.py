"""Korean to English translation pipeline."""

import asyncio
import logging
import uuid
from typing import Callable, Optional

from ..base import BasePipeline
from .clause_detector import KoreanClauseDetector
from .classifier import SafetyClassifier
from ...models import (
    TranslationDirection,
    TranslationResult,
    AudioOut,
    TranscriptInterim,
    TranscriptFinal,
    ClassifierDecision,
    ClassifierResult,
)
from ...session.context import SharedTranslationContext
from ...services import STTService, TTSService, TranslatorService

logger = logging.getLogger(__name__)

# Deepgram punctuates sentence ends (punctuate/smart_format)
SENTENCE_PUNCTUATION = (".", "?", "!")


class KrToEnPipeline(BasePipeline):
    """
    Korean to English translation pipeline.

    Flow: Korean Audio -> STT -> Clause Detector -> Classifier -> Translator -> TTS -> English Audio
    """

    def __init__(
        self,
        context: SharedTranslationContext,
        stt: STTService,
        translator: TranslatorService,
        tts: TTSService,
        on_interim: Optional[Callable[[TranscriptInterim], None]] = None,
        on_final: Optional[Callable[[TranscriptFinal], None]] = None,
        on_classifier: Optional[Callable[[ClassifierDecision], None]] = None,
        on_translation: Optional[Callable[[TranslationResult], None]] = None,
        on_audio: Optional[Callable[[AudioOut], None]] = None,
    ):
        """
        Initialize KO->EN pipeline.

        Args:
            context: Shared translation context.
            stt: Korean STT service.
            translator: Translation service.
            tts: English TTS service.
            on_interim: Callback for interim transcripts.
            on_final: Callback for final transcripts.
            on_classifier: Callback for classifier decisions.
            on_translation: Callback for translations.
            on_audio: Callback for audio output.
        """
        super().__init__(
            direction=TranslationDirection.KO_TO_EN,
            context=context,
            stt=stt,
            translator=translator,
            tts=tts,
            on_translation=on_translation,
            on_audio=on_audio,
        )
        self.on_interim = on_interim
        self.on_final = on_final
        self.on_classifier = on_classifier
        self.clause_detector = KoreanClauseDetector()
        self.classifier = SafetyClassifier()
        self._last_interim_text: Optional[str] = None  # Track last interim for short audio handling
        self._last_interim_ms = 0  # Start of the last interim (Deepgram stream time)
        self._had_final_since_interim = False  # Track if we got a final after interim

    async def start(self) -> None:
        """Start the pipeline."""
        if self._is_running:
            logger.warning("KO->EN pipeline already running")
            return

        self._is_running = True
        await self.stt.connect()

        # Start processing loop
        self._tasks = [
            asyncio.create_task(self._process_stt_results()),
        ]

        logger.info("KO->EN pipeline started")

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
            logger.error(f"KO->EN: error flushing on stop: {e}")
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
            logger.info("KO->EN pipeline stopped")

    async def process_audio(self, audio_data: bytes, timestamp_ms: int = 0) -> None:
        """Process incoming Korean audio."""
        if not self._is_running or self._is_stopping:
            return
        await self.stt.send_audio(audio_data)

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
                        logger.debug("KO->EN: Utterance ended, flushing buffers")
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
                                msg = TranscriptInterim(
                                    direction=TranslationDirection.KO_TO_EN,
                                    text=result.text,
                                )
                                self.on_interim(msg)
                        continue

                    # Skip empty results (silence filtered by VAD)
                    if not result.text:
                        continue

                    # Mark that we got a final result
                    self._had_final_since_interim = True

                    # Process final result through clause detector
                    await self._process_words(result.text, result.timestamp_ms)

                    # Deepgram marked the end of speech: translate what's buffered now
                    # rather than waiting for UtteranceEnd, which needs more audio
                    # and never comes if the user pauses the mic
                    if result.speech_final:
                        await self._flush_remaining()

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Error processing STT results: {e}")

    async def _process_words(self, text: str, timestamp_ms: int) -> None:
        """Split transcript text into words and process each through the clause detector."""
        for word in text.split():
            clause = self.clause_detector.add_word(word, timestamp_ms)
            if clause:
                await self._process_clause(clause)

            if word.endswith(SENTENCE_PUNCTUATION):
                # Punctuation hides the Korean ending ("안녕하세요.") from the
                # clause detector, so close the sentence here
                clause = self.clause_detector.force_flush()
                if clause:
                    await self._process_clause(clause)

    async def _process_clause(self, clause) -> None:
        """Process a detected clause through classifier and translation."""
        # Classify the clause
        decision = self.classifier.classify(clause)

        # Emit classifier decision
        if self.on_classifier:
            msg = ClassifierDecision(
                clause=clause.text,
                connector=clause.connector,
                decision=decision.value,
            )
            self.on_classifier(msg)

        if decision == ClassifierResult.WAIT:
            # Return clause to buffer
            self.clause_detector.return_to_buffer(clause)
            return

        # SAFE - proceed with translation
        segment_id = str(uuid.uuid4())[:8]

        # Emit final transcript
        if self.on_final:
            msg = TranscriptFinal(
                direction=TranslationDirection.KO_TO_EN,
                text=clause.text,
                segment_id=segment_id,
            )
            self.on_final(msg)

        # Translate and synthesize
        await self._translate_and_speak(clause.text, segment_id)

    async def _translate_and_speak(self, korean_text: str, segment_id: str) -> None:
        """Translate Korean text and synthesize English speech."""
        try:
            full_translation = ""

            # Stream translation tokens through phrase buffer
            async for token in self.translator.translate_stream(
                korean_text,
                TranslationDirection.KO_TO_EN,
                self.context,
            ):
                full_translation += token
                phrase = self.phrase_buffer.add_token(token)
                if phrase:
                    await self._synthesize_and_emit(phrase, "en")

            # Flush remaining phrase buffer
            remaining = self.phrase_buffer.force_flush()
            if remaining:
                await self._synthesize_and_emit(remaining, "en")

            # Emit translation result
            if self.on_translation:
                msg = TranslationResult(
                    direction=TranslationDirection.KO_TO_EN,
                    original=korean_text,
                    translated=full_translation,
                    segment_id=segment_id,
                )
                self.on_translation(msg)

        except Exception as e:
            logger.error(f"Error in translate_and_speak: {e}")
            # Drop partial tokens so they don't leak into the next utterance's audio
            self.phrase_buffer.clear()

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
            logger.info(f"KO->EN: Processing pending interim as final: {self._last_interim_text}")
            # Process the interim text as if it were final
            await self._process_words(self._last_interim_text, 0)
            self._last_interim_text = None

        # Flush clause detector
        clause = self.clause_detector.force_flush()
        if clause:
            segment_id = str(uuid.uuid4())[:8]
            await self._translate_and_speak(clause.text, segment_id)

        # Flush phrase buffer
        remaining = self.phrase_buffer.force_flush()
        if remaining:
            await self._synthesize_and_emit(remaining, "en")
