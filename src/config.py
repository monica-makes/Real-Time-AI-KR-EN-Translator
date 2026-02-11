"""Configuration settings from environment variables."""

from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # API Keys
    deepgram_api_key: str = ""
    anthropic_api_key: str = ""
    elevenlabs_api_key: str = ""

    # ElevenLabs Voice IDs
    elevenlabs_korean_voice_id: str = "21m00Tcm4TlvDq8ikWAM"
    elevenlabs_english_voice_id: str = "21m00Tcm4TlvDq8ikWAM"

    # Logging
    log_level: str = "INFO"

    # Korean -> English pipeline settings
    ko_clause_timeout_ms: int = 3000
    ko_pause_threshold_ms: int = 300
    ko_max_buffer_chars: int = 100

    # English -> Korean pipeline settings
    en_pause_threshold_ms: int = 500
    en_timeout_ms: int = 3000
    en_max_buffer_words: int = 25

    # Phrase buffer settings
    phrase_min_chars: int = 10
    phrase_max_buffer_ms: int = 500

    # Translation context
    max_context_exchanges: int = 10

    # Audio settings
    sample_rate: int = 16000

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()
