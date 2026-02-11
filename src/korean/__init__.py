"""Korean linguistic utilities."""

from .patterns import (
    SENTENCE_FINAL,
    QUESTION_MARKERS,
    CLAUSE_CONNECTORS,
    MODIFIERS,
    ACTION_VERBS,
    PERCEPTION_VERBS,
    HONORIFIC_VERBS,
    has_past_tense_marker,
    ends_with_verb_stem,
    detect_ending,
)

__all__ = [
    "SENTENCE_FINAL",
    "QUESTION_MARKERS",
    "CLAUSE_CONNECTORS",
    "MODIFIERS",
    "ACTION_VERBS",
    "PERCEPTION_VERBS",
    "HONORIFIC_VERBS",
    "has_past_tense_marker",
    "ends_with_verb_stem",
    "detect_ending",
]
