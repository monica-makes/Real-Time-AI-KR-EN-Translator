"""Pydantic models for the bidirectional translation pipeline."""

from datetime import datetime
from enum import Enum
from typing import Literal, Optional, List
from pydantic import BaseModel


class TranslationDirection(str, Enum):
    """Direction of translation."""
    KO_TO_EN = "ko_to_en"
    EN_TO_KO = "en_to_ko"


class ClassifierResult(str, Enum):
    """Result from the safety classifier."""
    SAFE = "safe"   # Translate now
    WAIT = "wait"   # Keep buffering


class ClauseResult(BaseModel):
    """Result from clause/sentence detection."""
    text: str
    connector: Optional[str] = None
    trigger: str  # "sentence_end", "connector", "pause", "timeout", "overflow", "force"


class Exchange(BaseModel):
    """A single exchange in the conversation."""
    timestamp: datetime
    direction: TranslationDirection
    source_text: str       # Original (Korean or English)
    translated_text: str   # Translation (English or Korean)


class SessionConfig(BaseModel):
    """Configuration for a translation session."""
    active_directions: List[TranslationDirection]
    honorific_mode: bool = False  # For EN->KR only
    detected_gender: Optional[Literal["male", "female"]] = None
    gender_override: Optional[Literal["male", "female"]] = None  # Takes precedence


# ==================== CLIENT -> SERVER ====================

class SessionStart(BaseModel):
    """Start a new translation session."""
    type: Literal["session_start"] = "session_start"
    directions: List[TranslationDirection]
    honorific_mode: bool = False


class AudioChunk(BaseModel):
    """Audio chunk from client."""
    type: Literal["audio_chunk"] = "audio_chunk"
    direction: TranslationDirection
    data: bytes
    timestamp_ms: int = 0
    gender_override: Optional[Literal["male", "female"]] = None  # Override detected gender


class ConfigUpdate(BaseModel):
    """Update session configuration."""
    type: Literal["config_update"] = "config_update"
    honorific_mode: Optional[bool] = None
    gender_override: Optional[Literal["male", "female"]] = None  # Override detected gender


class SessionEnd(BaseModel):
    """End the current session."""
    type: Literal["session_end"] = "session_end"


# ==================== SERVER -> CLIENT ====================

class TranscriptInterim(BaseModel):
    """Interim transcription for UI feedback."""
    type: Literal["transcript_interim"] = "transcript_interim"
    direction: TranslationDirection
    text: str


class TranscriptFinal(BaseModel):
    """Final transcription."""
    type: Literal["transcript_final"] = "transcript_final"
    direction: TranslationDirection
    text: str
    segment_id: str


class ClassifierDecision(BaseModel):
    """Debug info for Korean->English pipeline."""
    type: Literal["classifier_decision"] = "classifier_decision"
    clause: str
    connector: Optional[str] = None
    decision: str  # "safe" or "wait"


class TranslationResult(BaseModel):
    """Translation result."""
    type: Literal["translation"] = "translation"
    direction: TranslationDirection
    original: str
    translated: str
    segment_id: str
    honorific: Optional[bool] = None  # Only for EN->KR


class AudioOut(BaseModel):
    """Audio output chunk."""
    type: Literal["audio_out"] = "audio_out"
    direction: TranslationDirection
    data: bytes
    format: str = "mp3"


# ErrorMessage.code values for a segment that couldn't be translated. In a room
# these errors go to both phones, so neither side waits for text that never comes.
ERROR_CODE_TRANSLATION_REFUSED = "translation_refused"  # Claude declined (policy)
ERROR_CODE_TRANSLATION_FAILED = "translation_failed"    # The translation call broke mid-stream


class ErrorMessage(BaseModel):
    """
    Error message.

    For a segment that couldn't be translated, code says why, segment_id matches
    the segment's transcript_final and original repeats its source text (the
    trailing clause of an utterance may never have had a transcript_final).
    """
    type: Literal["error"] = "error"
    direction: Optional[TranslationDirection] = None
    message: str
    recoverable: bool = True
    code: Optional[str] = None
    segment_id: Optional[str] = None
    original: Optional[str] = None


class StatusMessage(BaseModel):
    """Status message."""
    type: Literal["status"] = "status"
    status: str
    session_id: Optional[str] = None
    details: Optional[dict] = None


class GenderDetected(BaseModel):
    """Notification when gender is detected from audio."""
    type: Literal["gender_detected"] = "gender_detected"
    gender: Literal["male", "female"]
    direction: TranslationDirection
