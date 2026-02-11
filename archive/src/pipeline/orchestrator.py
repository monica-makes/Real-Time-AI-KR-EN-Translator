"""Pipeline orchestrator that coordinates all components."""

import asyncio
import logging
import time
import uuid
from typing import Optional, Callable

from ..config import get_settings
from ..models import (
    Word,
    Clause,
    ClassifierDecision,
    SessionState,
    TranscriptInterim,
    ClauseDetected,
    TranslationText,
    AudioOut,
)
from .stt import STTService
from .clause_detector import ClauseDetector
from .classifier import SafetyClassifier
from .translator import TranslatorService
from .phrase_buffer import PhraseBuffer
from .tts import TTSService

logger = logging.getLogger(__name__)


class PipelineOrchestrator:
    """
    Coordinates all pipeline components for a translation session.

    Flow:
    Audio → STT → Clause Detector → Safety Classifier → Translator → Phrase Buffer → TTS → Audio Out

    Uses async queues for inter-component communication.
    """

    def __init__(
        self,
        on_interim: Optional[Callable[[TranscriptInterim], None]] = None,
        on_clause: Optional[Callable[[ClauseDetected], None]] = None,
        on_translation: Optional[Callable[[TranslationText], None]] = None,
        on_audio: Optional[Callable[[AudioOut], None]] = None,
    ):
        """
        Initialize the pipeline orchestrator.

        Args:
            on_interim: Callback for interim transcription
            on_clause: Callback for clause detection
            on_translation: Callback for translation result
            on_audio: Callback for audio output
        """
        self.settings = get_settings()

        # Callbacks for WebSocket output
        self.on_interim = on_interim
        self.on_clause = on_clause
        self.on_translation = on_translation
        self.on_audio = on_audio

        # Session state
        self.session_id = str(uuid.uuid4())
        self.session_state = SessionState(session_id=self.session_id)

        # Pipeline components
        self.stt = STTService(
            on_interim=self._handle_interim,
        )
        self.clause_detector = ClauseDetector()
        self.classifier = SafetyClassifier()
        self.translator = TranslatorService()
        self.phrase_buffer = PhraseBuffer()
        self.tts = TTSService()

        # Task handles
        self._tasks: list[asyncio.Task] = []
        self._is_running = False

    async def start(self) -> None:
        """Start the pipeline."""
        if self._is_running:
            logger.warning("Pipeline already running")
            return

        self._is_running = True
        self.session_state.is_active = True

        # Start all components
        await self.stt.connect()
        await self.clause_detector.start()
        await self.phrase_buffer.start()
        await self.tts.start()

        # Start processing loops
        self._tasks = [
            asyncio.create_task(self._process_words()),
            asyncio.create_task(self._process_clauses()),
        ]

        logger.info(f"Pipeline started: session={self.session_id}")

    async def stop(self) -> None:
        """Stop the pipeline and clean up."""
        if not self._is_running:
            return

        self._is_running = False
        self.session_state.is_active = False

        # Cancel all tasks
        for task in self._tasks:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

        # Stop all components
        await self.clause_detector.stop()
        await self.phrase_buffer.stop()
        await self.tts.stop()
        await self.stt.disconnect()

        logger.info(f"Pipeline stopped: session={self.session_id}")

    async def process_audio(self, audio_data: bytes) -> None:
        """
        Process incoming audio data.

        Args:
            audio_data: Raw audio bytes (PCM 16-bit, 16kHz, mono)
        """
        if not self._is_running:
            logger.warning("Pipeline not running, ignoring audio")
            return

        self.session_state.update_activity()
        await self.stt.send_audio(audio_data)

    def _handle_interim(self, text: str) -> None:
        """Handle interim transcription results."""
        if self.on_interim:
            msg = TranscriptInterim(text=text)
            self.on_interim(msg)

    async def _process_words(self) -> None:
        """Process words from STT and send to clause detector."""
        try:
            async for word in self.stt.get_words():
                if not self._is_running:
                    break

                # Add word to clause detector
                clause = await self.clause_detector.add_word(word)
                # Clause emission is handled in clause detector's queue

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Error processing words: {e}")

    async def _process_clauses(self) -> None:
        """Process clauses from detector through classifier, translator, and TTS."""
        try:
            while self._is_running:
                # Get clause from detector
                try:
                    clause = await asyncio.wait_for(
                        self.clause_detector.clause_queue.get(),
                        timeout=0.1,
                    )
                except asyncio.TimeoutError:
                    continue

                # Classify the clause
                decision = self.classifier.classify(clause)

                # Emit clause detection event
                if self.on_clause:
                    msg = ClauseDetected(
                        text=clause.text,
                        connector=clause.connector,
                        decision=decision.value,
                    )
                    self.on_clause(msg)

                if decision == ClassifierDecision.WAIT:
                    # Return clause to buffer and wait for more context
                    self.clause_detector.return_to_buffer(clause)
                    continue

                # SAFE - proceed with translation
                await self._translate_and_speak(clause)

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Error processing clauses: {e}")

    async def _translate_and_speak(self, clause: Clause) -> None:
        """Translate a clause and synthesize speech."""
        start_time = time.time()
        korean_text = clause.text

        try:
            # Translate with streaming
            full_translation = ""
            async for token in self.translator.translate_stream(
                clause,
                self.session_state,
            ):
                full_translation += token

                # Add token to phrase buffer
                phrase = await self.phrase_buffer.add_token(token)
                if phrase:
                    # Synthesize and emit audio
                    await self._synthesize_phrase(phrase)

            # Signal end of translation to phrase buffer
            phrase = await self.phrase_buffer.add_token("")
            if phrase:
                await self._synthesize_phrase(phrase)

            # Emit translation result
            latency_ms = int((time.time() - start_time) * 1000)
            if self.on_translation:
                msg = TranslationText(
                    original=korean_text,
                    translated=full_translation,
                    latency_ms=latency_ms,
                )
                self.on_translation(msg)

        except Exception as e:
            logger.error(f"Error in translate_and_speak: {e}")

    async def _synthesize_phrase(self, phrase: str) -> None:
        """Synthesize a phrase to audio and emit."""
        try:
            async for audio_chunk in self.tts.synthesize_stream(phrase):
                if self.on_audio:
                    msg = AudioOut(data=audio_chunk, format="mp3")
                    self.on_audio(msg)

        except Exception as e:
            logger.error(f"Error synthesizing phrase: {e}")

    async def flush(self) -> None:
        """Force flush all buffers."""
        # Flush clause detector
        clause = await self.clause_detector._flush_buffer("FLUSH")
        if clause:
            decision = self.classifier.classify(clause)
            if decision == ClassifierDecision.SAFE:
                await self._translate_and_speak(clause)

        # Flush phrase buffer
        phrase = await self.phrase_buffer._flush()
        if phrase:
            await self._synthesize_phrase(phrase)

    @property
    def is_running(self) -> bool:
        """Check if the pipeline is running."""
        return self._is_running
