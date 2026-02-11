"""Phrase buffer for natural TTS output."""

import asyncio
import logging
import time
from typing import Optional, Callable

from ..config import get_settings

logger = logging.getLogger(__name__)

# Patterns that indicate a natural phrase break
PHRASE_BREAK_PATTERNS = [",", ".", "!", "?", " and ", " but ", " or ", ";", ":"]


class PhraseBuffer:
    """
    Buffers translation tokens until natural phrase breaks.

    Prevents choppy word-by-word TTS output by grouping words into
    natural phrases before sending to TTS.

    Example:
        Input tokens: "I" → "went" → "to" → "Seoul" → "yesterday"
        Output phrase: "I went to Seoul yesterday" (one natural unit)
    """

    def __init__(
        self,
        on_phrase: Optional[Callable[[str], None]] = None,
        min_words: Optional[int] = None,
        max_buffer_ms: Optional[int] = None,
    ):
        """
        Initialize phrase buffer.

        Args:
            on_phrase: Callback when a phrase is ready
            min_words: Minimum words before releasing a phrase
            max_buffer_ms: Maximum time to buffer before forcing release
        """
        settings = get_settings()
        self.on_phrase = on_phrase
        self.min_words = min_words or settings.phrase_min_words
        self.max_buffer_ms = max_buffer_ms or settings.phrase_max_buffer_ms

        self._buffer: str = ""
        self._word_count: int = 0
        self._first_token_time: Optional[int] = None
        self._phrase_queue: asyncio.Queue[str] = asyncio.Queue()
        self._timeout_task: Optional[asyncio.Task] = None
        self._is_running: bool = False

    async def start(self) -> None:
        """Start the phrase buffer."""
        self._is_running = True
        logger.info("Phrase buffer started")

    async def stop(self) -> None:
        """Stop the phrase buffer and flush any remaining content."""
        self._is_running = False
        if self._timeout_task:
            self._timeout_task.cancel()
            try:
                await self._timeout_task
            except asyncio.CancelledError:
                pass
        # Flush remaining buffer
        await self._flush()
        logger.info("Phrase buffer stopped")

    async def add_token(self, token: str) -> Optional[str]:
        """
        Add a token to the buffer.

        Args:
            token: The token to add (empty string signals end of translation)

        Returns:
            Phrase if ready to release, None otherwise
        """
        if not self._is_running:
            return None

        # Empty token signals end of translation - flush buffer
        if token == "":
            return await self._flush()

        # Start timing from first token
        if self._first_token_time is None:
            self._first_token_time = int(time.time() * 1000)
            self._start_timeout()

        # Add token to buffer
        self._buffer += token

        # Count words (roughly)
        self._word_count = len(self._buffer.split())

        # Check for phrase break
        return await self._check_phrase_break()

    async def _check_phrase_break(self) -> Optional[str]:
        """Check if we should release the current buffer as a phrase."""
        # Need minimum words first
        if self._word_count < self.min_words:
            return None

        # Check for phrase break patterns
        for pattern in PHRASE_BREAK_PATTERNS:
            if pattern in self._buffer:
                # Find the last occurrence of the pattern
                idx = self._buffer.rfind(pattern)
                if idx > 0:
                    # Release up to and including the pattern
                    phrase = self._buffer[:idx + len(pattern)].strip()
                    self._buffer = self._buffer[idx + len(pattern):].strip()
                    self._word_count = len(self._buffer.split())

                    if phrase:
                        await self._emit_phrase(phrase)
                        return phrase

        return None

    def _start_timeout(self) -> None:
        """Start the timeout timer."""
        if self._timeout_task:
            self._timeout_task.cancel()
        self._timeout_task = asyncio.create_task(self._timeout_handler())

    async def _timeout_handler(self) -> None:
        """Handle timeout - force release buffer."""
        try:
            await asyncio.sleep(self.max_buffer_ms / 1000)
            if self._buffer and self._is_running:
                logger.debug(f"Phrase buffer timeout after {self.max_buffer_ms}ms")
                await self._flush()
        except asyncio.CancelledError:
            pass

    async def _flush(self) -> Optional[str]:
        """Force flush the buffer."""
        if self._timeout_task:
            self._timeout_task.cancel()

        phrase = self._buffer.strip()
        self._buffer = ""
        self._word_count = 0
        self._first_token_time = None

        if phrase:
            await self._emit_phrase(phrase)
            return phrase

        return None

    async def _emit_phrase(self, phrase: str) -> None:
        """Emit a ready phrase."""
        await self._phrase_queue.put(phrase)
        if self.on_phrase:
            self.on_phrase(phrase)
        logger.debug(f"Phrase released: '{phrase}'")

        # Reset timeout for next phrase
        self._first_token_time = None

    @property
    def phrase_queue(self) -> asyncio.Queue[str]:
        """Get the phrase queue for external consumption."""
        return self._phrase_queue

    @property
    def current_buffer(self) -> str:
        """Get the current buffer contents."""
        return self._buffer

    def clear(self) -> None:
        """Clear the buffer without emitting."""
        self._buffer = ""
        self._word_count = 0
        self._first_token_time = None
        if self._timeout_task:
            self._timeout_task.cancel()
