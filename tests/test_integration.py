"""Integration tests for bidirectional translation pipelines."""

import pytest
from src.pipelines.kr_to_en.clause_detector import KoreanClauseDetector
from src.pipelines.kr_to_en.classifier import SafetyClassifier
from src.pipelines.en_to_kr.sentence_detector import EnglishSentenceDetector
from src.pipelines.en_to_kr.formality import FormalityConfig
from src.session.context import SharedTranslationContext
from src.session.manager import SessionManager
from src.models import TranslationDirection, ClassifierResult


class TestKrToEnFlow:
    """Integration tests for Korean to English pipeline flow."""

    @pytest.fixture
    def detector(self):
        return KoreanClauseDetector(timeout_ms=10000)

    @pytest.fixture
    def classifier(self):
        return SafetyClassifier()

    def test_full_sentence_flow(self, detector, classifier):
        """
        Test: '저는 어제 서울에 갔고 맛있는 음식을 먹었어요'

        Expected:
        1. '갔고' → classifier → SAFE (past tense)
        2. '먹었어요' → classifier → SAFE (sentence end)
        """
        # First clause
        detector.add_word("저는", 0)
        detector.add_word("어제", 100)
        detector.add_word("서울에", 200)
        clause1 = detector.add_word("갔고", 300)

        assert clause1 is not None
        decision1 = classifier.classify(clause1)
        assert decision1 == ClassifierResult.SAFE

        # Second clause
        detector.add_word("맛있는", 400)
        detector.add_word("음식을", 500)
        clause2 = detector.add_word("먹었어요", 600)

        assert clause2 is not None
        decision2 = classifier.classify(clause2)
        assert decision2 == ClassifierResult.SAFE

    def test_wait_and_continue(self, detector, classifier):
        """Test WAIT decision and returning to buffer."""
        detector.add_word("서울에", 0)
        clause = detector.add_word("있는", 100)

        assert clause is not None
        decision = classifier.classify(clause)
        assert decision == ClassifierResult.WAIT

        # Return to buffer and continue
        detector.return_to_buffer(clause)
        assert "있는" in detector.current_buffer

        # Complete with noun
        detector.add_word("식당에서", 200)
        clause2 = detector.add_word("먹었어요", 300)

        assert clause2 is not None
        decision2 = classifier.classify(clause2)
        assert decision2 == ClassifierResult.SAFE

    def test_conditional_flow(self, detector, classifier):
        """Test conditional clause handling."""
        detector.add_word("비가", 0)
        clause1 = detector.add_word("오면", 100)

        assert clause1 is not None
        decision1 = classifier.classify(clause1)
        assert decision1 == ClassifierResult.SAFE

        detector.add_word("우산을", 200)
        clause2 = detector.add_word("가져가세요", 300)

        assert clause2 is not None
        decision2 = classifier.classify(clause2)
        assert decision2 == ClassifierResult.SAFE


class TestEnToKrFlow:
    """Integration tests for English to Korean pipeline flow."""

    @pytest.fixture
    def detector(self):
        return EnglishSentenceDetector(timeout_ms=10000)

    @pytest.fixture
    def formality(self):
        return FormalityConfig()

    def test_simple_sentence_flow(self, detector, formality):
        """Test simple English sentence detection."""
        detector.add_word("I", 0)
        detector.add_word("went", 100)
        detector.add_word("to", 200)
        sentence = detector.add_word("school.", 300)

        assert sentence is not None
        assert sentence == "I went to school."

    def test_question_flow(self, detector, formality):
        """Test question detection."""
        detector.add_word("Did", 0)
        detector.add_word("you", 100)
        sentence = detector.add_word("eat?", 200)

        assert sentence is not None
        assert sentence == "Did you eat?"

    def test_formality_toggle(self, formality):
        """Test formality toggle during session."""
        assert formality.honorific_mode is False
        assert "해요체" in formality.get_style_description()

        formality.set_honorific(True)
        assert formality.honorific_mode is True
        assert "높임말" in formality.get_style_description()


class TestBidirectionalContext:
    """Test bidirectional context sharing."""

    def test_context_shared_between_pipelines(self):
        """Context should be shared and updated by both directions."""
        context = SharedTranslationContext(max_exchanges=10)

        # Simulate KO->EN translation
        context.add_exchange(
            direction=TranslationDirection.KO_TO_EN,
            source_text="저는 학생입니다",
            translated_text="I am a student",
        )

        # Simulate EN->KO translation
        context.add_exchange(
            direction=TranslationDirection.EN_TO_KO,
            source_text="Nice to meet you",
            translated_text="만나서 반갑습니다",
        )

        assert len(context) == 2

        # Both should be visible in context
        ko_prompt = context.get_context_for_prompt(TranslationDirection.KO_TO_EN)
        en_prompt = context.get_context_for_prompt(TranslationDirection.EN_TO_KO)

        assert "학생" in ko_prompt
        assert "meet" in ko_prompt
        assert "학생" in en_prompt
        assert "meet" in en_prompt


class TestSessionManagement:
    """Test session management."""

    def test_create_session(self):
        """Should create session with correct config."""
        manager = SessionManager()

        session = manager.create_session(
            directions=[TranslationDirection.KO_TO_EN],
            honorific_mode=False,
        )

        assert session is not None
        assert session.has_direction(TranslationDirection.KO_TO_EN)
        assert not session.has_direction(TranslationDirection.EN_TO_KO)

    def test_bidirectional_session(self):
        """Should create bidirectional session."""
        manager = SessionManager()

        session = manager.create_session(
            directions=[
                TranslationDirection.KO_TO_EN,
                TranslationDirection.EN_TO_KO,
            ],
            honorific_mode=True,
        )

        assert session.has_direction(TranslationDirection.KO_TO_EN)
        assert session.has_direction(TranslationDirection.EN_TO_KO)
        assert session.honorific_mode is True

    def test_end_session(self):
        """Should end and remove session."""
        manager = SessionManager()
        session = manager.create_session(
            directions=[TranslationDirection.KO_TO_EN],
        )

        result = manager.end_session(session.id)
        assert result is True
        assert manager.get_session(session.id) is None


class TestEdgeCases:
    """Test edge cases and error handling."""

    def test_empty_input_ko(self):
        """Korean detector should handle empty input."""
        detector = KoreanClauseDetector()
        result = detector.add_word("", 0)
        assert result is None

    def test_empty_input_en(self):
        """English detector should handle empty input."""
        detector = EnglishSentenceDetector()
        result = detector.add_word("", 0)
        assert result is None

    def test_long_clause_handling(self):
        """Should handle very long clauses."""
        detector = KoreanClauseDetector(max_buffer_chars=50)
        classifier = SafetyClassifier()

        # Add many words until overflow
        for i in range(20):
            result = detector.add_word(f"단어{i}", i * 100)
            if result:
                # Should have triggered overflow, which is SAFE
                decision = classifier.classify(result)
                assert decision == ClassifierResult.SAFE
                break

    def test_rapid_consecutive_sentences(self):
        """Should handle rapid consecutive sentences."""
        detector = EnglishSentenceDetector()

        sentence1 = None
        for word in ["Hello.", "How", "are", "you?"]:
            result = detector.add_word(word, 0)
            if result:
                if sentence1 is None:
                    sentence1 = result
                else:
                    # Second sentence
                    assert result == "How are you?"
