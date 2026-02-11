"""Pydantic models for the translation pipeline."""

from typing import Literal, Optional
from pydantic import BaseModel
from enum import Enum
import time


class ClassifierDecision(str, Enum):
    """Decision from the safety classifier."""
    SAFE = "SAFE"
    WAIT = "WAIT"


class Word(BaseModel):
    """A single word from STT."""
    text: str
    confidence: float = 1.0
    is_final: bool = True
    timestamp_ms: int = 0


class Clause(BaseModel):
    """A detected clause with its connector."""
    text: str
    connector: str
    connector_type: str  # 'sentence_final', 'question', 'connector', 'modifier', 'timeout'
    timestamp_ms: int = 0
    decision: Optional[ClassifierDecision] = None

    def __init__(self, **data):
        if "timestamp_ms" not in data:
            data["timestamp_ms"] = int(time.time() * 1000)
        super().__init__(**data)


# Client -> Server messages

class AudioChunk(BaseModel):
    """Audio chunk from client."""
    type: Literal["audio_chunk"] = "audio_chunk"
    data: bytes
    sample_rate: int = 16000
    format: Literal["pcm_s16le", "opus"] = "pcm_s16le"


class ControlMessage(BaseModel):
    """Control message from client."""
    type: Literal["control"] = "control"
    command: Literal["start", "stop", "flush"]


# Server -> Client messages

class TranscriptInterim(BaseModel):
    """Interim transcription for UI feedback."""
    type: Literal["transcript_interim"] = "transcript_interim"
    text: str  # Korean being heard


class ClauseDetected(BaseModel):
    """Notification of clause detection."""
    type: Literal["clause_detected"] = "clause_detected"
    text: str           # Korean clause
    connector: str      # What triggered detection
    decision: str       # SAFE or WAIT


class TranslationText(BaseModel):
    """Translation result."""
    type: Literal["translation"] = "translation"
    original: str       # Korean
    translated: str     # English
    latency_ms: int


class AudioOut(BaseModel):
    """Audio output chunk."""
    type: Literal["audio_out"] = "audio_out"
    data: bytes
    format: str = "mp3"


class SessionState(BaseModel):
    """State for a translation session."""
    session_id: str
    is_active: bool = False
    clause_buffer: str = ""
    translation_context: list[dict] = []  # Last N exchanges
    last_activity_ms: int = 0

    def __init__(self, **data):
        if "last_activity_ms" not in data:
            data["last_activity_ms"] = int(time.time() * 1000)
        super().__init__(**data)

    def update_activity(self):
        """Update last activity timestamp."""
        self.last_activity_ms = int(time.time() * 1000)

    def add_to_context(self, korean: str, english: str, max_context: int = 5):
        """Add a translation pair to context window."""
        self.translation_context.append({
            "korean": korean,
            "english": english,
        })
        # Keep only last N exchanges
        if len(self.translation_context) > max_context:
            self.translation_context = self.translation_context[-max_context:]
