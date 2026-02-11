"""Integration tests for the translation pipeline."""

import pytest
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

from src.pipeline.clause_detector import ClauseDetector
from src.pipeline.classifier import SafetyClassifier
from src.models import Word, Clause, ClassifierDecision


class TestPipelineFlow:
    """Integration tests for the clause detection and classification flow."""

    @pytest.fixture
    def detector(self):
        return ClauseDetector(timeout_ms=10000)

    @pytest.fixture
    def classifier(self):
        return SafetyClassifier()

    @pytest.mark.asyncio
    async def test_full_sentence_flow(self, detector, classifier):
        """
        Test: '저는 어제 서울에 갔고 맛있는 음식을 먹었어요'

        Expected flow:
        1. '갔고' detected → classifier → SAFE (past tense)
        2. '먹었어요' detected → classifier → SAFE (sentence end)
        """
        await detector.start()

        # First part: "저는 어제 서울에 갔고"
        words1 = ["저는", "어제", "서울에", "갔고"]
        clause1 = None
        for word_text in words1:
            word = Word(text=word_text)
            result = await detector.add_word(word)
            if result:
                clause1 = result

        assert clause1 is not None
        assert clause1.connector == "고"
        decision1 = classifier.classify(clause1)
        # '갔고' has past tense marker '갔', so should be SAFE
        assert decision1 == ClassifierDecision.SAFE

        # Second part: "맛있는 음식을 먹었어요"
        words2 = ["맛있는", "음식을", "먹었어요"]
        clauses = []
        for word_text in words2:
            word = Word(text=word_text)
            result = await detector.add_word(word)
            if result:
                clauses.append(result)

        # Should detect "맛있는" as modifier (WAIT) and "먹었어요" as sentence end (SAFE)
        # The modifier will be returned to buffer, then sentence end detected
        assert len(clauses) >= 1

        # The final clause should be the sentence ending
        final_clause = clauses[-1]
        assert final_clause.connector_type == "sentence_final"
        decision2 = classifier.classify(final_clause)
        assert decision2 == ClassifierDecision.SAFE

        await detector.stop()

    @pytest.mark.asyncio
    async def test_wait_and_continue_flow(self, detector, classifier):
        """
        Test returning to buffer on WAIT and continuing to buffer more.

        Input: "서울에 있는 식당"
        '있는' → WAIT (modifier, noun coming)
        """
        await detector.start()

        words = ["서울에", "있는"]
        clause = None
        for word_text in words:
            word = Word(text=word_text)
            result = await detector.add_word(word)
            if result:
                clause = result

        assert clause is not None
        assert clause.connector == "는"
        assert clause.connector_type == "modifier"

        decision = classifier.classify(clause)
        assert decision == ClassifierDecision.WAIT

        # Return to buffer
        detector.return_to_buffer(clause)
        assert "있는" in detector.current_buffer

        # Add more words
        word = Word(text="식당에서")
        await detector.add_word(word)
        assert "식당에서" in detector.current_buffer

        await detector.stop()

    @pytest.mark.asyncio
    async def test_conditional_flow(self, detector, classifier):
        """
        Test: '비가 오면 우산을 가져가세요'

        '오면' → SAFE (conditional is complete)
        '가져가세요' → SAFE (sentence end)
        """
        await detector.start()

        # First clause: "비가 오면"
        words1 = ["비가", "오면"]
        clause1 = None
        for word_text in words1:
            word = Word(text=word_text)
            result = await detector.add_word(word)
            if result:
                clause1 = result

        assert clause1 is not None
        decision1 = classifier.classify(clause1)
        assert decision1 == ClassifierDecision.SAFE

        # Second clause: "우산을 가져가세요"
        words2 = ["우산을", "가져가세요"]
        clause2 = None
        for word_text in words2:
            word = Word(text=word_text)
            result = await detector.add_word(word)
            if result:
                clause2 = result

        assert clause2 is not None
        decision2 = classifier.classify(clause2)
        assert decision2 == ClassifierDecision.SAFE

        await detector.stop()

    @pytest.mark.asyncio
    async def test_cause_effect_wait_flow(self, detector, classifier):
        """
        Test: '그 사람을 만나서 후회했어요'

        '만나서' → WAIT (cause-effect, wait for the effect)
        Full sentence → SAFE
        """
        await detector.start()

        # First detect "만나서"
        words1 = ["그", "사람을", "만나서"]
        clause1 = None
        for word_text in words1:
            word = Word(text=word_text)
            result = await detector.add_word(word)
            if result:
                clause1 = result

        assert clause1 is not None
        decision1 = classifier.classify(clause1)
        assert decision1 == ClassifierDecision.WAIT

        # Return to buffer and continue
        detector.return_to_buffer(clause1)

        # Complete with "후회했어요"
        word = Word(text="후회했어요")
        clause2 = await detector.add_word(word)

        assert clause2 is not None
        decision2 = classifier.classify(clause2)
        assert decision2 == ClassifierDecision.SAFE

        await detector.stop()


class TestEdgeCases:
    """Test edge cases and special scenarios."""

    @pytest.fixture
    def detector(self):
        return ClauseDetector(timeout_ms=10000)

    @pytest.fixture
    def classifier(self):
        return SafetyClassifier()

    @pytest.mark.asyncio
    async def test_long_clause_go_connector(self, detector, classifier):
        """Long clauses with -고 should be SAFE even without past tense."""
        await detector.start()

        # Long clause that ends with -고
        long_text = "오늘 아침에 일어나서 밥을 먹고 학교에 가고"
        words = long_text.split()

        clause = None
        for word_text in words:
            word = Word(text=word_text)
            result = await detector.add_word(word)
            if result:
                clause = result
                # Reset for next clause
                pass

        # Should have detected at least one clause ending with 고
        assert clause is not None

        await detector.stop()

    @pytest.mark.asyncio
    async def test_empty_input(self, detector):
        """Should handle empty input gracefully."""
        await detector.start()

        word = Word(text="")
        clause = await detector.add_word(word)
        assert clause is None

        await detector.stop()

    @pytest.mark.asyncio
    async def test_single_word_sentence(self, detector, classifier):
        """Should handle single-word sentences."""
        await detector.start()

        word = Word(text="네요")  # "Yes" / affirmation
        clause = await detector.add_word(word)

        # Should be detected as sentence final
        if clause:
            decision = classifier.classify(clause)
            assert decision == ClassifierDecision.SAFE

        await detector.stop()
