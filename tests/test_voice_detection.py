"""Tests for voice detection utilities."""

import numpy as np
import pytest

from src.services.voice_detection import (
    detect_language,
    get_voice_id,
    GenderDetector,
    VOICES,
    FEMALE_PITCH_THRESHOLD,
)


class TestDetectLanguage:
    """Tests for language detection."""

    def test_korean_text(self):
        """Test that Korean text is detected."""
        assert detect_language("안녕하세요") == "ko"
        assert detect_language("감사합니다") == "ko"
        assert detect_language("오늘 날씨가 좋습니다") == "ko"

    def test_english_text(self):
        """Test that English text is detected."""
        assert detect_language("Hello") == "en"
        assert detect_language("Hello, how are you?") == "en"
        assert detect_language("Thank you") == "en"
        assert detect_language("The weather is nice today") == "en"

    def test_mixed_text(self):
        """Test that mixed text returns Korean if Hangul present."""
        assert detect_language("Hello 안녕") == "ko"
        assert detect_language("Thank you 감사합니다") == "ko"

    def test_specific_cases(self):
        """Test specific cases from requirements."""
        assert detect_language("Hello, how are you?") == "en"
        assert detect_language("안녕하세요") == "ko"
        assert detect_language("Hello 안녕") == "ko"

    def test_empty_text(self):
        """Test that empty text returns English as default."""
        assert detect_language("") == "en"
        assert detect_language("   ") == "en"

    def test_numbers_and_punctuation(self):
        """Test that numbers/punctuation default to English."""
        assert detect_language("123") == "en"
        assert detect_language("!@#$%") == "en"


class TestGetVoiceId:
    """Tests for voice ID lookup."""

    def test_korean_female(self):
        """Test Korean female voice ID."""
        assert get_voice_id("ko", "female") == VOICES[("ko", "female")]

    def test_korean_male(self):
        """Test Korean male voice ID."""
        assert get_voice_id("ko", "male") == VOICES[("ko", "male")]

    def test_english_female(self):
        """Test English female voice ID."""
        assert get_voice_id("en", "female") == VOICES[("en", "female")]

    def test_english_male(self):
        """Test English male voice ID."""
        assert get_voice_id("en", "male") == VOICES[("en", "male")]

    def test_all_voice_ids_unique(self):
        """Test that all voice IDs are unique."""
        ids = list(VOICES.values())
        assert len(ids) == len(set(ids))


class TestGenderDetector:
    """Tests for the GenderDetector class."""

    def test_init(self):
        """Test detector initialization."""
        detector = GenderDetector()
        assert detector.sample_rate == 16000
        assert detector.detected_gender is None
        assert not detector.is_complete

    def test_custom_init(self):
        """Test detector with custom parameters."""
        detector = GenderDetector(
            sample_rate=44100,
            min_duration_seconds=2.0,
            max_duration_seconds=10.0,
        )
        assert detector.sample_rate == 44100
        assert detector.min_samples == 88200  # 44100 * 2.0
        assert detector.max_samples == 441000  # 44100 * 10.0

    def test_reset(self):
        """Test reset clears state."""
        detector = GenderDetector()
        # Add some audio
        audio = np.zeros(16000, dtype=np.int16).tobytes()
        detector.add_audio(audio)

        # Reset
        detector.reset()
        assert detector.detected_gender is None
        assert not detector.is_complete

    def test_add_short_audio_returns_none(self):
        """Test that short audio returns None (not enough for detection)."""
        detector = GenderDetector(min_duration_seconds=1.0)
        # Only 0.5 seconds of audio
        short_audio = np.zeros(8000, dtype=np.int16).tobytes()
        result = detector.add_audio(short_audio)
        assert result is None
        assert not detector.is_complete

    def test_buffer_accumulates_audio(self):
        """Test that audio is accumulated in the buffer."""
        detector = GenderDetector(min_duration_seconds=1.0)

        # Add 0.5 seconds of audio
        audio1 = np.zeros(8000, dtype=np.int16).tobytes()
        detector.add_audio(audio1)

        # Add another 0.5 seconds
        audio2 = np.zeros(8000, dtype=np.int16).tobytes()
        detector.add_audio(audio2)

        # Buffer should have accumulated audio
        # (if detection succeeded, buffer may be cleared, so check before detection)
        # In this case, 1 second >= min_duration, so detection should trigger
        assert detector.is_complete or len(detector._audio_buffer) >= len(audio1)

    def test_detection_complete_returns_cached(self):
        """Test that once detection is complete, cached result is returned."""
        detector = GenderDetector()
        detector._detection_complete = True
        detector._detected_gender = "male"

        result = detector.add_audio(b"any audio")
        assert result == "male"
        assert detector.is_complete


class TestVoiceConstants:
    """Tests for voice-related constants."""

    def test_female_pitch_threshold(self):
        """Test the pitch threshold is reasonable."""
        # Female pitch typically >= 165 Hz
        assert FEMALE_PITCH_THRESHOLD == 165.0

    def test_all_voices_defined(self):
        """Test all language/gender combinations have voices."""
        languages = ["ko", "en"]
        genders = ["male", "female"]

        for lang in languages:
            for gender in genders:
                assert (lang, gender) in VOICES
                assert VOICES[(lang, gender)]  # Non-empty string


class TestTextToVoiceId:
    """Tests for combined text→language detection→voice ID flow."""

    def test_english_female_voice(self):
        """Test English text with female gender returns correct voice ID."""
        text = "Hello there"
        lang = detect_language(text)
        voice_id = get_voice_id(lang, "female")
        assert voice_id == "M7baJQBjzMsrxxZ796H6"

    def test_korean_female_voice(self):
        """Test Korean text with female gender returns correct voice ID."""
        text = "안녕하세요"
        lang = detect_language(text)
        voice_id = get_voice_id(lang, "female")
        assert voice_id == "8jHHF8rMqMlg8if2mOUe"

    def test_english_male_voice(self):
        """Test English text with male gender returns correct voice ID."""
        text = "Hello"
        lang = detect_language(text)
        voice_id = get_voice_id(lang, "male")
        assert voice_id == "R13lt9tQ5Z8CcM2SDB1K"

    def test_korean_male_voice(self):
        """Test Korean text with male gender returns correct voice ID."""
        text = "안녕"
        lang = detect_language(text)
        voice_id = get_voice_id(lang, "male")
        assert voice_id == "pb3lVZVjdFWbkhPKlelB"

    def test_all_voice_combinations(self):
        """Test all text/gender combinations produce expected voice IDs."""
        test_cases = [
            ("Hello there", "female", "M7baJQBjzMsrxxZ796H6"),
            ("안녕하세요", "female", "8jHHF8rMqMlg8if2mOUe"),
            ("Hello", "male", "R13lt9tQ5Z8CcM2SDB1K"),
            ("안녕", "male", "pb3lVZVjdFWbkhPKlelB"),
        ]
        for text, gender, expected_voice_id in test_cases:
            lang = detect_language(text)
            voice_id = get_voice_id(lang, gender)
            assert voice_id == expected_voice_id, f"Failed for ({text}, {gender})"
