"""Safety classifier for Korean clause translation timing."""

import logging
from typing import Literal

from ..models import Clause, ClassifierDecision
from ..korean import (
    SENTENCE_FINAL,
    QUESTION_MARKERS,
    MODIFIERS,
    INTENT_PURPOSE,
    ACTION_VERBS,
    PERCEPTION_VERBS,
    has_past_tense_marker,
    ends_with_verb_stem,
)

logger = logging.getLogger(__name__)


class SafetyClassifier:
    """
    Determines if a clause is safe to translate or should wait for more context.

    This is critical for Korean->English translation because:
    - Korean is SOV (Subject-Object-Verb)
    - English is SVO (Subject-Verb-Object)
    - Translating too early can produce incorrect translations

    Example failure case this prevents:
    - "저는 그 영화를 보고" + "싶지 않아요" = "I DON'T WANT to watch"
    - If we translated at "보고", we might say "I watched and..."
    """

    def classify(self, clause: Clause) -> ClassifierDecision:
        """
        Classify whether a clause is safe to translate.

        Args:
            clause: The clause to classify

        Returns:
            ClassifierDecision.SAFE or ClassifierDecision.WAIT
        """
        text = clause.text
        connector = clause.connector
        connector_type = clause.connector_type

        decision = self._apply_rules(text, connector, connector_type)

        # Update the clause with the decision
        clause.decision = decision

        logger.info(
            f"Classifier decision: {decision.value} for '{text}' "
            f"(connector: {connector}, type: {connector_type})"
        )

        return decision

    def _apply_rules(
        self,
        text: str,
        connector: str,
        connector_type: str,
    ) -> ClassifierDecision:
        """Apply classification rules."""

        # ALWAYS SAFE - sentence endings
        if connector_type == "sentence_final" or connector in SENTENCE_FINAL:
            return ClassifierDecision.SAFE

        # ALWAYS SAFE - question markers
        if connector_type == "question" or connector in QUESTION_MARKERS:
            return ClassifierDecision.SAFE

        # ALWAYS SAFE - timeout or buffer limit
        if connector_type == "timeout" or connector in ["TIMEOUT", "BUFFER_LIMIT", "STOP"]:
            return ClassifierDecision.SAFE

        # ALWAYS WAIT - modifiers (noun coming next)
        if connector_type == "modifier" or connector in MODIFIERS:
            return ClassifierDecision.WAIT

        # ALWAYS WAIT - intent/purpose patterns
        if connector_type == "intent_purpose" or connector in INTENT_PURPOSE:
            return ClassifierDecision.WAIT

        # CONTEXT-DEPENDENT: -고 connector
        if connector == "고":
            return self._classify_go_connector(text)

        # -면 / -으면 (if/when) = usually safe, conditional is complete
        if connector in ["면", "으면"]:
            return ClassifierDecision.SAFE

        # -지만 (but/although) = safe, contrast is set up
        if connector == "지만":
            return ClassifierDecision.SAFE

        # -서 / -아서 / -어서 = often indicates cause-effect, wait for effect
        if connector in ["서", "아서", "어서"]:
            return ClassifierDecision.WAIT

        # -니까 / -으니까 (because) = usually safe
        if connector in ["니까", "으니까"]:
            return ClassifierDecision.SAFE

        # -는데 (background) = context dependent, lean towards safe
        if connector == "는데":
            # If it's a long clause, probably safe to translate
            if len(text) > 20:
                return ClassifierDecision.SAFE
            return ClassifierDecision.WAIT

        # Default: conservative, wait for more context
        return ClassifierDecision.WAIT

    def _classify_go_connector(self, text: str) -> ClassifierDecision:
        """
        Special handling for -고 connector.

        -고 can mean:
        1. "and" (sequential actions): 먹고 갔어요 = "ate and went"
        2. Part of compound: 보고 싶다 = "want to see" (NOT "saw and want")
        """

        # Past tense + 고 = completed action, usually safe
        if has_past_tense_marker(text):
            return ClassifierDecision.SAFE

        # Perception/emotion verbs + 고 = often followed by desire/reaction
        # e.g., 보고 (싶다), 만나고 (싶다)
        if ends_with_verb_stem(text, PERCEPTION_VERBS):
            return ClassifierDecision.WAIT

        # Action verbs + 고 = usually safe (sequential actions)
        if ends_with_verb_stem(text, ACTION_VERBS):
            return ClassifierDecision.SAFE

        # If clause is long enough, it's probably safe
        if len(text) > 30:
            return ClassifierDecision.SAFE

        # Default for -고: wait to be safe
        return ClassifierDecision.WAIT


def classify(clause: str, connector: str) -> Literal["SAFE", "WAIT"]:
    """
    Convenience function for classification.

    This matches the interface in the spec for easy testing.

    Args:
        clause: The clause text
        connector: The detected connector

    Returns:
        "SAFE" or "WAIT"
    """
    classifier = SafetyClassifier()
    clause_obj = Clause(
        text=clause,
        connector=connector,
        connector_type="connector",  # Default type
    )
    result = classifier.classify(clause_obj)
    return result.value
