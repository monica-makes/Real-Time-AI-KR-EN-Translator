"""Formality toggle for Korean output."""

import logging

logger = logging.getLogger(__name__)


# Honorific verb mappings (for reference/documentation)
HONORIFIC_VERBS = {
    "먹다": "드시다",      # to eat
    "자다": "주무시다",    # to sleep
    "있다": "계시다",      # to be/exist
    "말하다": "말씀하시다", # to speak
    "주다": "드리다",      # to give
    "보다": "뵙다",        # to see/meet
}


class FormalityConfig:
    """
    Binary formality toggle for Korean output (the app's "Honorifics" / 존댓말 card).

    OFF: 반말 (casual, for a friend or peer)
         먹었어?, 자, 있어, 말해, 줘

    ON:  존댓말 (polite speech, for an elder, a stranger or a customer), with
         honorific verb forms: 드세요, 주무세요, 계세요, 말씀하세요, 드려요
    """

    def __init__(self, honorific_mode: bool = False):
        """
        Initialize formality config.

        Args:
            honorific_mode: Whether to use honorific Korean.
        """
        self._honorific_mode = honorific_mode

    @property
    def honorific_mode(self) -> bool:
        """Get current honorific mode."""
        return self._honorific_mode

    @honorific_mode.setter
    def honorific_mode(self, value: bool) -> None:
        """Set honorific mode."""
        self._honorific_mode = value
        logger.info(f"Honorific mode set to: {value}")

    def set_honorific(self, enabled: bool) -> None:
        """
        Set honorific mode.

        Args:
            enabled: Whether to enable honorific mode.
        """
        self.honorific_mode = enabled

    def toggle(self) -> bool:
        """
        Toggle honorific mode.

        Returns:
            New honorific mode state.
        """
        self._honorific_mode = not self._honorific_mode
        logger.info(f"Honorific mode toggled to: {self._honorific_mode}")
        return self._honorific_mode

    def get_style_description(self) -> str:
        """Get description of current style."""
        if self._honorific_mode:
            return "존댓말 (polite, with 높임말 honorific verbs)"
        return "반말 (casual)"
