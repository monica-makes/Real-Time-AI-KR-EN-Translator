"""English sentence boundary detection."""

import logging
from typing import Optional, List

from ...config import get_settings

logger = logging.getLogger(__name__)


class EnglishSentenceDetector:
    """
    Simple boundary detection for English.
    Much simpler than Korean - punctuation and pauses are sufficient.

    Triggers:
    1. Punctuation (. ! ?) -> immediate boundary
    2. Pause > 500ms -> boundary
    3. Timeout > 3s -> force boundary
    4. Buffer overflow -> force boundary
    """

    PUNCTUATION_BOUNDARIES = [".", "!", "?"]

    def __init__(
        self,
        pause_threshold_ms: Optional[int] = None,
        timeout_ms: Optional[int] = None,
        max_buffer_words: Optional[int] = None,
    ):
        """
        Initialize sentence detector.

        Args:
            pause_threshold_ms: Pause threshold for boundary detection.
            timeout_ms: Timeout before forcing flush.
            max_buffer_words: Maximum words before forcing flush.
        """
        settings = get_settings()
        self.pause_threshold_ms = pause_threshold_ms or settings.en_pause_threshold_ms
        self.timeout_ms = timeout_ms or settings.en_timeout_ms
        self.max_buffer_words = max_buffer_words or settings.en_max_buffer_words

        self._buffer: List[str] = []
        self._buffer_start_time: Optional[int] = None
        self._last_word_time: Optional[int] = None

    def add_word(self, word: str, timestamp_ms: int) -> Optional[str]:
        """
        Add word, return complete sentence if boundary detected.

        Args:
            word: The word to add.
            timestamp_ms: Timestamp of the word.

        Returns:
            Complete sentence if boundary detected, None otherwise.
        """
        if not word.strip():
            return None

        # Initialize timing
        if self._buffer_start_time is None:
            self._buffer_start_time = timestamp_ms

        # Check pause before adding
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

        # Check punctuation
        word_stripped = word.rstrip()
        if any(word_stripped.endswith(p) for p in self.PUNCTUATION_BOUNDARIES):
            return self._flush("punctuation")

        # Check timeout
        if timestamp_ms - self._buffer_start_time > self.timeout_ms:
            return self._flush("timeout")

        # Check buffer size
        if len(self._buffer) >= self.max_buffer_words:
            return self._flush("overflow")

        return None

    def _flush(self, trigger: str) -> str:
        """Flush the buffer and return the sentence."""
        sentence = " ".join(self._buffer)
        self._buffer = []
        self._buffer_start_time = None

        logger.debug(f"Sentence detected ({trigger}): '{sentence}'")
        return sentence

    def force_flush(self) -> Optional[str]:
        """Force flush the buffer."""
        if self._buffer:
            return self._flush("force")
        return None

    @property
    def current_buffer(self) -> str:
        """Get current buffer content."""
        return " ".join(self._buffer)

    def clear(self) -> None:
        """Clear the buffer."""
        self._buffer = []
        self._buffer_start_time = None
        self._last_word_time = None
