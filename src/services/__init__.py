"""Shared services for both translation pipelines."""

from .stt import STTService, STTResult
from .tts import TTSService
from .translator import TranslatorService
from .phrase_buffer import PhraseBuffer
from .voice_detection import (
    detect_gender,
    detect_language,
    get_voice_id,
    GenderDetector,
    VOICES,
)

__all__ = [
    "STTService",
    "STTResult",
    "TTSService",
    "TranslatorService",
    "PhraseBuffer",
    "detect_gender",
    "detect_language",
    "get_voice_id",
    "GenderDetector",
    "VOICES",
]
