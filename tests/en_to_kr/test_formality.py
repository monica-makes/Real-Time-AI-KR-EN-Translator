"""Tests for Korean formality toggle."""

import pytest
from src.pipelines.en_to_kr.formality import FormalityConfig, HONORIFIC_VERBS


class TestFormalityConfig:
    """Tests for the FormalityConfig class."""

    def test_default_mode(self):
        """Default should be non-honorific (해요체)."""
        config = FormalityConfig()
        assert config.honorific_mode is False

    def test_init_with_honorific(self):
        """Should initialize with honorific mode."""
        config = FormalityConfig(honorific_mode=True)
        assert config.honorific_mode is True

    def test_set_honorific(self):
        """Should set honorific mode."""
        config = FormalityConfig()
        config.set_honorific(True)
        assert config.honorific_mode is True

        config.set_honorific(False)
        assert config.honorific_mode is False

    def test_toggle(self):
        """Should toggle honorific mode."""
        config = FormalityConfig(honorific_mode=False)

        result = config.toggle()
        assert result is True
        assert config.honorific_mode is True

        result = config.toggle()
        assert result is False
        assert config.honorific_mode is False

    def test_property_setter(self):
        """Should set via property."""
        config = FormalityConfig()
        config.honorific_mode = True
        assert config.honorific_mode is True

    def test_style_description(self):
        """Should return correct style description."""
        config = FormalityConfig(honorific_mode=False)
        assert "해요체" in config.get_style_description()

        config.set_honorific(True)
        assert "높임말" in config.get_style_description()


class TestHonorificVerbs:
    """Tests for honorific verb mappings."""

    def test_honorific_verbs_defined(self):
        """Should have honorific verb mappings."""
        assert len(HONORIFIC_VERBS) > 0

    def test_common_honorifics(self):
        """Should include common honorific mappings."""
        assert HONORIFIC_VERBS["먹다"] == "드시다"
        assert HONORIFIC_VERBS["자다"] == "주무시다"
        assert HONORIFIC_VERBS["있다"] == "계시다"
