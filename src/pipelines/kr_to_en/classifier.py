"""Safety classifier for Korean clause translation timing."""

import logging
from typing import Optional

from ...models import ClauseResult, ClassifierResult
from ...korean import (
    MODIFIERS,
    ACTION_VERBS,
    PERCEPTION_VERBS,
    has_past_tense_marker,
    ends_with_verb_stem,
)

logger = logging.getLogger(__name__)

# Common Korean single-word affirmations that are safe to translate immediately
AFFIRMATIONS = {
    "네", "예", "응", "어", "그래", "좋아", "알았어", "알겠어",
    "아니", "아니요", "아뇨", "싫어", "맞아", "맞아요", "그래요",
    "네,", "예,", "응,", "아니,", "아니요,",  # With comma
}


class SafetyClassifier:
    """
    Rule-based classifier determining if a clause is safe to translate.

    Prevents errors like:
    - "보고" -> "watched and..." when actual meaning is "want to watch"
    - "만나서" -> "met and..." when actual meaning is "regretted meeting"

    Rules:
    - Sentence endings -> SAFE
    - Modifiers (는/은/ㄴ) -> WAIT (noun coming)
    - Action verb + 고 -> SAFE
    - Perception verb + 고 -> WAIT (emotion likely)
    - -서 connector -> WAIT (cause-effect)
    - -면 connector -> SAFE (conditional complete)
    - Timeout/overflow -> SAFE (force translate)
    """

    def classify(self, clause: ClauseResult) -> ClassifierResult:
        """
        Classify whether a clause is safe to translate.

        Args:
            clause: The clause to classify.

        Returns:
            ClassifierResult.SAFE or ClassifierResult.WAIT
        """
        text = clause.text
        connector = clause.connector
        trigger = clause.trigger

        result = self._apply_rules(text, connector, trigger)

        logger.info(
            f"Classifier: {result.value.upper()} for '{text}' "
            f"(trigger={trigger}, connector={connector})"
        )

        return result

    def _apply_rules(
        self,
        text: str,
        connector: Optional[str],
        trigger: str,
    ) -> ClassifierResult:
        """Apply classification rules."""

        # Common affirmations = always safe (handles short responses)
        if text.strip() in AFFIRMATIONS:
            return ClassifierResult.SAFE

        # Timeout/overflow/force = force translate
        if trigger in ["timeout", "overflow", "force"]:
            return ClassifierResult.SAFE

        # Sentence endings = always safe
        if trigger == "sentence_end":
            return ClassifierResult.SAFE

        # Pause trigger = safe (speaker naturally paused)
        if trigger == "pause":
            return ClassifierResult.SAFE

        # From here, we're dealing with connectors
        if connector is None:
            return ClassifierResult.WAIT  # No clear signal, wait

        # Modifiers = always wait (modifying next noun)
        if connector in MODIFIERS:
            return ClassifierResult.WAIT

        # Check verb type for -고 connector
        if connector == "고":
            if has_past_tense_marker(text):
                # Past tense + 고 = completed action, safe
                return ClassifierResult.SAFE
            if ends_with_verb_stem(text, PERCEPTION_VERBS):
                # Perception verb + 고 = often "want to" or emotion follows
                return ClassifierResult.WAIT
            if ends_with_verb_stem(text, ACTION_VERBS):
                # Action verb + 고 = usually safe
                return ClassifierResult.SAFE
            # Default for -고: if clause is long enough, probably safe
            if len(text) > 30:
                return ClassifierResult.SAFE
            return ClassifierResult.WAIT

        # -서 connector = cause-effect, usually wait
        if connector in ["서", "아서", "어서"]:
            return ClassifierResult.WAIT

        # -면 connector = conditional, self-contained
        if connector in ["면", "으면"]:
            return ClassifierResult.SAFE

        # -지만 connector = "but", safe to translate first part
        if connector == "지만":
            return ClassifierResult.SAFE

        # -니까 = "because", the reason is complete
        if connector in ["니까", "으니까"]:
            return ClassifierResult.SAFE

        # -는데 = background, context dependent
        if connector == "는데":
            # If long enough, probably safe
            if len(text) > 20:
                return ClassifierResult.SAFE
            return ClassifierResult.WAIT

        # -려고 = "in order to", intent not complete
        if connector in ["려고", "으려고"]:
            return ClassifierResult.WAIT

        # Default: conservative, wait
        return ClassifierResult.WAIT


def classify(clause: str, connector: Optional[str], trigger: str = "connector") -> str:
    """
    Convenience function for classification.

    Args:
        clause: The clause text.
        connector: The detected connector.
        trigger: The trigger type.

    Returns:
        "safe" or "wait"
    """
    classifier = SafetyClassifier()
    clause_obj = ClauseResult(text=clause, connector=connector, trigger=trigger)
    result = classifier.classify(clause_obj)
    return result.value
