"""Tests for Korean clause boundary detection."""

import pytest
import asyncio
from src.pipeline.clause_detector import ClauseDetector
from src.models import Word
from src.korean.patterns import detect_ending


class TestDetectEnding:
    """Tests for the detect_ending function."""

    def test_sentence_final_formal(self):
        """Should detect formal sentence endings."""
        assert detect_ending("안녕하세요") == ("sentence_final", "요")
        assert detect_ending("먹었습니다") == ("sentence_final", "습니다")
        assert detect_ending("입니다") == ("sentence_final", "입니다")

    def test_sentence_final_casual(self):
        """Should detect casual sentence endings."""
        assert detect_ending("먹었어") == ("sentence_final", "어")
        assert detect_ending("갔다") == ("sentence_final", "다")

    def test_question_markers(self):
        """Should detect question markers."""
        assert detect_ending("먹었습니까") == ("question", "습니까")
        assert detect_ending("갈까요") == ("question", "까요")

    def test_clause_connectors(self):
        """Should detect clause connectors."""
        assert detect_ending("밥을 먹고") == ("connector", "고")
        assert detect_ending("비가 오면") == ("connector", "면")
        assert detect_ending("늦어서") == ("connector", "서")
        assert detect_ending("좋지만") == ("connector", "지만")

    def test_modifiers(self):
        """Should detect modifiers (should WAIT)."""
        assert detect_ending("서울에 있는") == ("modifier", "는")
        assert detect_ending("맛있는") == ("modifier", "는")
        assert detect_ending("예쁜") == ("modifier", "ㄴ")

    def test_intent_purpose(self):
        """Should detect intent/purpose patterns (should WAIT)."""
        assert detect_ending("먹으려고") == ("intent_purpose", "려고")
        assert detect_ending("가려면") == ("intent_purpose", "려면")
        assert detect_ending("배우도록") == ("intent_purpose", "도록")

    def test_no_match(self):
        """Should return None for unrecognized endings."""
        assert detect_ending("서울") is None
        assert detect_ending("한국") is None


class TestClauseDetector:
    """Tests for the ClauseDetector class."""

    @pytest.fixture
    def detector(self):
        """Create a clause detector for testing."""
        return ClauseDetector(timeout_ms=10000)  # Long timeout for testing

    @pytest.mark.asyncio
    async def test_detect_sentence_ending(self, detector):
        """Should detect clause at sentence endings."""
        await detector.start()

        words = ["안녕", "하세요"]
        for word_text in words:
            word = Word(text=word_text)
            clause = await detector.add_word(word)

        # Last word should trigger detection
        assert clause is not None
        assert clause.connector == "요"
        assert clause.connector_type == "sentence_final"

        await detector.stop()

    @pytest.mark.asyncio
    async def test_detect_clause_connector(self, detector):
        """Should detect clause at connectors."""
        await detector.start()

        words = ["밥을", "먹고"]
        clause = None
        for word_text in words:
            word = Word(text=word_text)
            clause = await detector.add_word(word)

        assert clause is not None
        assert clause.connector == "고"
        assert clause.connector_type == "connector"

        await detector.stop()

    @pytest.mark.asyncio
    async def test_return_to_buffer(self, detector):
        """Should properly return clause to buffer."""
        await detector.start()

        words = ["서울에", "있는"]
        clause = None
        for word_text in words:
            word = Word(text=word_text)
            clause = await detector.add_word(word)

        assert clause is not None

        # Return to buffer
        detector.return_to_buffer(clause)
        assert detector.current_buffer == "서울에 있는"

        await detector.stop()

    @pytest.mark.asyncio
    async def test_buffer_limit(self, detector):
        """Should flush buffer when size limit reached."""
        detector = ClauseDetector(max_buffer_chars=20)
        await detector.start()

        # Add words until buffer limit
        long_text = "아주 긴 문장을 테스트합니다"
        for word_text in long_text.split():
            word = Word(text=word_text)
            clause = await detector.add_word(word)
            if clause:
                break

        # Should have triggered buffer limit flush
        assert clause is not None
        assert clause.connector == "BUFFER_LIMIT"

        await detector.stop()

    @pytest.mark.asyncio
    async def test_timeout_flush(self, detector):
        """Should flush buffer after timeout."""
        detector = ClauseDetector(timeout_ms=100)  # Short timeout
        await detector.start()

        word = Word(text="서울")
        await detector.add_word(word)

        # Wait for timeout
        await asyncio.sleep(0.2)

        # Get clause from queue
        try:
            clause = await asyncio.wait_for(
                detector.clause_queue.get(),
                timeout=0.1
            )
            assert clause is not None
            assert clause.connector == "TIMEOUT"
        except asyncio.TimeoutError:
            pytest.fail("Timeout flush did not trigger")

        await detector.stop()
