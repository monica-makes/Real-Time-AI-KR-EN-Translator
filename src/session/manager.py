"""Session lifecycle management."""

import uuid
import logging
from typing import Dict, Literal, Optional, List

from ..models import TranslationDirection, SessionConfig
from .context import SharedTranslationContext

logger = logging.getLogger(__name__)


class Session:
    """Represents a single translation session."""

    def __init__(
        self,
        session_id: str,
        config: SessionConfig,
    ):
        """
        Initialize a session.

        Args:
            session_id: Unique session identifier.
            config: Session configuration.
        """
        self.id = session_id
        self.config = config
        self.shared_context = SharedTranslationContext()
        self.is_active = True

    @property
    def honorific_mode(self) -> bool:
        """Get current honorific mode setting."""
        return self.config.honorific_mode

    @honorific_mode.setter
    def honorific_mode(self, value: bool) -> None:
        """Set honorific mode."""
        self.config.honorific_mode = value

    @property
    def active_directions(self) -> List[TranslationDirection]:
        """Get active translation directions."""
        return self.config.active_directions

    def has_direction(self, direction: TranslationDirection) -> bool:
        """Check if a direction is active."""
        return direction in self.config.active_directions

    @property
    def detected_gender(self) -> Optional[Literal["male", "female"]]:
        """Get the detected gender from audio analysis."""
        return self.config.detected_gender

    @detected_gender.setter
    def detected_gender(self, value: Literal["male", "female"]) -> None:
        """Set the detected gender."""
        self.config.detected_gender = value
        logger.info(f"Session {self.id} detected gender: {value}")

    @property
    def gender_override(self) -> Optional[Literal["male", "female"]]:
        """Get the gender override (takes precedence over detected)."""
        return self.config.gender_override

    @gender_override.setter
    def gender_override(self, value: Optional[Literal["male", "female"]]) -> None:
        """Set the gender override."""
        self.config.gender_override = value
        logger.info(f"Session {self.id} gender override: {value}")

    @property
    def effective_gender(self) -> Literal["male", "female"]:
        """Get the effective gender (override > detected > default)."""
        if self.config.gender_override is not None:
            return self.config.gender_override
        if self.config.detected_gender is not None:
            return self.config.detected_gender
        return "female"  # Default to female

    def deactivate(self) -> None:
        """Deactivate the session."""
        self.is_active = False
        logger.info(f"Session {self.id} deactivated")


class SessionManager:
    """Manages multiple translation sessions."""

    def __init__(self):
        """Initialize the session manager."""
        self._sessions: Dict[str, Session] = {}

    def create_session(
        self,
        directions: List[TranslationDirection],
        honorific_mode: bool = False,
    ) -> Session:
        """
        Create a new translation session.

        Args:
            directions: Active translation directions.
            honorific_mode: Whether to use honorific Korean.

        Returns:
            The created session.
        """
        session_id = str(uuid.uuid4())
        config = SessionConfig(
            active_directions=directions,
            honorific_mode=honorific_mode,
        )
        session = Session(session_id=session_id, config=config)
        self._sessions[session_id] = session
        logger.info(
            f"Created session {session_id} with directions={directions}, "
            f"honorific={honorific_mode}"
        )
        return session

    def get_session(self, session_id: str) -> Optional[Session]:
        """
        Get a session by ID.

        Args:
            session_id: The session ID.

        Returns:
            The session if found, None otherwise.
        """
        return self._sessions.get(session_id)

    def end_session(self, session_id: str) -> bool:
        """
        End and remove a session.

        Args:
            session_id: The session ID.

        Returns:
            True if session was found and removed.
        """
        session = self._sessions.pop(session_id, None)
        if session:
            session.deactivate()
            logger.info(f"Ended session {session_id}")
            return True
        return False

    def get_active_sessions(self) -> List[Session]:
        """Get all active sessions."""
        return [s for s in self._sessions.values() if s.is_active]

    @property
    def session_count(self) -> int:
        """Get total number of sessions."""
        return len(self._sessions)
