"""Voice detection utilities for gender and language detection."""

import io
import logging
import re
from typing import Literal, Optional

import numpy as np

logger = logging.getLogger(__name__)

# Voice mapping based on detected gender + language
VOICES = {
    ("ko", "female"): "8jHHF8rMqMlg8if2mOUe",
    ("ko", "male"): "pb3lVZVjdFWbkhPKlelB",
    ("en", "female"): "M7baJQBjzMsrxxZ796H6",
    ("en", "male"): "R13lt9tQ5Z8CcM2SDB1K",
}

# Gender pitch thresholds (Hz)
# Women typically speak at 165-255 Hz, men at 85-180 Hz
FEMALE_PITCH_THRESHOLD = 165.0  # If median pitch >= this, classify as female

# Korean Hangul Unicode range
HANGUL_PATTERN = re.compile(r"[\uAC00-\uD7AF]")


def detect_gender(
    audio_bytes: bytes,
    sample_rate: int = 16000,
) -> Literal["male", "female"]:
    """
    Detect gender from audio using pitch analysis.

    Uses median pitch to classify:
    - >= 165 Hz: female
    - < 165 Hz: male

    Args:
        audio_bytes: Raw audio bytes (PCM 16-bit).
        sample_rate: Audio sample rate in Hz.

    Returns:
        "male" or "female". Defaults to "female" if detection fails.
    """
    try:
        # Import librosa here to avoid loading it if not needed
        import librosa

        # Convert bytes to numpy array (assuming PCM 16-bit signed)
        audio_data = np.frombuffer(audio_bytes, dtype=np.int16)

        # Normalize to float32 in range [-1, 1]
        audio_float = audio_data.astype(np.float32) / 32768.0

        # Skip if audio is too short (need at least 0.1 seconds)
        min_samples = int(sample_rate * 0.1)
        if len(audio_float) < min_samples:
            logger.info("Audio too short for pitch detection, defaulting to female")
            return "female"

        # Extract pitch using librosa's yin algorithm
        # yin is more accurate for fundamental frequency detection than pyin
        # Use frame_length=1024 for better detection with 16kHz audio
        f0 = librosa.yin(
            audio_float,
            fmin=50,   # Minimum frequency to consider
            fmax=300,  # Maximum frequency
            sr=sample_rate,
            frame_length=1024,
        )

        # Filter to valid pitches in speech range (75-300 Hz)
        valid_pitches = f0[(f0 >= 75) & (f0 <= 300)]

        if len(valid_pitches) == 0:
            logger.info("No valid pitches in speech range, defaulting to female")
            return "female"

        # Calculate median pitch from filtered values
        median_pitch = np.median(valid_pitches)
        num_valid_frames = len(valid_pitches)

        # Classify based on threshold
        gender = "female" if median_pitch >= FEMALE_PITCH_THRESHOLD else "male"

        logger.info(
            f"Gender detection: median_pitch={median_pitch:.1f}Hz, threshold={FEMALE_PITCH_THRESHOLD}Hz, "
            f"valid_frames={num_valid_frames} -> {gender}"
        )

        return gender

    except ImportError:
        logger.warning("librosa not installed, defaulting to female")
        return "female"
    except Exception as e:
        logger.error(f"Gender detection failed: {e}, defaulting to female")
        return "female"


def detect_language(text: str) -> Literal["ko", "en"]:
    """
    Detect language from text by checking for Korean Hangul characters.

    Args:
        text: Text to analyze.

    Returns:
        "ko" if Korean Hangul characters are present, "en" otherwise.
    """
    if not text:
        return "en"

    # Check for Korean Hangul characters (Unicode range AC00-D7AF)
    if HANGUL_PATTERN.search(text):
        return "ko"

    return "en"


def get_voice_id(
    language: Literal["ko", "en"],
    gender: Literal["male", "female"],
) -> str:
    """
    Get the ElevenLabs voice ID for a given language and gender.

    Args:
        language: Target language ("ko" or "en").
        gender: Detected or overridden gender ("male" or "female").

    Returns:
        ElevenLabs voice ID.
    """
    return VOICES.get((language, gender), VOICES[("en", "female")])


class GenderDetector:
    """
    Accumulates audio samples for more accurate gender detection.

    Stores audio chunks and performs detection when enough data is collected.
    """

    def __init__(
        self,
        sample_rate: int = 16000,
        min_duration_seconds: float = 2.0,  # Lowered from 3s to handle shorter audio
        max_duration_seconds: float = 5.0,
        default_gender: Literal["male", "female"] = "female",
    ):
        """
        Initialize the gender detector.

        Args:
            sample_rate: Audio sample rate in Hz.
            min_duration_seconds: Minimum audio duration before detection.
            max_duration_seconds: Maximum audio to accumulate.
            default_gender: Gender to use if audio is too short for detection.
        """
        self.sample_rate = sample_rate
        self.min_samples = int(sample_rate * min_duration_seconds)
        self.max_samples = int(sample_rate * max_duration_seconds)
        self.default_gender = default_gender
        self._audio_buffer: bytes = b""
        self._detected_gender: Optional[Literal["male", "female"]] = None
        self._detection_complete = False

    def add_audio(self, audio_bytes: bytes) -> Optional[Literal["male", "female"]]:
        """
        Add audio chunk and attempt gender detection.

        Args:
            audio_bytes: Raw audio bytes to add.

        Returns:
            Detected gender if detection is complete, None otherwise.
        """
        if self._detection_complete:
            return self._detected_gender

        self._audio_buffer += audio_bytes

        # Check if we have enough audio (2 bytes per sample for 16-bit PCM)
        current_samples = len(self._audio_buffer) // 2

        if current_samples >= self.min_samples:
            # Perform detection
            self._detected_gender = detect_gender(
                self._audio_buffer,
                self.sample_rate,
            )
            self._detection_complete = True
            logger.info(f"Gender detection complete: {self._detected_gender}")
            return self._detected_gender

        # Trim buffer if too long
        max_bytes = self.max_samples * 2
        if len(self._audio_buffer) > max_bytes:
            self._audio_buffer = self._audio_buffer[-max_bytes:]

        return None

    @property
    def detected_gender(self) -> Optional[Literal["male", "female"]]:
        """Get the detected gender, or None if not yet detected."""
        return self._detected_gender

    @property
    def is_complete(self) -> bool:
        """Check if gender detection is complete."""
        return self._detection_complete

    def reset(self) -> None:
        """Reset the detector for a new detection."""
        self._audio_buffer = b""
        self._detected_gender = None
        self._detection_complete = False

    def finalize_with_default(self) -> Literal["male", "female"]:
        """
        Finalize detection using default gender if not enough audio was collected.

        Call this when audio stream ends but detection hasn't completed.

        Returns:
            The detected gender, or default if detection wasn't possible.
        """
        if self._detection_complete:
            return self._detected_gender

        # Try detection with whatever audio we have
        current_samples = len(self._audio_buffer) // 2
        if current_samples > 0:
            # Attempt detection even with less audio
            self._detected_gender = detect_gender(
                self._audio_buffer,
                self.sample_rate,
            )
            if self._detected_gender:
                logger.info(f"Gender detection (short audio): {self._detected_gender}")
                self._detection_complete = True
                return self._detected_gender

        # Fall back to default
        self._detected_gender = self.default_gender
        self._detection_complete = True
        logger.info(f"Gender detection using default: {self._detected_gender}")
        return self._detected_gender
