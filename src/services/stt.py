"""Streaming Speech-to-Text service using Deepgram."""

import asyncio
import logging
from typing import AsyncGenerator, Callable, Optional, Literal
from dataclasses import dataclass

from deepgram import DeepgramClient
from deepgram.core.events import EventType

from ..config import get_settings

logger = logging.getLogger(__name__)


@dataclass
class STTResult:
    """Result from STT processing."""
    text: str
    is_final: bool
    confidence: float = 1.0
    timestamp_ms: int = 0
    is_utterance_end: bool = False  # True when Deepgram detects end of utterance


class STTService:
    """Streaming STT service using Deepgram for Korean and English."""

    def __init__(
        self,
        language: Literal["ko", "en"],
        on_result: Optional[Callable[[STTResult], None]] = None,
    ):
        """
        Initialize STT service.

        Args:
            language: Language to transcribe ("ko" or "en").
            on_result: Callback for transcription results.
        """
        self.settings = get_settings()
        self.language = language
        self.on_result = on_result
        self._client: Optional[DeepgramClient] = None
        self._context_manager = None
        self._connection = None
        self._is_connected = False
        self._is_ready = False  # True after connect() called, ready for lazy connection
        self._result_queue: asyncio.Queue[STTResult] = asyncio.Queue()
        self._loop: Optional[asyncio.AbstractEventLoop] = None

    async def connect(self) -> None:
        """Mark STT as ready. Actual Deepgram connection happens on first audio."""
        if self._is_ready:
            logger.warning(f"STT ({self.language}) already ready")
            return

        self._client = DeepgramClient(api_key=self.settings.deepgram_api_key)
        self._loop = asyncio.get_event_loop()
        self._is_ready = True
        logger.info(f"STT ({self.language}) ready (lazy connection mode)")

    def _ensure_connected(self, first_audio: bytes = None) -> bool:
        """Lazily establish Deepgram connection on first audio. Returns True if connected."""
        if self._is_connected:
            return True

        if not self._is_ready or not self._client:
            logger.warning(f"STT ({self.language}) not ready")
            return False

        try:
            # Map internal language codes to Deepgram codes
            deepgram_language = "ko" if self.language == "ko" else self.language

            # Use the v1 connect API with VAD configuration
            self._context_manager = self._client.listen.v1.connect(
                model="nova-2",
                language=deepgram_language,
                encoding="linear16",
                sample_rate=str(self.settings.sample_rate),
                channels="1",
                punctuate="true",
                interim_results="true",
                # VAD (Voice Activity Detection) settings
                endpointing="500",           # End speech detection after 500ms silence (increased from 300)
                utterance_end_ms="1500",     # Signal utterance end after 1500ms silence (increased from 1000)
                vad_events="true",           # Get VAD start/stop events
                smart_format="true",
            )

            # Enter context manager to get connection
            self._connection = self._context_manager.__enter__()

            # Register callbacks for events
            self._connection.on(EventType.MESSAGE, self._on_message)
            self._connection.on(EventType.ERROR, self._on_error)
            self._connection.on(EventType.CLOSE, self._on_close)

            # CRITICAL: Send first audio IMMEDIATELY after connection
            # This prevents Deepgram from timing out
            if first_audio and hasattr(self._connection, 'send_media'):
                self._connection.send_media(first_audio)
                logger.debug(f"STT ({self.language}) sent first audio packet")

            # Start listening in background thread
            # Don't wait for it - just start and return
            import threading
            listener_thread = threading.Thread(
                target=self._run_listener,
                daemon=True
            )
            listener_thread.start()

            logger.info(
                f"STT ({self.language}) configured with VAD: "
                f"endpointing=300ms, utterance_end=1000ms"
            )

            self._is_connected = True
            logger.info(f"STT ({self.language}) connected to Deepgram")
            return True

        except Exception as e:
            logger.error(f"Failed to connect STT ({self.language}): {e}")
            return False

    def _run_listener(self) -> None:
        """Run the Deepgram listener loop in a background thread."""
        try:
            for response in self._connection:
                if not self._is_connected:
                    break
                self._on_message(response)
        except Exception as e:
            logger.error(f"STT ({self.language}) listener error: {e}")

    def _on_message(self, result) -> None:
        """Handle incoming message from Deepgram (runs in listener thread)."""
        try:
            # Get response type for VAD event handling
            response_type = getattr(result, 'type', None)

            # Handle VAD events
            if response_type == 'SpeechStarted':
                logger.debug(f"STT ({self.language}) VAD: Speech started")
                return

            if response_type == 'UtteranceEnd':
                logger.info(f"STT ({self.language}) VAD: Utterance ended")
                # Send an utterance end marker to trigger pipeline flush
                utterance_end_result = STTResult(
                    text="",
                    is_final=True,
                    is_utterance_end=True,
                )
                self._queue_result(utterance_end_result)
                return

            # Parse transcription results
            if hasattr(result, 'channel'):
                channel = result.channel
                if hasattr(channel, 'alternatives') and channel.alternatives:
                    alt = channel.alternatives[0]
                    transcript = getattr(alt, 'transcript', '')

                    # Only process if there's actual transcription text
                    if transcript:
                        is_final = getattr(result, 'is_final', True)
                        confidence = getattr(alt, 'confidence', 1.0)

                        # Get timestamp from first word if available
                        timestamp_ms = 0
                        words = getattr(alt, 'words', [])
                        if words and len(words) > 0:
                            timestamp_ms = int(getattr(words[0], 'start', 0) * 1000)

                        stt_result = STTResult(
                            text=transcript,
                            is_final=is_final,
                            confidence=confidence,
                            timestamp_ms=timestamp_ms,
                            is_utterance_end=False,
                        )

                        self._queue_result(stt_result)

                        log_level = logging.DEBUG if not is_final else logging.INFO
                        logger.log(
                            log_level,
                            f"STT ({self.language}) {'final' if is_final else 'interim'}: {transcript}"
                        )

        except Exception as e:
            logger.error(f"Error processing response: {e}")

    def _queue_result(self, result: STTResult) -> None:
        """Thread-safe method to queue a result."""
        if self._loop and self._loop.is_running():
            # Schedule the coroutine from a different thread
            asyncio.run_coroutine_threadsafe(
                self._async_queue_result(result),
                self._loop
            )
        if self.on_result:
            self.on_result(result)

    async def _async_queue_result(self, result: STTResult) -> None:
        """Async method to put result in queue."""
        await self._result_queue.put(result)

    def _on_error(self, error) -> None:
        """Handle error from Deepgram."""
        logger.error(f"STT ({self.language}) Deepgram error: {error}")

    def _on_close(self, close_msg) -> None:
        """Handle connection close from Deepgram."""
        logger.info(f"STT ({self.language}) Deepgram connection closed: {close_msg}")

    async def send_audio(self, audio_data: bytes) -> None:
        """
        Send audio data to Deepgram.

        Args:
            audio_data: Raw audio bytes (PCM 16-bit, 16kHz, mono).
        """
        # Lazy connection - establish on first audio and send it immediately
        if not self._is_connected:
            if not self._ensure_connected(first_audio=audio_data):
                logger.warning(f"Cannot send audio ({self.language}): connection failed")
                return
            # First audio was already sent during connection
            return

        if not self._connection:
            return

        try:
            # Use send_media for the Deepgram SDK v5.x
            if hasattr(self._connection, 'send_media'):
                self._connection.send_media(audio_data)
            elif hasattr(self._connection, 'send'):
                self._connection.send(audio_data)
        except Exception as e:
            logger.error(f"Error sending audio ({self.language}): {e}")

    async def get_results(self) -> AsyncGenerator[STTResult, None]:
        """
        Async generator that yields transcription results.

        Yields:
            STTResult objects as they are received.
        """
        while True:
            try:
                result = await self._result_queue.get()
                yield result
            except asyncio.CancelledError:
                break

    async def finalize(self) -> None:
        """
        Signal end of audio stream to get final transcripts.

        Call this when audio input ends to ensure Deepgram returns
        any pending final transcripts before disconnecting.
        """
        if not self._connection:
            return

        try:
            # Send finalize/finish signal to Deepgram
            if hasattr(self._connection, 'finish'):
                self._connection.finish()
                logger.info(f"STT ({self.language}) finalize signal sent")
                # Wait a bit for final results to arrive
                await asyncio.sleep(0.5)
        except Exception as e:
            logger.error(f"Error finalizing STT ({self.language}): {e}")

    async def disconnect(self) -> None:
        """Close the Deepgram connection."""
        self._is_connected = False
        self._is_ready = False

        if self._context_manager:
            try:
                # Exit the context manager to properly close the connection
                self._context_manager.__exit__(None, None, None)
            except Exception as e:
                logger.error(f"Error closing Deepgram ({self.language}): {e}")
            finally:
                self._connection = None
                self._context_manager = None
                self._loop = None
                self._client = None
                logger.info(f"STT ({self.language}) disconnected")

    @property
    def is_connected(self) -> bool:
        """Check if connected to Deepgram."""
        return self._is_connected

    @property
    def result_queue(self) -> asyncio.Queue[STTResult]:
        """Get the result queue for external consumption."""
        return self._result_queue
