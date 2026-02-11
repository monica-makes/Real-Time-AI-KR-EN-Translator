"""Streaming Speech-to-Text service using Deepgram."""

import asyncio
import logging
from typing import AsyncGenerator, Callable, Optional
from deepgram import (
    DeepgramClient,
    DeepgramClientOptions,
    LiveTranscriptionEvents,
    LiveOptions,
)

from ..config import get_settings
from ..models import Word

logger = logging.getLogger(__name__)


class STTService:
    """Streaming STT service using Deepgram for Korean transcription."""

    def __init__(
        self,
        on_word: Optional[Callable[[Word], None]] = None,
        on_interim: Optional[Callable[[str], None]] = None,
    ):
        """
        Initialize STT service.

        Args:
            on_word: Callback for confirmed words (final results)
            on_interim: Callback for interim results (UI feedback)
        """
        self.settings = get_settings()
        self.on_word = on_word
        self.on_interim = on_interim
        self._client: Optional[DeepgramClient] = None
        self._connection = None
        self._is_connected = False
        self._word_queue: asyncio.Queue[Word] = asyncio.Queue()

    async def connect(self) -> None:
        """Establish streaming connection to Deepgram."""
        if self._is_connected:
            logger.warning("STT already connected")
            return

        try:
            # Configure Deepgram client
            config = DeepgramClientOptions(
                options={"keepalive": "true"}
            )
            self._client = DeepgramClient(
                self.settings.deepgram_api_key,
                config
            )

            # Configure live transcription options for Korean
            options = LiveOptions(
                model="nova-2",
                language="ko",  # Korean
                encoding="linear16",
                sample_rate=self.settings.sample_rate,
                channels=1,
                punctuate=True,
                interim_results=True,
                endpointing=300,  # ms of silence to end utterance
                smart_format=True,
            )

            # Create live connection
            self._connection = self._client.listen.asynclive.v("1")

            # Set up event handlers
            self._connection.on(LiveTranscriptionEvents.Open, self._on_open)
            self._connection.on(LiveTranscriptionEvents.Transcript, self._on_transcript)
            self._connection.on(LiveTranscriptionEvents.Error, self._on_error)
            self._connection.on(LiveTranscriptionEvents.Close, self._on_close)

            # Start the connection
            if await self._connection.start(options):
                self._is_connected = True
                logger.info("STT connected to Deepgram")
            else:
                raise ConnectionError("Failed to start Deepgram connection")

        except Exception as e:
            logger.error(f"Failed to connect to Deepgram: {e}")
            raise

    async def _on_open(self, *args, **kwargs) -> None:
        """Handle connection open event."""
        logger.info("Deepgram connection opened")

    async def _on_transcript(self, *args, **kwargs) -> None:
        """Handle incoming transcript from Deepgram."""
        try:
            result = kwargs.get("result") or (args[1] if len(args) > 1 else None)
            if not result:
                return

            # Get the transcript
            channel = result.channel
            alternatives = channel.alternatives
            if not alternatives:
                return

            transcript = alternatives[0].transcript
            if not transcript:
                return

            is_final = result.is_final
            words = alternatives[0].words

            if is_final and words:
                # Process each word from final result
                for word_info in words:
                    word = Word(
                        text=word_info.word,
                        confidence=word_info.confidence,
                        is_final=True,
                        timestamp_ms=int(word_info.start * 1000),
                    )
                    await self._word_queue.put(word)
                    if self.on_word:
                        self.on_word(word)
                logger.debug(f"Final transcript: {transcript}")
            elif not is_final and self.on_interim:
                # Send interim result for UI feedback
                self.on_interim(transcript)
                logger.debug(f"Interim transcript: {transcript}")

        except Exception as e:
            logger.error(f"Error processing transcript: {e}")

    async def _on_error(self, *args, **kwargs) -> None:
        """Handle error event."""
        error = kwargs.get("error") or (args[1] if len(args) > 1 else "Unknown error")
        logger.error(f"Deepgram error: {error}")

    async def _on_close(self, *args, **kwargs) -> None:
        """Handle connection close event."""
        logger.info("Deepgram connection closed")
        self._is_connected = False

    async def send_audio(self, audio_data: bytes) -> None:
        """
        Send audio data to Deepgram for transcription.

        Args:
            audio_data: Raw audio bytes (PCM 16-bit, 16kHz, mono)
        """
        if not self._is_connected or not self._connection:
            logger.warning("Cannot send audio: not connected")
            return

        try:
            await self._connection.send(audio_data)
        except Exception as e:
            logger.error(f"Error sending audio: {e}")

    async def get_words(self) -> AsyncGenerator[Word, None]:
        """
        Async generator that yields confirmed words.

        Yields:
            Word objects as they are confirmed by Deepgram.
        """
        while True:
            try:
                word = await self._word_queue.get()
                yield word
            except asyncio.CancelledError:
                break

    async def disconnect(self) -> None:
        """Close the Deepgram connection."""
        if self._connection and self._is_connected:
            try:
                await self._connection.finish()
            except Exception as e:
                logger.error(f"Error closing Deepgram connection: {e}")
            finally:
                self._is_connected = False
                self._connection = None
                logger.info("STT disconnected")

    @property
    def is_connected(self) -> bool:
        """Check if connected to Deepgram."""
        return self._is_connected

    @property
    def word_queue(self) -> asyncio.Queue[Word]:
        """Get the word queue for external consumption."""
        return self._word_queue
