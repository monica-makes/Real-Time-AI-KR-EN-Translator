"""Tests for English sentence boundary detection."""

import pytest
from src.pipelines.en_to_kr.sentence_detector import EnglishSentenceDetector


class TestEnglishSentenceDetector:
    """Tests for the EnglishSentenceDetector class."""

    @pytest.fixture
    def detector(self):
        """Create a sentence detector for testing."""
        return EnglishSentenceDetector(timeout_ms=10000)

    def test_period_boundary(self, detector):
        """Should detect sentence at period."""
        detector.add_word("I", 0)
        detector.add_word("went", 100)
        detector.add_word("to", 200)
        detector.add_word("the", 300)
        result = detector.add_word("store.", 400)

        assert result is not None
        assert result == "I went to the store."

    def test_question_boundary(self, detector):
        """Should detect sentence at question mark."""
        detector.add_word("Did", 0)
        detector.add_word("you", 100)
        result = detector.add_word("eat?", 200)

        assert result is not None
        assert result == "Did you eat?"

    def test_exclamation_boundary(self, detector):
        """Should detect sentence at exclamation mark."""
        detector.add_word("Hello", 0)
        result = detector.add_word("there!", 100)

        assert result is not None
        assert result == "Hello there!"

    def test_pause_boundary(self, detector):
        """Should detect boundary at pause."""
        detector = EnglishSentenceDetector(pause_threshold_ms=300)

        detector.add_word("Hello", 0)
        # Large pause
        result = detector.add_word("world", 1000)

        # Should have flushed "Hello" due to pause
        assert result is not None
        assert result == "Hello"

    def test_no_boundary_mid_sentence(self, detector):
        """Should not detect boundary mid-sentence."""
        detector.add_word("The", 0)
        result = detector.add_word("quick", 100)
        assert result is None

        result = detector.add_word("brown", 200)
        assert result is None

    def test_force_flush(self, detector):
        """Should force flush remaining content."""
        detector.add_word("Hello", 0)
        detector.add_word("world", 100)

        result = detector.force_flush()
        assert result is not None
        assert result == "Hello world"

    def test_buffer_overflow(self, detector):
        """Should flush on buffer overflow."""
        detector = EnglishSentenceDetector(max_buffer_words=3)

        detector.add_word("One", 0)
        detector.add_word("two", 100)
        result = detector.add_word("three", 200)

        # Should have triggered overflow at 3 words
        assert result is not None


class TestSentenceDetectorEdgeCases:
    """Edge case tests for sentence detector."""

    def test_empty_word(self):
        """Should handle empty words."""
        detector = EnglishSentenceDetector()
        result = detector.add_word("", 0)
        assert result is None
        result = detector.add_word("   ", 100)
        assert result is None

    def test_clear(self):
        """Should clear buffer."""
        detector = EnglishSentenceDetector()
        detector.add_word("test", 0)
        detector.clear()
        assert detector.current_buffer == ""

    def test_current_buffer(self):
        """Should return current buffer content."""
        detector = EnglishSentenceDetector()
        detector.add_word("Hello", 0)
        detector.add_word("world", 100)
        assert detector.current_buffer == "Hello world"
