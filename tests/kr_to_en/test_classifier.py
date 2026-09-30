"""Tests for Korean clause safety classification."""

import pytest
from src.pipelines.kr_to_en.classifier import SafetyClassifier, classify
from src.models import ClauseResult, ClassifierResult


class TestSafetyClassifier:
    """Tests for the SafetyClassifier class."""

    @pytest.fixture
    def classifier(self):
        """Create a classifier for testing."""
        return SafetyClassifier()

    def test_sentence_final_safe(self, classifier):
        """Sentence finals should always be SAFE."""
        test_cases = [
            ("밥을 먹었어요", "요", "sentence_end"),
            ("안녕하세요", "요", "sentence_end"),
            ("먹었습니다", "습니다", "sentence_end"),
        ]
        for text, connector, trigger in test_cases:
            clause = ClauseResult(text=text, connector=connector, trigger=trigger)
            assert classifier.classify(clause) == ClassifierResult.SAFE, \
                f"Expected SAFE for '{text}'"

    def test_timeout_safe(self, classifier):
        """Timeout should always be SAFE."""
        clause = ClauseResult(text="서울에 갔", connector=None, trigger="timeout")
        assert classifier.classify(clause) == ClassifierResult.SAFE

    def test_pause_safe(self, classifier):
        """Pause should be SAFE."""
        clause = ClauseResult(text="안녕", connector=None, trigger="pause")
        assert classifier.classify(clause) == ClassifierResult.SAFE

    def test_modifiers_wait(self, classifier):
        """Modifiers should always WAIT."""
        test_cases = [
            ("서울에 있는", "는"),
            ("맛있는", "는"),
            ("먹을", "ㄹ"),
        ]
        for text, connector in test_cases:
            clause = ClauseResult(text=text, connector=connector, trigger="connector")
            assert classifier.classify(clause) == ClassifierResult.WAIT, \
                f"Expected WAIT for '{text}'"

    def test_go_connector_past_tense_safe(self, classifier):
        """Past tense + 고 should be SAFE."""
        clause = ClauseResult(
            text="어제 서울에 갔고",
            connector="고",
            trigger="connector"
        )
        assert classifier.classify(clause) == ClassifierResult.SAFE

    def test_go_connector_perception_verb_wait(self, classifier):
        """Perception verb + 고 should WAIT."""
        clause = ClauseResult(
            text="그 영화를 보고",
            connector="고",
            trigger="connector"
        )
        assert classifier.classify(clause) == ClassifierResult.WAIT

    def test_conditional_safe(self, classifier):
        """Conditional -면 should be SAFE."""
        clause = ClauseResult(
            text="비가 오면",
            connector="면",
            trigger="connector"
        )
        assert classifier.classify(clause) == ClassifierResult.SAFE

    def test_cause_effect_wait(self, classifier):
        """Cause-effect -서 should WAIT."""
        clause = ClauseResult(
            text="그 사람을 만나서",
            connector="서",
            trigger="connector"
        )
        assert classifier.classify(clause) == ClassifierResult.WAIT

    def test_contrast_jiman_safe(self, classifier):
        """Contrast -지만 should be SAFE."""
        clause = ClauseResult(
            text="비가 오지만",
            connector="지만",
            trigger="connector"
        )
        assert classifier.classify(clause) == ClassifierResult.SAFE

    def test_intent_ryeogo_wait(self, classifier):
        """-려고 (intent) should WAIT."""
        clause = ClauseResult(
            text="먹으려고",
            connector="려고",
            trigger="connector"
        )
        assert classifier.classify(clause) == ClassifierResult.WAIT


class TestClassifyFunction:
    """Tests for the convenience classify function."""

    def test_safe_cases(self):
        """Test cases that should return safe."""
        assert classify("어제 서울에 갔고", "고") == "safe"
        assert classify("비가 오면", "면") == "safe"
        assert classify("밥을 먹었어요", "요", "sentence_end") == "safe"

    def test_wait_cases(self):
        """Test cases that should return wait."""
        assert classify("그 영화를 보고", "고") == "wait"
        assert classify("서울에 있는", "는") == "wait"
        assert classify("그 사람을 만나서", "서") == "wait"


class TestNegationPattern:
    """Test the critical negation pattern."""

    @pytest.fixture
    def classifier(self):
        return SafetyClassifier()

    def test_negation_pattern_wait(self, classifier):
        """
        Test: '저는 그 영화를 보고' + '싶지 않아요' = 'I DON'T WANT to watch'

        Should WAIT at '보고' to prevent wrong translation.
        """
        clause = ClauseResult(
            text="저는 그 영화를 보고",
            connector="고",
            trigger="connector"
        )
        decision = classifier.classify(clause)
        assert decision == ClassifierResult.WAIT

    def test_complete_negation_safe(self, classifier):
        """Full sentence with negation should be SAFE."""
        clause = ClauseResult(
            text="저는 그 영화를 보고 싶지 않아요",
            connector="요",
            trigger="sentence_end"
        )
        assert classifier.classify(clause) == ClassifierResult.SAFE

    def test_spaces_do_not_change_the_decision(self, classifier):
        """Clauses now keep their spacing; the rules still see the unspaced text they were tuned on."""
        cases = [
            ("저는 그 영화를 보고", "고", "connector"),
            ("서울에 있는", "는", "connector"),
            ("어제 친구를 만나서 같이 밥을 먹고 영화도 보고", "고", "connector"),
            ("비가 오는데 우산이 없어서 편의점에", "서", "connector"),
            ("밥을 먹었어요", "요", "sentence_end"),
        ]
        for text, connector, trigger in cases:
            spaced = classifier.classify(ClauseResult(text=text, connector=connector, trigger=trigger))
            unspaced = classifier.classify(
                ClauseResult(text=text.replace(" ", ""), connector=connector, trigger=trigger)
            )
            assert spaced == unspaced, f"'{text}' decided differently with spaces"
