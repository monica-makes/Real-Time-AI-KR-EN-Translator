"""Korean clause boundary detection."""

import logging
from typing import Optional, List

from ...config import get_settings
from ...models import ClauseResult
from ...korean import (
    SENTENCE_FINAL,
    QUESTION_MARKERS,
    CLAUSE_CONNECTORS,
    MODIFIERS,
)

logger = logging.getLogger(__name__)


class KoreanClauseDetector:
    """
    Detects translatable clause boundaries in Korean speech.

    Triggers:
    1. Sentence-final endings (요, 다, 습니다) -> high confidence
    2. Clause connectors (고, 면, 서) -> send to classifier
    3. Modifiers (는, 은) -> send to classifier (will WAIT)
    4. Pause > 300ms -> flush with pause trigger
    5. Timeout > 3s -> force flush
    6. Buffer overflow -> force flush
    """

    def __init__(
        self,
        pause_threshold_ms: Optional[int] = None,
        timeout_ms: Optional[int] = None,
        max_buffer_chars: Optional[int] = None,
    ):
        """
        Initialize clause detector.

        Args:
            pause_threshold_ms: Pause threshold for boundary detection.
            timeout_ms: Timeout before forcing flush.
            max_buffer_chars: Maximum buffer size before forcing flush.
        """
        settings = get_settings()
        self.pause_threshold_ms = pause_threshold_ms or settings.ko_pause_threshold_ms
        self.timeout_ms = timeout_ms or settings.ko_clause_timeout_ms
        self.max_buffer_chars = max_buffer_chars or settings.ko_max_buffer_chars

        self._buffer: List[str] = []
        self._buffer_start_time: Optional[int] = None
        self._last_word_time: Optional[int] = None

    def add_word(self, word: str, timestamp_ms: int) -> Optional[ClauseResult]:
        """
        Add word to buffer, return ClauseResult if boundary detected.

        Args:
            word: The word to add.
            timestamp_ms: Timestamp of the word.

        Returns:
            ClauseResult if boundary detected, None otherwise.
        """
        if not word.strip():
            return None

        # Initialize timing
        if self._buffer_start_time is None:
            self._buffer_start_time = timestamp_ms

        # Check pause-based boundary BEFORE adding word
        if self._last_word_time is not None:
            pause = timestamp_ms - self._last_word_time
            if pause > self.pause_threshold_ms and self._buffer:
                result = self._flush("pause")
                self._buffer.append(word)
                self._buffer_start_time = timestamp_ms
                self._last_word_time = timestamp_ms
                return result

        self._buffer.append(word)
        self._last_word_time = timestamp_ms

        current_text = "".join(self._buffer)

        # Check sentence-final endings (highest priority)
        for ending in sorted(SENTENCE_FINAL, key=len, reverse=True):
            if current_text.endswith(ending):
                return self._flush("sentence_end", ending)

        # Check question markers
        for marker in sorted(QUESTION_MARKERS, key=len, reverse=True):
            if current_text.endswith(marker):
                return self._flush("sentence_end", marker)

        # Check modifiers (will likely WAIT)
        for modifier in sorted(MODIFIERS, key=len, reverse=True):
            if current_text.endswith(modifier):
                return self._flush("connector", modifier)

        # Check clause connectors
        for connector in sorted(CLAUSE_CONNECTORS, key=len, reverse=True):
            if current_text.endswith(connector):
                return self._flush("connector", connector)

        # Check timeout
        if timestamp_ms - self._buffer_start_time > self.timeout_ms:
            return self._flush("timeout")

        # Check buffer size
        if len(current_text) > self.max_buffer_chars:
            return self._flush("overflow")

        return None

    def _flush(
        self,
        trigger: str,
        connector: Optional[str] = None,
    ) -> ClauseResult:
        """Flush the buffer and return a clause result (words keep their spacing)."""
        clause = " ".join(self._buffer)
        self._buffer = []
        self._buffer_start_time = None

        logger.debug(
            f"Clause detected: '{clause}' (trigger={trigger}, connector={connector})"
        )

        return ClauseResult(
            text=clause,
            connector=connector,
            trigger=trigger,
        )

    def force_flush(self) -> Optional[ClauseResult]:
        """Force flush the buffer."""
        if self._buffer:
            return self._flush("force")
        return None

    def return_to_buffer(self, clause: ClauseResult) -> None:
        """
        Return a clause back to the buffer (when classifier says WAIT).

        Args:
            clause: The clause to return.
        """
        if clause.text:
            # Prepend the clause text back to buffer
            words = clause.text.split()
            self._buffer = words + self._buffer
            logger.debug(f"Returned to buffer: '{clause.text}'")

    @property
    def current_buffer(self) -> str:
        """Get current buffer content, without spaces (what the ending checks match against)."""
        return "".join(self._buffer)

    @property
    def pending_text(self) -> str:
        """Words waiting for a clause boundary, spaced as spoken (for live captions)."""
        return " ".join(self._buffer)

    def clear(self) -> None:
        """Clear the buffer."""
        self._buffer = []
        self._buffer_start_time = None
        self._last_word_time = None
