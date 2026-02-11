"""Tests for Korean clause safety classification."""

import pytest
from src.pipeline.classifier import SafetyClassifier, classify
from src.models import Clause, ClassifierDecision


class TestSafetyClassifier:
    """Tests for the SafetyClassifier class."""

    @pytest.fixture
    def classifier(self):
        """Create a classifier for testing."""
        return SafetyClassifier()

    def test_sentence_final_safe(self, classifier):
        """Sentence finals should always be SAFE."""
        test_cases = [
            ("밥을 먹었어요", "요", "sentence_final"),
            ("안녕하세요", "요", "sentence_final"),
            ("먹었습니다", "습니다", "sentence_final"),
            ("갔다", "다", "sentence_final"),
        ]
        for text, connector, conn_type in test_cases:
            clause = Clause(text=text, connector=connector, connector_type=conn_type)
            assert classifier.classify(clause) == ClassifierDecision.SAFE, \
                f"Expected SAFE for '{text}'"

    def test_question_markers_safe(self, classifier):
        """Question markers should always be SAFE."""
        test_cases = [
            ("먹었습니까", "습니까", "question"),
            ("갈까요", "까요", "question"),
        ]
        for text, connector, conn_type in test_cases:
            clause = Clause(text=text, connector=connector, connector_type=conn_type)
            assert classifier.classify(clause) == ClassifierDecision.SAFE, \
                f"Expected SAFE for '{text}'"

    def test_timeout_safe(self, classifier):
        """Timeout should always be SAFE."""
        clause = Clause(text="서울에 갔", connector="TIMEOUT", connector_type="timeout")
        assert classifier.classify(clause) == ClassifierDecision.SAFE

    def test_modifiers_wait(self, classifier):
        """Modifiers should always WAIT."""
        test_cases = [
            ("서울에 있는", "는", "modifier"),
            ("맛있는", "는", "modifier"),
            ("예쁜", "ㄴ", "modifier"),
            ("먹을", "ㄹ", "modifier"),
        ]
        for text, connector, conn_type in test_cases:
            clause = Clause(text=text, connector=connector, connector_type=conn_type)
            assert classifier.classify(clause) == ClassifierDecision.WAIT, \
                f"Expected WAIT for '{text}'"

    def test_intent_purpose_wait(self, classifier):
        """Intent/purpose patterns should always WAIT."""
        test_cases = [
            ("먹으려고", "려고", "intent_purpose"),
            ("가려면", "려면", "intent_purpose"),
            ("배우도록", "도록", "intent_purpose"),
        ]
        for text, connector, conn_type in test_cases:
            clause = Clause(text=text, connector=connector, connector_type=conn_type)
            assert classifier.classify(clause) == ClassifierDecision.WAIT, \
                f"Expected WAIT for '{text}'"

    def test_go_connector_past_tense_safe(self, classifier):
        """Past tense + 고 should be SAFE."""
        clause = Clause(
            text="어제 서울에 갔고",
            connector="고",
            connector_type="connector"
        )
        assert classifier.classify(clause) == ClassifierDecision.SAFE

    def test_go_connector_perception_verb_wait(self, classifier):
        """Perception verb + 고 should WAIT."""
        # This tests the case where "보고" could be followed by "싶다"
        clause = Clause(
            text="그 영화를 보고",
            connector="고",
            connector_type="connector"
        )
        assert classifier.classify(clause) == ClassifierDecision.WAIT

    def test_conditional_safe(self, classifier):
        """Conditional -면 should be SAFE."""
        clause = Clause(
            text="비가 오면",
            connector="면",
            connector_type="connector"
        )
        assert classifier.classify(clause) == ClassifierDecision.SAFE

    def test_cause_effect_wait(self, classifier):
        """Cause-effect -서 should WAIT."""
        clause = Clause(
            text="그 사람을 만나서",
            connector="서",
            connector_type="connector"
        )
        assert classifier.classify(clause) == ClassifierDecision.WAIT

    def test_contrast_jiman_safe(self, classifier):
        """Contrast -지만 should be SAFE."""
        clause = Clause(
            text="비가 오지만",
            connector="지만",
            connector_type="connector"
        )
        assert classifier.classify(clause) == ClassifierDecision.SAFE


class TestClassifyFunction:
    """Tests for the convenience classify function."""

    def test_safe_cases(self):
        """Test cases that should return SAFE."""
        assert classify("어제 서울에 갔고", "고") == "SAFE"  # Past tense action
        assert classify("비가 오면", "면") == "SAFE"  # Conditional
        assert classify("밥을 먹었어요", "요") == "SAFE"  # Sentence end

    def test_wait_cases(self):
        """Test cases that should return WAIT."""
        assert classify("그 영화를 보고", "고") == "WAIT"  # Perception verb
        assert classify("서울에 있는", "는") == "WAIT"  # Modifier
        assert classify("그 사람을 만나서", "서") == "WAIT"  # Cause-effect


class TestNegationPattern:
    """Test the critical negation pattern that this architecture prevents."""

    @pytest.fixture
    def classifier(self):
        return SafetyClassifier()

    def test_negation_pattern_wait(self, classifier):
        """
        Test: '저는 그 영화를 보고' + '싶지 않아요' = 'I DON'T WANT to watch'

        If we translated at '보고', we might say 'I watched and...' which is wrong.
        The classifier should WAIT at '보고' because '보' is a perception verb.
        """
        clause = Clause(
            text="저는 그 영화를 보고",
            connector="고",
            connector_type="connector"
        )
        decision = classifier.classify(clause)

        # Should WAIT because 보 is a perception verb
        # and 보고 싶다 is a common pattern meaning "want to see"
        assert decision == ClassifierDecision.WAIT, \
            "Should WAIT for '보고' to prevent translating '보고 싶지 않아요' as 'watched and...'"

    def test_complete_negation_safe(self, classifier):
        """After getting the full phrase, sentence ending should be SAFE."""
        # Simulating when we get the full sentence
        clause = Clause(
            text="저는 그 영화를 보고 싶지 않아요",
            connector="요",
            connector_type="sentence_final"
        )
        decision = classifier.classify(clause)
        assert decision == ClassifierDecision.SAFE
