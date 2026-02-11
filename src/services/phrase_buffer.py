"""Phrase buffer for natural TTS output."""

import time
import logging
from typing import Optional, List

from ..config import get_settings

logger = logging.getLogger(__name__)


class PhraseBuffer:
    """
    Buffers streaming tokens until natural phrase breaks.
    Prevents choppy word-by-word TTS output.
    """

    BREAK_CHARS = [",", ".", "!", "?", ":", ";"]

    def __init__(
        self,
        min_chars: Optional[int] = None,
        max_buffer_ms: Optional[int] = None,
    ):
        """
        Initialize phrase buffer.

        Args:
            min_chars: Minimum characters before releasing a phrase.
            max_buffer_ms: Maximum time to buffer before forcing release.
        """
        settings = get_settings()
        self.min_chars = min_chars or settings.phrase_min_chars
        self.max_buffer_ms = max_buffer_ms or settings.phrase_max_buffer_ms

        self._buffer: List[str] = []
        self._buffer_start: Optional[float] = None

    def add_token(self, token: str) -> Optional[str]:
        """
        Add a token to the buffer.

        Args:
            token: The token to add.

        Returns:
            Phrase if ready to release, None otherwise.
        """
        if self._buffer_start is None:
            self._buffer_start = time.time()

        self._buffer.append(token)
        current = "".join(self._buffer)

        # Check for natural break
        if any(current.rstrip().endswith(c) for c in self.BREAK_CHARS):
            if len(current) >= self.min_chars:
                return self._flush()

        # Check timeout
        elapsed_ms = (time.time() - self._buffer_start) * 1000
        if elapsed_ms > self.max_buffer_ms:
            if len(current) >= self.min_chars:
                return self._flush()

        return None

    def _flush(self) -> str:
        """Flush the buffer and return the phrase."""
        phrase = "".join(self._buffer)
        self._buffer = []
        self._buffer_start = None
        logger.debug(f"Phrase buffer flushed: '{phrase}'")
        return phrase

    def force_flush(self) -> Optional[str]:
        """Force flush the buffer regardless of conditions."""
        if self._buffer:
            return self._flush()
        return None

    def clear(self) -> None:
        """Clear the buffer without returning content."""
        self._buffer = []
        self._buffer_start = None

    @property
    def current_content(self) -> str:
        """Get current buffer content without flushing."""
        return "".join(self._buffer)

    @property
    def is_empty(self) -> bool:
        """Check if buffer is empty."""
        return len(self._buffer) == 0
