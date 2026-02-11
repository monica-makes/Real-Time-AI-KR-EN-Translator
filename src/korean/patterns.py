"""Korean grammatical patterns for clause detection and classification."""

from typing import Optional, List

# Sentence-final endings (highest confidence - definitely translate)
SENTENCE_FINAL = [
    # Formal declarative
    "습니다", "입니다", "ㅂ니다", "니다",
    # Polite declarative
    "어요", "아요", "여요", "해요",
    "거든요", "네요", "군요", "죠",
    # Casual declarative
    "어", "아", "여", "해",
    # Plain form
    "다", "했다", "였다", "었다",
    # General polite ending
    "요",
]

# Question markers
QUESTION_MARKERS = [
    "습니까", "입니까", "합니까",      # Formal
    "을까요", "ㄹ까요", "까요",        # Polite
    "나요", "가요",                    # Polite
    "니", "냐",                        # Casual
]

# Clause connectors (send to classifier)
CLAUSE_CONNECTORS = [
    "고",                    # and (sequential)
    "서", "아서", "어서",    # because/and then
    "면", "으면",            # if/when
    "지만",                  # but/although
    "니까", "으니까",        # because (reason)
    "는데",                  # but/and (background)
    "려고", "으려고",        # in order to
]

# Modifiers (ALWAYS WAIT - noun coming next)
MODIFIERS = ["는", "은", "ㄴ", "을", "ㄹ"]

# Verb classifications for safety classifier
ACTION_VERBS = [
    "가", "오", "먹", "마시", "자", "일어나", "앉", "서",
    "걷", "뛰", "하", "사", "팔", "쓰", "읽", "만들",
    "타", "내리", "열", "닫", "놓", "넣", "빼", "던지",
    "잡", "치", "때리", "울", "웃", "노래하", "춤추",
    "일하", "공부하", "운동하", "요리하", "청소하", "씻",
]

PERCEPTION_VERBS = [
    "보", "듣", "만나", "느끼", "생각하", "알", "모르",
    "믿", "의심하", "기억하", "잊", "이해하", "깨닫",
    "발견하", "인식하",
]

# Honorific verb mappings (for reference/testing)
HONORIFIC_VERBS = {
    "먹다": "드시다",      # to eat
    "자다": "주무시다",    # to sleep
    "있다": "계시다",      # to be/exist
    "말하다": "말씀하시다", # to speak
    "주다": "드리다",      # to give
    "보다": "뵙다",        # to see/meet
}

# Past tense markers
PAST_TENSE_MARKERS = ["었", "았", "했", "였"]


def has_past_tense_marker(text: str) -> bool:
    """Check if text contains a past tense marker."""
    for marker in PAST_TENSE_MARKERS:
        if marker in text:
            return True
    return False


def ends_with_verb_stem(text: str, verb_list: List[str]) -> bool:
    """Check if text ends with any verb stem from the list."""
    cleaned = text.rstrip()
    for verb in verb_list:
        # Check if the verb stem appears near the end
        if verb in cleaned[-10:]:  # Look in last 10 chars
            return True
    return False


def detect_ending(text: str) -> Optional[tuple[str, str]]:
    """
    Detect if text ends with a known pattern.

    Returns:
        Tuple of (ending_type, matched_ending) or None if no match.
        ending_type is one of: 'sentence_final', 'question', 'connector', 'modifier'
    """
    text = text.strip()
    if not text:
        return None

    # Check sentence finals (longest first for proper matching)
    for ending in sorted(SENTENCE_FINAL, key=len, reverse=True):
        if text.endswith(ending):
            return ("sentence_final", ending)

    # Check question markers
    for ending in sorted(QUESTION_MARKERS, key=len, reverse=True):
        if text.endswith(ending):
            return ("question", ending)

    # Check clause connectors
    for ending in sorted(CLAUSE_CONNECTORS, key=len, reverse=True):
        if text.endswith(ending):
            return ("connector", ending)

    # Check modifiers
    for ending in sorted(MODIFIERS, key=len, reverse=True):
        if text.endswith(ending):
            return ("modifier", ending)

    return None
