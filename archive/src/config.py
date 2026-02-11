"""Configuration settings from environment variables."""

from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # API Keys
    deepgram_api_key: str = ""
    anthropic_api_key: str = ""
    elevenlabs_api_key: str = ""
    elevenlabs_voice_id: str = "21m00Tcm4TlvDq8ikWAM"  # Default voice

    # Logging
    log_level: str = "INFO"

    # Pipeline settings
    clause_timeout_ms: int = 3000
    max_buffer_chars: int = 100
    phrase_min_words: int = 3
    phrase_max_buffer_ms: int = 500

    # Translation context
    translation_context_window: int = 5

    # Audio settings
    sample_rate: int = 16000

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()
