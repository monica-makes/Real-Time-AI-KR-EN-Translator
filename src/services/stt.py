"""Streaming Speech-to-Text service using Deepgram."""

import asyncio
import logging
import threading
import time
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
    speech_final: bool = False  # True when Deepgram endpointed the speech or answered a Finalize
    last_word_end_ms: Optional[int] = None  # UtteranceEnd only: end of the utterance's last word


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

        # Connection state is shared between the event loop (send_audio) and the
        # listener thread, so transitions happen under _state_lock. Each Deepgram
        # connection gets a new generation so a stale listener can't tear down a newer one.
        self._state_lock = threading.Lock()
        self._connect_lock = asyncio.Lock()  # Serializes lazy (re)connects on the event loop
        self._generation = 0

        # KeepAlive: Deepgram closes the stream after ~10s without audio (NET-0001)
        self.keepalive_idle_s = 4.0             # Start keepalives after this much silence
        self.keepalive_interval_s = 4.0         # Time between keepalives
        self.keepalive_max_silence_s = 300.0    # Stop after 5 min of silence; next audio reconnects
        self.keepalive_check_interval_s = 1.0
        self.finalize_wait_s = 0.5              # Time to wait for trailing results after finalize
        # Mic paused mid-utterance: Deepgram needs more audio to endpoint, so ask it to finalize
        self.idle_finalize_s = 1.5
        self._keepalive_task: Optional[asyncio.Task] = None
        self._last_audio_time = 0.0
        self._last_keepalive_time = 0.0
        self._idle_finalized_for = 0.0          # _last_audio_time the idle Finalize was sent for

        # Reconnect backoff: the first retry after a failure is immediate, repeated
        # failures (handshake errors, streams closed right after opening) back off
        self.reconnect_backoff_initial_s = 1.0
        self.reconnect_backoff_max_s = 10.0
        self.reconnect_stable_s = 10.0          # A connection that lived this long resets the backoff
        self._connect_failures = 0
        self._next_connect_at = 0.0
        self._connected_at = 0.0

    async def connect(self) -> None:
        """Mark STT as ready. Actual Deepgram connection happens on first audio."""
        if self._is_ready:
            logger.warning(f"STT ({self.language}) already ready")
            return

        self._client = DeepgramClient(api_key=self.settings.deepgram_api_key)
        self._loop = asyncio.get_event_loop()
        self._connect_failures = 0
        self._next_connect_at = 0.0
        self._is_ready = True
        self._keepalive_task = asyncio.create_task(self._keepalive_loop())
        logger.info(f"STT ({self.language}) ready (lazy connection mode)")

    def _ensure_connected(self, first_audio: bytes = None) -> bool:
        """Lazily establish Deepgram connection on first audio. Returns True if connected.

        Blocks during the Deepgram handshake, so send_audio runs it in a worker thread.
        """
        with self._state_lock:
            if self._is_connected:
                return True

            if not self._is_ready or not self._client:
                logger.warning(f"STT ({self.language}) not ready")
                return False

            client = self._client

        context_manager = None
        connection = None
        try:
            # Map internal language codes to Deepgram codes
            deepgram_language = "ko" if self.language == "ko" else self.language

            # Use the v1 connect API with VAD configuration
            context_manager = client.listen.v1.connect(
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
            connection = context_manager.__enter__()

            # Register callbacks for events
            connection.on(EventType.MESSAGE, self._on_message)
            connection.on(EventType.ERROR, self._on_error)
            connection.on(EventType.CLOSE, self._on_close)

            # CRITICAL: Send first audio IMMEDIATELY after connection
            # This prevents Deepgram from timing out
            if first_audio and hasattr(connection, 'send_media'):
                connection.send_media(first_audio)
                logger.debug(f"STT ({self.language}) sent first audio packet")

        except Exception as e:
            logger.error(f"Failed to connect STT ({self.language}): {e}")
            if connection is not None:
                self._close_context_manager(context_manager)
            with self._state_lock:
                self._record_connect_failure()
            return False

        with self._state_lock:
            if not self._is_ready:
                # disconnect() ran during the handshake - drop this connection
                stale = True
            else:
                stale = False
                self._generation += 1
                generation = self._generation
                self._context_manager = context_manager
                self._connection = connection
                self._is_connected = True
                self._connected_at = time.monotonic()
                self._last_audio_time = self._connected_at
                self._last_keepalive_time = 0.0

        if stale:
            self._close_context_manager(context_manager)
            return False

        # Start listening in background thread
        # Don't wait for it - just start and return
        listener_thread = threading.Thread(
            target=self._run_listener,
            args=(connection, generation),
            name=f"stt-listener-{self.language}-{generation}",
            daemon=True
        )
        listener_thread.start()

        logger.info(
            f"STT ({self.language}) configured with VAD: "
            f"endpointing=500ms, utterance_end=1500ms"
        )
        logger.info(f"STT ({self.language}) connected to Deepgram")
        return True

    def _run_listener(self, connection, generation: int) -> None:
        """Run the Deepgram listener loop in a background thread."""
        reason = "stream ended"
        try:
            for response in connection:
                if generation != self._generation:
                    break
                self._on_message(response)
        except Exception as e:
            # Logged once by _drop_connection if this is still the live connection
            reason = f"listener error: {e}"
        finally:
            # Deepgram closed the stream (e.g. 1011/NET-0001 after ~10s without audio).
            # Mark disconnected so the next send_audio reconnects.
            self._close_context_manager(self._drop_connection(generation, reason))

    def _drop_connection(self, generation: int, reason: str):
        """
        Mark the connection for `generation` as dead if it is still the current one.

        Returns the context manager the caller must close, or None if the
        connection was already dropped or replaced by a newer one.
        """
        with self._state_lock:
            if generation != self._generation or not self._is_connected:
                return None
            self._is_connected = False
            context_manager = self._context_manager
            self._context_manager = None
            self._connection = None

            # A long-lived stream closing (e.g. idle timeout) is normal; one that
            # dies right after opening counts towards the reconnect backoff
            if time.monotonic() - self._connected_at >= self.reconnect_stable_s:
                self._connect_failures = 0
            self._record_connect_failure()

        logger.warning(
            f"STT ({self.language}) Deepgram connection lost ({reason}); "
            f"will reconnect on next audio"
        )
        return context_manager

    def _record_connect_failure(self) -> None:
        """Schedule the next connect attempt after a failure. Caller holds _state_lock."""
        self._connect_failures += 1
        if self._connect_failures <= 1:
            delay = 0.0
        else:
            delay = min(
                self.reconnect_backoff_max_s,
                self.reconnect_backoff_initial_s * 2 ** (self._connect_failures - 2),
            )
        self._next_connect_at = time.monotonic() + delay
        if delay > 0:
            logger.warning(
                f"STT ({self.language}) {self._connect_failures} connection failures in a row, "
                f"retrying in {delay:.1f}s"
            )

    def _close_context_manager(self, context_manager) -> None:
        """Exit a Deepgram connection context manager, ignoring errors."""
        if context_manager is None:
            return
        try:
            context_manager.__exit__(None, None, None)
        except Exception as e:
            logger.debug(f"STT ({self.language}) error closing stale connection: {e}")

    def _close_in_background(self, context_manager) -> None:
        """Close a dropped connection without blocking the event loop."""
        if context_manager is None:
            return
        asyncio.get_running_loop().run_in_executor(
            None, self._close_context_manager, context_manager
        )

    async def _keepalive_loop(self) -> None:
        """Send KeepAlive while connected but silent so Deepgram keeps the stream open.

        Also sends one Finalize when audio stops (mic paused) so the last words
        come back as a final instead of waiting for audio that isn't coming.
        """
        silence_logged = False
        try:
            while self._is_ready:
                await asyncio.sleep(self.keepalive_check_interval_s)

                with self._state_lock:
                    connection = self._connection if self._is_connected else None
                    generation = self._generation
                if connection is None:
                    continue

                now = time.monotonic()
                last_audio_time = self._last_audio_time
                idle_s = now - last_audio_time

                if (
                    idle_s >= self.idle_finalize_s
                    and self._idle_finalized_for != last_audio_time
                    and hasattr(connection, 'send_finalize')
                ):
                    self._idle_finalized_for = last_audio_time
                    try:
                        await asyncio.to_thread(connection.send_finalize)
                        logger.debug(
                            f"STT ({self.language}) Finalize sent after {idle_s:.1f}s without audio"
                        )
                    except Exception as e:
                        self._close_in_background(
                            self._drop_connection(generation, f"Finalize failed: {e}")
                        )
                        continue

                if not hasattr(connection, 'send_keep_alive'):
                    continue

                if idle_s < self.keepalive_idle_s:
                    silence_logged = False
                    continue

                if idle_s >= self.keepalive_max_silence_s:
                    # Long silence: let Deepgram close the stream, next audio reconnects
                    if not silence_logged:
                        logger.info(
                            f"STT ({self.language}) silent for {idle_s:.0f}s, stopping KeepAlive"
                        )
                        silence_logged = True
                    continue

                if now - self._last_keepalive_time < self.keepalive_interval_s:
                    continue

                try:
                    await asyncio.to_thread(connection.send_keep_alive)
                    self._last_keepalive_time = time.monotonic()
                    logger.debug(f"STT ({self.language}) KeepAlive sent (idle {idle_s:.1f}s)")
                except Exception as e:
                    self._close_in_background(
                        self._drop_connection(generation, f"KeepAlive failed: {e}")
                    )
        except asyncio.CancelledError:
            pass

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
                last_word_end = getattr(result, 'last_word_end', None)
                utterance_end_result = STTResult(
                    text="",
                    is_final=True,
                    is_utterance_end=True,
                    last_word_end_ms=(
                        int(last_word_end * 1000) if last_word_end is not None else None
                    ),
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
                        # End of speech: endpointing fired, or this answers a Finalize
                        speech_final = bool(
                            is_final and (
                                getattr(result, 'speech_final', False)
                                or getattr(result, 'from_finalize', False)
                            )
                        )

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
                            speech_final=speech_final,
                        )

                        self._queue_result(stt_result)

                        log_level = logging.DEBUG if not is_final else logging.INFO
                        logger.log(
                            log_level,
                            f"STT ({self.language}) {'final' if is_final else 'interim'}"
                            f"{' (end of speech)' if speech_final else ''}: {transcript}"
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
        # Lazy connection - establish on first audio (or after Deepgram dropped
        # the stream) and send it immediately
        if not self._is_connected:
            if time.monotonic() < self._next_connect_at:
                # Backing off after repeated failures; drop the chunk (logged when scheduled)
                return
            async with self._connect_lock:
                if not self._is_connected:
                    if time.monotonic() < self._next_connect_at:
                        return
                    # Handshake blocks, so run it off the event loop
                    if not await asyncio.to_thread(self._ensure_connected, first_audio=audio_data):
                        logger.warning(f"Cannot send audio ({self.language}): connection failed")
                        return
                    # First audio was already sent during connection
                    return

        with self._state_lock:
            connection = self._connection
            generation = self._generation
        if not connection:
            return

        try:
            # Use send_media for the Deepgram SDK v5.x
            if hasattr(connection, 'send_media'):
                connection.send_media(audio_data)
            elif hasattr(connection, 'send'):
                connection.send(audio_data)
            self._last_audio_time = time.monotonic()
        except Exception as e:
            # Treat the stream as dead so the next chunk reconnects
            self._close_in_background(
                self._drop_connection(generation, f"send failed: {e}")
            )

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
        with self._state_lock:
            connection = self._connection if self._is_connected else None
        if not connection:
            return

        try:
            # Ask Deepgram to flush buffered audio as final transcripts
            # (deepgram-sdk 7.x: send_finalize, older SDKs: finish)
            if hasattr(connection, 'send_finalize'):
                connection.send_finalize()
            elif hasattr(connection, 'finish'):
                connection.finish()
            else:
                return
            logger.info(f"STT ({self.language}) finalize signal sent")
            # Wait a bit for final results to arrive
            await asyncio.sleep(self.finalize_wait_s)
        except Exception as e:
            logger.error(f"Error finalizing STT ({self.language}): {e}")

    async def disconnect(self) -> None:
        """Close the Deepgram connection."""
        with self._state_lock:
            # New generation so the listener doesn't treat this close as a dropped stream
            self._generation += 1
            self._is_connected = False
            self._is_ready = False
            context_manager = self._context_manager
            self._context_manager = None
            self._connection = None

        if self._keepalive_task:
            self._keepalive_task.cancel()
            try:
                await self._keepalive_task
            except asyncio.CancelledError:
                pass
            self._keepalive_task = None

        if context_manager:
            try:
                # Exit the context manager to properly close the connection
                await asyncio.to_thread(context_manager.__exit__, None, None, None)
            except Exception as e:
                logger.error(f"Error closing Deepgram ({self.language}): {e}")
            finally:
                logger.info(f"STT ({self.language}) disconnected")

        self._loop = None
        self._client = None

    @property
    def is_connected(self) -> bool:
        """Check if connected to Deepgram."""
        return self._is_connected

    @property
    def result_queue(self) -> asyncio.Queue[STTResult]:
        """Get the result queue for external consumption."""
        return self._result_queue
