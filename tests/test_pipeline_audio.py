"""Offline tests for pipeline audio emission, stop() finalize ordering and routing (fakes only)."""

import asyncio
import base64
import json
import time

import pytest

from src.config import Settings
from src.models import TranslationDirection
from src.pipelines import KrToEnPipeline, EnToKrPipeline
from src.pipelines.base import WordBoundaryPhraseBuffer
from src.services.stt import STTResult
from src.session.context import SharedTranslationContext

MP3_CHUNKS = [b"ID3\x04\x00", b"\xff\xfb\x90\x00frame-1", b"\xff\xfb\x90\x00frame-2"]

PIPELINES = {
    "kr_to_en": (KrToEnPipeline, TranslationDirection.KO_TO_EN, "안녕하세요", "en"),
    "en_to_kr": (EnToKrPipeline, TranslationDirection.EN_TO_KO, "See you tomorrow", "ko"),
}

# Per direction: (punctuated first utterance, second utterance's first word, second utterance)
UTTERANCES = {
    "kr_to_en": ("안녕하세요.", "오늘", "오늘 날씨가 정말 좋네요."),
    "en_to_kr": ("Hello there.", "See", "See you tomorrow."),
}

# Per direction: (unpunctuated final, speech_final final, text the detector buffers)
UNPUNCTUATED = {
    "kr_to_en": ("오늘", "날씨", "오늘날씨"),
    "en_to_kr": ("see you", "tomorrow", "see you tomorrow"),
}


async def wait_until(predicate, timeout: float = 2.0) -> None:
    """Poll until predicate() is true or fail after timeout."""
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met before timeout")
        await asyncio.sleep(0.01)


class FakeSTT:
    """Stands in for STTService; finalize() delivers trailing results like Deepgram does."""

    def __init__(self):
        self.result_queue: asyncio.Queue = asyncio.Queue()
        self.sent_audio: list[bytes] = []
        self.finalize_results: list[STTResult] = []
        self.during_finalize = None
        self.finalized = False
        self.disconnected = False

    async def connect(self) -> None:
        pass

    async def send_audio(self, audio_data: bytes) -> None:
        self.sent_audio.append(audio_data)

    async def get_results(self):
        while True:
            yield await self.result_queue.get()

    async def finalize(self) -> None:
        self.finalized = True
        if self.during_finalize:
            await self.during_finalize()
        # Trailing finals arrive shortly after the finalize signal
        loop = asyncio.get_running_loop()
        for result in self.finalize_results:
            loop.call_later(0.01, self.result_queue.put_nowait, result)
        await asyncio.sleep(0.05)

    async def disconnect(self) -> None:
        self.disconnected = True


class FakeTranslator:
    """Streams fixed tokens, slowly enough that stop() must wait for it."""

    def __init__(self, tokens=("Hello", " there."), delay_s: float = 0.02):
        self.tokens = tokens
        self.delay_s = delay_s
        self.calls: list[str] = []

    async def translate_stream(self, text, direction, context, **kwargs):
        self.calls.append(text)
        for token in self.tokens:
            await asyncio.sleep(self.delay_s)
            yield token


class FailingTranslator:
    """Yields a partial phrase (no break character) then fails mid-stream."""

    async def translate_stream(self, text, direction, context, **kwargs):
        yield "partial words"
        raise RuntimeError("translation stream dropped")


class FakeTTS:
    """Yields fixed audio chunks for every phrase."""

    def __init__(self, chunks):
        self.chunks = chunks
        self.phrases: list[str] = []

    async def synthesize_stream(self, text, language=None, gender_override=None):
        self.phrases.append(text)
        for chunk in self.chunks:
            yield chunk


class FailingTTS:
    """Yields one chunk then fails."""

    async def synthesize_stream(self, text, language=None, gender_override=None):
        yield b"\xff\xfb\x90\x00partial"
        raise RuntimeError("tts stream dropped")


def make_pipeline(kind, stt=None, translator=None, tts=None):
    """Build a pipeline wired to fakes; returns (pipeline, audio_out, translations)."""
    pipeline_cls = PIPELINES[kind][0]
    audio_out, translations = [], []
    pipeline = pipeline_cls(
        context=SharedTranslationContext(),
        stt=stt or FakeSTT(),
        translator=translator or FakeTranslator(),
        tts=tts or FakeTTS(MP3_CHUNKS),
        on_translation=translations.append,
        on_audio=audio_out.append,
    )
    return pipeline, audio_out, translations


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_synthesize_and_emit_emits_one_complete_mp3(kind):
    """All TTS chunks for a phrase are joined into a single AudioOut."""
    pipeline, audio_out, _ = make_pipeline(kind)
    target_lang = PIPELINES[kind][3]

    await pipeline._synthesize_and_emit("Hello there.", target_lang)

    assert len(audio_out) == 1
    assert audio_out[0].data == b"".join(MP3_CHUNKS)
    assert audio_out[0].format == "mp3"
    assert audio_out[0].direction == PIPELINES[kind][1]


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
@pytest.mark.parametrize("chunks", [[], [b""]], ids=["no_chunks", "empty_chunk"])
async def test_synthesize_and_emit_skips_empty_audio(kind, chunks):
    """Nothing is emitted when TTS produces no audio."""
    pipeline, audio_out, _ = make_pipeline(kind, tts=FakeTTS(chunks))

    await pipeline._synthesize_and_emit("Hello there.", PIPELINES[kind][3])

    assert audio_out == []


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_synthesize_and_emit_swallows_tts_error(kind):
    """A TTS failure is logged, not raised, and emits no partial clip."""
    pipeline, audio_out, _ = make_pipeline(kind, tts=FailingTTS())

    await pipeline._synthesize_and_emit("Hello there.", PIPELINES[kind][3])

    assert audio_out == []


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_stop_processes_final_result_delivered_during_finalize(kind):
    """A final transcript that arrives after the user taps Stop is still translated and spoken."""
    stt = FakeSTT()
    pipeline, audio_out, translations = make_pipeline(kind, stt=stt)
    text = PIPELINES[kind][2]
    await pipeline.start()

    stt.finalize_results = [STTResult(text=text, is_final=True)]

    async def send_late_audio():
        await pipeline.process_audio(b"late-audio")

    stt.during_finalize = send_late_audio

    await asyncio.wait_for(pipeline.stop(), timeout=5)

    assert stt.finalized
    assert [t.original for t in translations] == [text]
    assert len(audio_out) == 1
    assert audio_out[0].data == b"".join(MP3_CHUNKS)
    # Audio arriving while stopping is rejected
    assert stt.sent_audio == []
    assert stt.disconnected
    assert not pipeline.is_running
    assert all(task.done() for task in pipeline._tasks)


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_stop_waits_for_result_already_being_processed(kind):
    """stop() lets an in-flight translation finish instead of cancelling it."""
    stt = FakeSTT()
    translator = FakeTranslator(delay_s=0.1)
    pipeline, audio_out, translations = make_pipeline(kind, stt=stt, translator=translator)
    text = PIPELINES[kind][2]
    await pipeline.start()

    await stt.result_queue.put(STTResult(text=text, is_final=True))
    await stt.result_queue.put(STTResult(text="", is_final=True, is_utterance_end=True))
    await asyncio.sleep(0.05)  # Results loop is now mid-translation

    await asyncio.wait_for(pipeline.stop(), timeout=5)

    assert [t.original for t in translations] == [text]
    assert len(audio_out) == 1


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_process_audio_forwards_while_running(kind):
    """process_audio still forwards audio to STT during normal operation."""
    stt = FakeSTT()
    pipeline, _, _ = make_pipeline(kind, stt=stt)
    await pipeline.start()
    try:
        await pipeline.process_audio(b"chunk")
        assert stt.sent_audio == [b"chunk"]
    finally:
        await asyncio.wait_for(pipeline.stop(), timeout=5)


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_translate_failure_clears_phrase_buffer(kind):
    """A mid-stream translation failure drops buffered tokens so they don't leak into the next utterance."""
    pipeline, audio_out, translations = make_pipeline(kind, translator=FailingTranslator())

    await pipeline._translate_and_speak(PIPELINES[kind][2], "seg1")

    assert pipeline.phrase_buffer.is_empty
    assert audio_out == []
    assert translations == []


@pytest.mark.asyncio
async def test_ko_punctuated_final_translated_without_utterance_end():
    """A punctuated Korean final ("안녕하세요.") is translated when it arrives, not at the next UtteranceEnd."""
    stt = FakeSTT()
    translator = FakeTranslator()
    pipeline, audio_out, _ = make_pipeline("kr_to_en", stt=stt, translator=translator)
    await pipeline.start()
    try:
        await stt.result_queue.put(STTResult(text="안녕하세요.", is_final=True))
        await wait_until(lambda: len(audio_out) == 1)
        assert translator.calls == ["안녕하세요."]
    finally:
        await asyncio.wait_for(pipeline.stop(), timeout=5)


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_speech_final_flushes_without_utterance_end(kind):
    """An unpunctuated utterance is translated at Deepgram's end of speech (mic paused, no UtteranceEnd)."""
    stt = FakeSTT()
    translator = FakeTranslator()
    pipeline, audio_out, _ = make_pipeline(kind, stt=stt, translator=translator)
    first, last, buffered = UNPUNCTUATED[kind]
    await pipeline.start()
    try:
        await stt.result_queue.put(STTResult(text=first, is_final=True))
        await asyncio.sleep(0.05)
        assert translator.calls == []

        await stt.result_queue.put(STTResult(text=last, is_final=True, speech_final=True))
        await wait_until(lambda: len(audio_out) == 1)
        assert translator.calls == [buffered]
    finally:
        await asyncio.wait_for(pipeline.stop(), timeout=5)


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_late_utterance_end_does_not_glue_next_utterance(kind):
    """An UtteranceEnd arriving after the next utterance's first interim doesn't translate that interim early."""
    stt = FakeSTT()
    translator = FakeTranslator()
    pipeline, audio_out, _ = make_pipeline(kind, stt=stt, translator=translator)
    first, next_interim, second = UTTERANCES[kind]
    await pipeline.start()
    try:
        await stt.result_queue.put(
            STTResult(text=first, is_final=True, timestamp_ms=1000, speech_final=True)
        )
        await wait_until(lambda: len(translator.calls) == 1)

        # Mic paused, then resumed: the old utterance's UtteranceEnd only arrives
        # after the new utterance's first interim
        await stt.result_queue.put(STTResult(text=next_interim, is_final=False, timestamp_ms=5000))
        await stt.result_queue.put(
            STTResult(text="", is_final=True, is_utterance_end=True, last_word_end_ms=2400)
        )
        await stt.result_queue.put(
            STTResult(text=second, is_final=True, timestamp_ms=5000, speech_final=True)
        )
        await wait_until(lambda: len(translator.calls) >= 2)
        await asyncio.sleep(0.1)

        expected_second = second.replace(" ", "") if kind == "kr_to_en" else second
        assert translator.calls == [first, expected_second]
        assert len(audio_out) == 2
    finally:
        await asyncio.wait_for(pipeline.stop(), timeout=5)


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
@pytest.mark.parametrize("last_word_end_ms", [1300, None], ids=["with_last_word_end", "no_last_word_end"])
async def test_utterance_end_still_translates_interim_only_speech(kind, last_word_end_ms):
    """Short speech that only produced an interim is still translated at its UtteranceEnd."""
    stt = FakeSTT()
    translator = FakeTranslator()
    pipeline, audio_out, _ = make_pipeline(kind, stt=stt, translator=translator)
    word = "네" if kind == "kr_to_en" else "yes"
    await pipeline.start()
    try:
        await stt.result_queue.put(STTResult(text=word, is_final=False, timestamp_ms=1000))
        await stt.result_queue.put(
            STTResult(text="", is_final=True, is_utterance_end=True, last_word_end_ms=last_word_end_ms)
        )
        await wait_until(lambda: len(audio_out) == 1)
        assert translator.calls == [word]
    finally:
        await asyncio.wait_for(pipeline.stop(), timeout=5)


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_stop_translates_final_arriving_during_flush(kind):
    """A final that arrives while stop() is flushing is translated, not dropped when the loop is cancelled."""
    stt = FakeSTT()
    translator = FakeTranslator(delay_s=0.15)  # stop()'s flush takes ~0.3 s
    pipeline, _, translations = make_pipeline(kind, stt=stt, translator=translator)
    pending_interim = UNPUNCTUATED[kind][1]
    late_text = UTTERANCES[kind][0]
    await pipeline.start()

    # Pending interim -> stop()'s flush translates it
    await stt.result_queue.put(STTResult(text=pending_interim, is_final=False))
    await asyncio.sleep(0.05)
    # A late final (e.g. a slow Finalize reply) arrives mid-flush
    asyncio.get_running_loop().call_later(
        0.2, stt.result_queue.put_nowait, STTResult(text=late_text, is_final=True)
    )

    await asyncio.wait_for(pipeline.stop(), timeout=5)

    assert [t.original for t in translations] == [pending_interim, late_text]
    assert stt.disconnected


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_stop_cleans_up_when_flush_raises(kind):
    """stop() still cancels the results loop and disconnects STT if the final flush fails."""
    stt = FakeSTT()
    pipeline, _, _ = make_pipeline(kind, stt=stt)
    await pipeline.start()

    async def failing_flush(utterance_end_ms=None):
        raise RuntimeError("flush failed")

    pipeline._flush_remaining = failing_flush

    await asyncio.wait_for(pipeline.stop(), timeout=5)

    assert stt.disconnected
    assert not pipeline.is_running
    assert all(task.done() for task in pipeline._tasks)


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
async def test_stop_cleans_up_when_cancelled(kind):
    """stop() still cancels the results loop and disconnects STT if it is cancelled mid-finalize."""
    stt = FakeSTT()
    pipeline, _, _ = make_pipeline(kind, stt=stt)
    await pipeline.start()

    async def slow_finalize():
        await asyncio.sleep(1)

    stt.during_finalize = slow_finalize
    stop_task = asyncio.create_task(pipeline.stop())
    await asyncio.sleep(0.05)
    stop_task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await stop_task

    assert stt.disconnected
    assert not pipeline.is_running
    assert all(task.done() for task in pipeline._tasks)


def test_phrase_timeout_keeps_partial_word_for_next_phrase():
    """A timeout release ends at the last space; the possibly incomplete word starts the next phrase."""
    buffer = WordBoundaryPhraseBuffer(min_chars=5, max_buffer_ms=100)
    assert buffer.add_token("큰 커피 한 잔") is None
    buffer._buffer_start -= 1.0  # Simulate 1 s of buffering

    assert buffer.add_token(" 주문") == "큰 커피 한 잔"
    assert buffer.current_content == "주문"
    assert buffer.add_token("할게요.") == "주문할게요."
    assert buffer.is_empty


def test_phrase_timeout_holds_text_without_word_boundary():
    """With no space yet, a timeout release waits for the next boundary instead of splitting."""
    buffer = WordBoundaryPhraseBuffer(min_chars=5, max_buffer_ms=100)
    assert buffer.add_token("abcdefgh") is None
    buffer._buffer_start -= 1.0

    assert buffer.add_token("ij") is None
    assert buffer.current_content == "abcdefghij"
    assert buffer.add_token(" next") == "abcdefghij"
    assert buffer.force_flush() == "next"


def test_phrase_natural_breaks_unchanged():
    """Punctuation and trailing-space releases are passed through as-is."""
    buffer = WordBoundaryPhraseBuffer(min_chars=5, max_buffer_ms=100)
    assert buffer.add_token("Hello there,") == "Hello there,"
    buffer.add_token("see you")
    buffer._buffer_start -= 1.0
    assert buffer.add_token(" soon ") == "see you soon "
    assert buffer.is_empty


class FakeWebSocket:
    """Records text frames sent to it."""

    def __init__(self):
        self.sent: list[str] = []

    async def send_text(self, text: str) -> None:
        self.sent.append(text)


@pytest.mark.asyncio
async def test_routed_audio_includes_mp3_format():
    """Audio routed to a room partner carries the same format field as the solo path."""
    from src.main import ConversationRoom

    room = ConversationRoom("TEST01")
    listener = FakeWebSocket()
    room.participants["en"] = listener

    await room.route_translation_output("ko_to_en", b"mp3-bytes")

    assert len(listener.sent) == 1
    assert json.loads(listener.sent[0]) == {
        "type": "audio",
        "direction": "ko_to_en",
        "format": "mp3",
        "data": base64.b64encode(b"mp3-bytes").decode(),
    }


def test_server_address_defaults(monkeypatch):
    """Server binds 0.0.0.0:8001 by default to match the iOS app."""
    monkeypatch.delenv("HOST", raising=False)
    monkeypatch.delenv("PORT", raising=False)
    settings = Settings(_env_file=None)
    assert settings.host == "0.0.0.0"
    assert settings.port == 8001


def test_server_address_from_env(monkeypatch):
    """HOST/PORT environment variables override the server address."""
    monkeypatch.setenv("HOST", "127.0.0.1")
    monkeypatch.setenv("PORT", "9123")
    settings = Settings(_env_file=None)
    assert settings.host == "127.0.0.1"
    assert settings.port == 9123
