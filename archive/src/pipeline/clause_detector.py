"""Korean clause boundary detection."""

import asyncio
import logging
import time
from typing import Optional, Callable

from ..config import get_settings
from ..models import Word, Clause
from ..korean import detect_ending

logger = logging.getLogger(__name__)


class ClauseDetector:
    """
    Detects clause boundaries in streaming Korean text.

    Buffers incoming words and detects boundaries using:
    - Sentence-final endings (highest confidence)
    - Question markers
    - Clause connectors (sent to classifier for safety check)
    - Timeout fallback
    - Buffer size safety valve
    """

    def __init__(
        self,
        on_clause: Optional[Callable[[Clause], None]] = None,
        timeout_ms: Optional[int] = None,
        max_buffer_chars: Optional[int] = None,
    ):
        """
        Initialize clause detector.

        Args:
            on_clause: Callback when a clause boundary is detected
            timeout_ms: Timeout before forcing clause detection
            max_buffer_chars: Maximum buffer size before forcing detection
        """
        settings = get_settings()
        self.on_clause = on_clause
        self.timeout_ms = timeout_ms or settings.clause_timeout_ms
        self.max_buffer_chars = max_buffer_chars or settings.max_buffer_chars

        self._buffer: list[str] = []
        self._buffer_text: str = ""
        self._last_word_time: int = 0
        self._clause_queue: asyncio.Queue[Clause] = asyncio.Queue()
        self._timeout_task: Optional[asyncio.Task] = None
        self._is_running: bool = False

    async def start(self) -> None:
        """Start the clause detector."""
        self._is_running = True
        logger.info("Clause detector started")

    async def stop(self) -> None:
        """Stop the clause detector and flush any remaining buffer."""
        self._is_running = False
        if self._timeout_task:
            self._timeout_task.cancel()
            try:
                await self._timeout_task
            except asyncio.CancelledError:
                pass
        # Flush remaining buffer
        await self._flush_buffer("STOP")
        logger.info("Clause detector stopped")

    async def add_word(self, word: Word) -> Optional[Clause]:
        """
        Add a word to the buffer and check for clause boundaries.

        Args:
            word: The word to add

        Returns:
            Clause if boundary detected, None otherwise
        """
        if not self._is_running:
            return None

        self._last_word_time = int(time.time() * 1000)
        self._buffer.append(word.text)
        self._buffer_text = " ".join(self._buffer)

        # Reset timeout task
        if self._timeout_task:
            self._timeout_task.cancel()
        self._timeout_task = asyncio.create_task(self._timeout_handler())

        # Check for clause boundary
        clause = await self._check_boundary()
        return clause

    async def _check_boundary(self) -> Optional[Clause]:
        """Check if current buffer ends with a clause boundary."""
        if not self._buffer_text:
            return None

        # TRIGGER 5: Buffer size safety valve
        if len(self._buffer_text) >= self.max_buffer_chars:
            logger.debug(f"Buffer size limit reached: {len(self._buffer_text)} chars")
            return await self._flush_buffer("BUFFER_LIMIT")

        # Check for grammatical boundaries
        ending = detect_ending(self._buffer_text)
        if ending:
            ending_type, matched_ending = ending
            logger.debug(f"Detected ending: type={ending_type}, match={matched_ending}")

            clause = Clause(
                text=self._buffer_text,
                connector=matched_ending,
                connector_type=ending_type,
            )

            # Clear buffer
            self._buffer = []
            self._buffer_text = ""

            # Emit clause
            await self._emit_clause(clause)
            return clause

        return None

    async def _timeout_handler(self) -> None:
        """Handle timeout - force flush buffer after timeout period."""
        try:
            await asyncio.sleep(self.timeout_ms / 1000)
            if self._buffer_text and self._is_running:
                logger.debug(f"Timeout triggered after {self.timeout_ms}ms")
                await self._flush_buffer("TIMEOUT")
        except asyncio.CancelledError:
            pass

    async def _flush_buffer(self, reason: str) -> Optional[Clause]:
        """
        Force flush the buffer as a clause.

        Args:
            reason: Why the buffer is being flushed

        Returns:
            The flushed clause, or None if buffer was empty
        """
        if not self._buffer_text:
            return None

        clause = Clause(
            text=self._buffer_text,
            connector=reason,
            connector_type="timeout",
        )

        self._buffer = []
        self._buffer_text = ""

        await self._emit_clause(clause)
        return clause

    async def _emit_clause(self, clause: Clause) -> None:
        """Emit a detected clause."""
        await self._clause_queue.put(clause)
        if self.on_clause:
            self.on_clause(clause)
        logger.info(f"Clause detected: '{clause.text}' (connector: {clause.connector})")

    def return_to_buffer(self, clause: Clause) -> None:
        """
        Return a clause back to the buffer (when classifier says WAIT).

        Args:
            clause: The clause to return to buffer
        """
        # Prepend the clause text back to the buffer
        if clause.text:
            words = clause.text.split()
            self._buffer = words + self._buffer
            self._buffer_text = " ".join(self._buffer)
            logger.debug(f"Returned to buffer: '{clause.text}'")

    @property
    def clause_queue(self) -> asyncio.Queue[Clause]:
        """Get the clause queue for external consumption."""
        return self._clause_queue

    @property
    def current_buffer(self) -> str:
        """Get the current buffer contents."""
        return self._buffer_text

    def clear_buffer(self) -> None:
        """Clear the buffer without emitting."""
        self._buffer = []
        self._buffer_text = ""
