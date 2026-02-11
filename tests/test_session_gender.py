"""Tests for session gender detection and override functionality."""

import pytest

from src.models import TranslationDirection
from src.session import Session, SessionManager


class TestSessionGender:
    """Tests for session gender properties."""

    def test_default_effective_gender(self):
        """Test that default effective gender is female."""
        manager = SessionManager()
        session = manager.create_session([TranslationDirection.KO_TO_EN])
        assert session.effective_gender == "female"

    def test_detected_gender(self):
        """Test setting detected gender."""
        manager = SessionManager()
        session = manager.create_session([TranslationDirection.KO_TO_EN])

        session.detected_gender = "male"
        assert session.detected_gender == "male"
        assert session.effective_gender == "male"

    def test_gender_override_takes_precedence(self):
        """Test that gender override takes precedence over detected."""
        manager = SessionManager()
        session = manager.create_session([TranslationDirection.KO_TO_EN])

        # Set detected gender
        session.detected_gender = "male"
        assert session.effective_gender == "male"

        # Override with female
        session.gender_override = "female"
        assert session.effective_gender == "female"

    def test_gender_override_can_be_cleared(self):
        """Test that clearing override reverts to detected."""
        manager = SessionManager()
        session = manager.create_session([TranslationDirection.KO_TO_EN])

        session.detected_gender = "male"
        session.gender_override = "female"
        assert session.effective_gender == "female"

        # Clear override
        session.gender_override = None
        assert session.effective_gender == "male"

    def test_effective_gender_fallback_chain(self):
        """Test fallback chain: override > detected > default."""
        manager = SessionManager()
        session = manager.create_session([TranslationDirection.KO_TO_EN])

        # Nothing set - default female
        assert session.effective_gender == "female"
        assert session.detected_gender is None
        assert session.gender_override is None

        # Set detected
        session.detected_gender = "male"
        assert session.effective_gender == "male"

        # Set override
        session.gender_override = "female"
        assert session.effective_gender == "female"

        # Remove override
        session.gender_override = None
        assert session.effective_gender == "male"


class TestSessionGenderWithMultipleDirections:
    """Tests for gender with bidirectional sessions."""

    def test_gender_applies_to_both_directions(self):
        """Test that gender setting applies to both directions."""
        manager = SessionManager()
        session = manager.create_session([
            TranslationDirection.KO_TO_EN,
            TranslationDirection.EN_TO_KO,
        ])

        session.detected_gender = "male"

        # Both directions should use the same gender
        assert session.effective_gender == "male"
        assert session.has_direction(TranslationDirection.KO_TO_EN)
        assert session.has_direction(TranslationDirection.EN_TO_KO)
