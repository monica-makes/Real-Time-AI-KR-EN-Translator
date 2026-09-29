"""Offline tests for TranslatorService on Claude Sonnet 5.5 (no network).

Most tests inject a fake AsyncAnthropic-like client into TranslatorService._client.
A few run the real SDK against an in-process mock transport to check the wire
request and how the SDK hands stop_reason / stop_details / model back to us.
"""

import json
import logging
from types import SimpleNamespace

import anthropic
import httpx2
import pytest

from src.models import TranslationDirection
from src.services.translator import (
    EN_TO_KO_BASE_PROMPT,
    EN_TO_KO_HONORIFIC_PROMPT,
    KO_TO_EN_PROMPT,
    TRANSLATION_MODEL,
    TranslationRefused,
    TranslatorService,
)
from src.session.context import SharedTranslationContext
from tests.test_pipeline_audio import MP3_CHUNKS, PIPELINES, FakeTTS, make_pipeline

TRANSLATOR_LOGGER = "src.services.translator"
FALLBACK_MODEL = "claude-sonnet-5"


# --- Fake client ------------------------------------------------------------


def final_message(stop_reason="end_turn", category=None, model=TRANSLATION_MODEL, stop_details=None):
    """Scripted stand-in for the BetaMessage returned by get_final_message()."""
    if category is not None:
        stop_details = SimpleNamespace(type="refusal", category=category, explanation=None)
    return SimpleNamespace(stop_reason=stop_reason, stop_details=stop_details, model=model)


class Script:
    """One scripted response: the text tokens streamed, then the final message."""

    def __init__(self, tokens=(), final=None, raise_after=None, enter_error=None):
        self.tokens = list(tokens)
        self.final = final or final_message()
        self.raise_after = raise_after  # Exception raised after all tokens stream
        self.enter_error = enter_error  # Exception raised when opening the stream


class FakeStream:
    """Mimics BetaAsyncMessageStream: text_stream then get_final_message()."""

    def __init__(self, script: Script):
        self._script = script
        self.text_consumed = False
        self.final_requested = False

    @property
    def text_stream(self):
        async def gen():
            for token in self._script.tokens:
                yield token
            if self._script.raise_after:
                raise self._script.raise_after
            self.text_consumed = True

        return gen()

    async def get_final_message(self):
        self.final_requested = True
        return self._script.final


class FakeStreamManager:
    """Async context manager returned by beta.messages.stream(...)."""

    def __init__(self, script: Script):
        self.script = script
        self.stream = FakeStream(script)
        self.entered = False
        self.exited = False

    async def __aenter__(self):
        if self.script.enter_error:
            raise self.script.enter_error
        self.entered = True
        return self.stream

    async def __aexit__(self, exc_type, exc, tb):
        self.exited = True
        return False


class FakeBetaMessages:
    def __init__(self, scripts):
        self._scripts = list(scripts)
        self.calls: list[dict] = []
        self.managers: list[FakeStreamManager] = []

    def stream(self, **kwargs):
        self.calls.append(kwargs)
        script = self._scripts.pop(0) if len(self._scripts) > 1 else self._scripts[0]
        manager = FakeStreamManager(script)
        self.managers.append(manager)
        return manager


class FakeAnthropic:
    """Only exposes client.beta.messages - using client.messages would fail loudly."""

    def __init__(self, *scripts):
        self.beta = SimpleNamespace(messages=FakeBetaMessages(scripts or [Script(["ok"])]))

    @property
    def calls(self):
        return self.beta.messages.calls

    @property
    def managers(self):
        return self.beta.messages.managers


def make_service(client) -> TranslatorService:
    service = TranslatorService()
    service._client = client
    return service


async def collect(service, text, direction, context, **kwargs):
    tokens = []
    async for token in service.translate_stream(text, direction, context, **kwargs):
        tokens.append(token)
    return tokens


# --- Request shape -----------------------------------------------------------


def test_translation_model_is_sonnet_5_5():
    assert TRANSLATION_MODEL == "claude-sonnet-5-5"


@pytest.mark.asyncio
async def test_request_shape_for_sonnet_5_5():
    """Exact kwargs: model, max_tokens, between_tools, low effort, default fallbacks + matching beta."""
    client = FakeAnthropic(Script(["Hello"]))
    service = make_service(client)

    await collect(service, "안녕하세요", TranslationDirection.KO_TO_EN, SharedTranslationContext())

    assert len(client.calls) == 1
    kwargs = client.calls[0]
    # No temperature/top_p/top_k, tool_choice, or other stray fields
    assert set(kwargs) == {
        "model", "max_tokens", "thinking", "output_config", "betas", "fallbacks", "system", "messages",
    }
    assert kwargs["model"] == "claude-sonnet-5-5"
    assert kwargs["max_tokens"] == 1024
    # between_tools takes no other field (display / budget_tokens / block_binding are a 400)
    assert kwargs["thinking"] == {"type": "between_tools"}
    # between_tools requires effort high or below
    assert kwargs["output_config"] == {"effort": "low"}
    # The "default" scalar form pairs only with the 2026-07-01 header (the array form needs 2026-06-01)
    assert kwargs["fallbacks"] == "default"
    assert kwargs["betas"] == ["server-side-fallback-2026-07-01"]
    assert kwargs["messages"] == [{"role": "user", "content": "Translate: 안녕하세요"}]


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "direction, honorific, template, marker",
    [
        (TranslationDirection.KO_TO_EN, False, KO_TO_EN_PROMPT, "Korean to English"),
        (TranslationDirection.KO_TO_EN, True, KO_TO_EN_PROMPT, "Korean to English"),
        (TranslationDirection.EN_TO_KO, False, EN_TO_KO_BASE_PROMPT, "해요체"),
        (TranslationDirection.EN_TO_KO, True, EN_TO_KO_HONORIFIC_PROMPT, "높임말"),
    ],
    ids=["ko_to_en", "ko_to_en_honorific_ignored", "en_to_ko_base", "en_to_ko_honorific"],
)
async def test_system_prompt_per_direction(direction, honorific, template, marker):
    """System prompt follows the direction; honorific only switches the EN->KO prompt."""
    client = FakeAnthropic(Script(["x"]))
    service = make_service(client)

    await collect(service, "text", direction, SharedTranslationContext(), honorific_mode=honorific)

    system = client.calls[0]["system"]
    assert system == template.format(context="No previous context.")
    assert marker in system


@pytest.mark.asyncio
async def test_system_prompt_carries_previous_exchange():
    """The second request's system prompt includes the first exchange from the shared context."""
    client = FakeAnthropic(Script(["Hello"]), Script(["See you"]))
    service = make_service(client)
    context = SharedTranslationContext()

    await collect(service, "안녕하세요", TranslationDirection.KO_TO_EN, context)
    await collect(service, "내일 봐요", TranslationDirection.KO_TO_EN, context)

    second_system = client.calls[1]["system"]
    assert "Recent conversation:" in second_system
    assert "Korean: 안녕하세요" in second_system
    assert "English: Hello" in second_system


# --- Normal path -------------------------------------------------------------


@pytest.mark.asyncio
async def test_normal_path_yields_tokens_and_adds_one_exchange(caplog):
    client = FakeAnthropic(Script(["See", " you", " tomorrow."]))
    service = make_service(client)
    context = SharedTranslationContext()

    with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
        tokens = await collect(service, "내일 봐요", TranslationDirection.KO_TO_EN, context)

    assert tokens == ["See", " you", " tomorrow."]
    assert len(context) == 1
    exchange = context.exchanges[0]
    assert exchange.direction == TranslationDirection.KO_TO_EN
    assert exchange.source_text == "내일 봐요"
    assert exchange.translated_text == "See you tomorrow."
    # Final message is read after the text stream, and the stream is closed
    manager = client.managers[0]
    assert manager.stream.text_consumed and manager.stream.final_requested
    assert manager.exited
    assert "fallback" not in caplog.text
    assert not [r for r in caplog.records if r.levelno >= logging.WARNING]


@pytest.mark.asyncio
async def test_translate_concatenates_tokens():
    client = FakeAnthropic(Script(["내일", " 봬요", "."]))
    service = make_service(client)
    context = SharedTranslationContext()

    result = await service.translate(
        "See you tomorrow", TranslationDirection.EN_TO_KO, context, honorific_mode=True
    )

    assert result == "내일 봬요."
    assert len(context) == 1
    assert context.exchanges[0].translated_text == "내일 봬요."
    assert client.calls[0]["system"].startswith(EN_TO_KO_HONORIFIC_PROMPT.split("{context}")[0])


# --- Refusals ----------------------------------------------------------------


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "tokens, category, stop_details",
    [
        ([], "cyber", None),  # Classifier fires before any output
        (["I'll", " translate"], "general_harms", None),  # Fires mid-stream after partial output
        (["Partial"], None, None),  # stop_details can be null on a refusal
    ],
    ids=["pre_output", "mid_stream", "null_stop_details"],
)
async def test_refusal_raises_and_adds_nothing_to_context(caplog, tokens, category, stop_details):
    client = FakeAnthropic(Script(tokens, final_message("refusal", category=category, stop_details=stop_details)))
    service = make_service(client)
    context = SharedTranslationContext()
    yielded = []

    with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
        with pytest.raises(TranslationRefused) as excinfo:
            async for token in service.translate_stream("text", TranslationDirection.KO_TO_EN, context):
                yielded.append(token)

    # Partial tokens do stream before the refusal is known; none are saved
    assert yielded == tokens
    assert len(context) == 0
    assert excinfo.value.category == category
    assert client.managers[0].exited
    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert any("refused" in m and f"category={category}" in m for m in warnings)


@pytest.mark.asyncio
async def test_refusal_does_not_touch_existing_context():
    """A refusal after a good translation leaves only the good exchange in context."""
    client = FakeAnthropic(
        Script(["Hello"]),
        Script(["Hal"], final_message("refusal", category="general_harms")),
    )
    service = make_service(client)
    context = SharedTranslationContext()

    await collect(service, "안녕하세요", TranslationDirection.KO_TO_EN, context)
    with pytest.raises(TranslationRefused):
        await collect(service, "blocked", TranslationDirection.KO_TO_EN, context)

    assert [e.translated_text for e in context.exchanges] == ["Hello"]


@pytest.mark.asyncio
async def test_translate_propagates_refusal():
    client = FakeAnthropic(Script([], final_message("refusal", category="bio")))
    service = make_service(client)
    context = SharedTranslationContext()

    with pytest.raises(TranslationRefused):
        await service.translate("text", TranslationDirection.EN_TO_KO, context)
    assert len(context) == 0


@pytest.mark.asyncio
async def test_refusal_by_fallback_model_raises_without_served_by_log(caplog):
    """Whole fallback chain refused: raise, and don't claim the fallback served the reply."""
    final = final_message("refusal", category="cyber", model=FALLBACK_MODEL)
    client = FakeAnthropic(Script([], final))
    service = make_service(client)
    context = SharedTranslationContext()

    with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
        with pytest.raises(TranslationRefused):
            await collect(service, "text", TranslationDirection.KO_TO_EN, context)

    assert len(context) == 0
    assert "served by fallback" not in caplog.text


# --- max_tokens / fallback / errors -----------------------------------------


@pytest.mark.asyncio
async def test_max_tokens_returns_text_and_logs_warning(caplog):
    client = FakeAnthropic(Script(["A very long", " transl"], final_message("max_tokens")))
    service = make_service(client)
    context = SharedTranslationContext()

    with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
        result = await service.translate("long text", TranslationDirection.KO_TO_EN, context)

    assert result == "A very long transl"
    assert len(context) == 1
    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert any("truncated at max_tokens" in m for m in warnings)


@pytest.mark.asyncio
async def test_fallback_served_model_is_logged(caplog):
    client = FakeAnthropic(Script(["Hello"], final_message("end_turn", model=FALLBACK_MODEL)))
    service = make_service(client)
    context = SharedTranslationContext()

    with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
        result = await service.translate("안녕하세요", TranslationDirection.KO_TO_EN, context)

    assert result == "Hello"
    assert len(context) == 1
    infos = [r.getMessage() for r in caplog.records if r.levelno == logging.INFO]
    assert any(f"served by fallback model {FALLBACK_MODEL}" in m for m in infos)


@pytest.mark.asyncio
async def test_dated_model_id_is_not_logged_as_fallback(caplog):
    client = FakeAnthropic(Script(["Hello"], final_message("end_turn", model=f"{TRANSLATION_MODEL}-20260915")))
    service = make_service(client)

    with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
        await service.translate("안녕하세요", TranslationDirection.KO_TO_EN, SharedTranslationContext())

    assert "served by fallback" not in caplog.text


@pytest.mark.asyncio
async def test_fallback_message_iteration_is_logged(caplog):
    """usage.iterations is the documented served-by signal, whatever the model string says."""
    final = final_message("end_turn")
    final.usage = SimpleNamespace(iterations=[SimpleNamespace(type="message"), SimpleNamespace(type="fallback_message")])
    client = FakeAnthropic(Script(["Hello"], final))
    service = make_service(client)

    with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
        await service.translate("안녕하세요", TranslationDirection.KO_TO_EN, SharedTranslationContext())

    assert "served by fallback model" in caplog.text


@pytest.mark.asyncio
async def test_refusal_logs_one_warning_and_no_errors(caplog):
    details = SimpleNamespace(type="refusal", category="general_harms", explanation=None, recommended_model="claude-sonnet-5")
    client = FakeAnthropic(Script(["Par"], final_message("refusal", stop_details=details)))
    service = make_service(client)

    with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
        with pytest.raises(TranslationRefused) as excinfo:
            await collect(service, "text", TranslationDirection.KO_TO_EN, SharedTranslationContext())

    assert excinfo.value.recommended_model == "claude-sonnet-5"
    assert "category=general_harms" in str(excinfo.value)
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]
    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert len(warnings) == 1 and "recommended_model=claude-sonnet-5" in warnings[0]


@pytest.mark.asyncio
@pytest.mark.parametrize("where", ["open", "mid_stream"])
async def test_stream_error_propagates_and_adds_nothing(caplog, where):
    error = RuntimeError("connection dropped")
    script = Script(["Hel"], raise_after=error) if where == "mid_stream" else Script(enter_error=error)
    client = FakeAnthropic(script)
    service = make_service(client)
    context = SharedTranslationContext()

    with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
        with pytest.raises(RuntimeError, match="connection dropped"):
            await collect(service, "text", TranslationDirection.KO_TO_EN, context)

    assert len(context) == 0
    assert "Translation error: connection dropped" in caplog.text


# --- Real SDK over an in-process mock transport (still offline) --------------


def sse_body(events) -> bytes:
    return "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()


def sse_events(texts, stop_reason="end_turn", stop_details=None, model=TRANSLATION_MODEL, fallback_to=None):
    events = [{
        "type": "message_start",
        "message": {
            "id": "msg_test", "type": "message", "role": "assistant", "model": model,
            "content": [], "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": 12, "output_tokens": 1},
        },
    }]
    index = 0
    if fallback_to:
        # Pre-output server-side fallback: a fallback block first in content
        events += [
            {"type": "content_block_start", "index": 0, "content_block": {
                "type": "fallback", "from": {"model": model}, "to": {"model": fallback_to},
                "trigger": {"type": "refusal", "category": "cyber"},
            }},
            {"type": "content_block_stop", "index": 0},
        ]
        index = 1
    if texts:
        events.append({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}})
        events += [
            {"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": t}}
            for t in texts
        ]
        events.append({"type": "content_block_stop", "index": index})
    events += [
        {"type": "message_delta",
         "delta": {"stop_reason": stop_reason, "stop_sequence": None, "stop_details": stop_details},
         "usage": {"output_tokens": 7}},
        {"type": "message_stop"},
    ]
    return events


class MockAPI:
    """Real AsyncAnthropic whose HTTP layer is an in-process MockTransport."""

    def __init__(self, events):
        self.events = events
        self.requests: list = []
        self.http = httpx2.AsyncClient(transport=httpx2.MockTransport(self._handle))
        self.client = anthropic.AsyncAnthropic(api_key="test-key", http_client=self.http, max_retries=0)

    def _handle(self, request):
        self.requests.append(request)
        return httpx2.Response(
            200, headers={"content-type": "text/event-stream"}, content=sse_body(self.events)
        )

    async def aclose(self):
        await self.client.close()


@pytest.mark.asyncio
async def test_sdk_wire_request_shape():
    """The installed SDK sends the Sonnet 5.5 fields in the body and betas as a header."""
    api = MockAPI(sse_events(["Hello", "."]))
    service = make_service(api.client)
    try:
        result = await service.translate("안녕하세요.", TranslationDirection.KO_TO_EN, SharedTranslationContext())
    finally:
        await api.aclose()

    assert result == "Hello."
    assert len(api.requests) == 1
    request = api.requests[0]
    assert request.url.path == "/v1/messages"
    assert request.url.params.get("beta") == "true"
    assert request.headers["anthropic-beta"] == "server-side-fallback-2026-07-01"
    body = json.loads(request.content)
    assert body["model"] == "claude-sonnet-5-5"
    assert body["max_tokens"] == 1024
    assert body["thinking"] == {"type": "between_tools"}
    assert body["output_config"] == {"effort": "low"}
    assert body["fallbacks"] == "default"
    assert body["stream"] is True
    assert "betas" not in body
    assert body["messages"] == [{"role": "user", "content": "Translate: 안녕하세요."}]


@pytest.mark.asyncio
async def test_sdk_mid_stream_refusal_is_detected():
    """stop_reason / stop_details from message_delta reach get_final_message() in the real SDK."""
    stop_details = {"type": "refusal", "category": "general_harms", "explanation": None}
    api = MockAPI(sse_events(["Partial", " text"], stop_reason="refusal", stop_details=stop_details))
    service = make_service(api.client)
    context = SharedTranslationContext()
    yielded = []
    try:
        with pytest.raises(TranslationRefused) as excinfo:
            async for token in service.translate_stream("text", TranslationDirection.KO_TO_EN, context):
                yielded.append(token)
    finally:
        await api.aclose()

    assert yielded == ["Partial", " text"]
    assert excinfo.value.category == "general_harms"
    assert len(context) == 0


@pytest.mark.asyncio
async def test_sdk_pre_output_refusal_is_detected():
    api = MockAPI(sse_events([], stop_reason="refusal", stop_details={"type": "refusal", "category": "cyber"}))
    service = make_service(api.client)
    context = SharedTranslationContext()
    try:
        with pytest.raises(TranslationRefused):
            await service.translate("text", TranslationDirection.EN_TO_KO, context)
    finally:
        await api.aclose()

    assert len(context) == 0


@pytest.mark.asyncio
async def test_sdk_fallback_block_relabels_model_and_is_logged(caplog):
    """A fallback content block makes the final message name the serving model."""
    api = MockAPI(sse_events(["Hello"], fallback_to=FALLBACK_MODEL))
    service = make_service(api.client)
    context = SharedTranslationContext()
    try:
        with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
            result = await service.translate("안녕하세요", TranslationDirection.KO_TO_EN, context)
    finally:
        await api.aclose()

    assert result == "Hello"
    assert len(context) == 1
    assert f"served by fallback model {FALLBACK_MODEL}" in caplog.text


@pytest.mark.asyncio
async def test_sdk_mid_stream_fallback_keeps_partial_and_continuation(caplog):
    """Mid-stream decline + server-side fallback: the partial and the continuation arrive on one stream."""
    events = sse_events([])[:1] + [
        {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "See you"}},
        {"type": "content_block_stop", "index": 0},
        {"type": "content_block_start", "index": 1, "content_block": {
            "type": "fallback", "from": {"model": TRANSLATION_MODEL}, "to": {"model": FALLBACK_MODEL},
            "trigger": {"type": "refusal", "category": "cyber"},
        }},
        {"type": "content_block_stop", "index": 1},
        {"type": "content_block_start", "index": 2, "content_block": {"type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 2, "delta": {"type": "text_delta", "text": " tomorrow."}},
        {"type": "content_block_stop", "index": 2},
    ] + sse_events([])[-2:]
    api = MockAPI(events)
    service = make_service(api.client)
    context = SharedTranslationContext()
    try:
        with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
            tokens = await collect(service, "내일 봐요", TranslationDirection.KO_TO_EN, context)
    finally:
        await api.aclose()

    assert tokens == ["See you", " tomorrow."]
    assert [e.translated_text for e in context.exchanges] == ["See you tomorrow."]
    assert f"served by fallback model {FALLBACK_MODEL}" in caplog.text


@pytest.mark.asyncio
async def test_sdk_max_tokens_is_logged(caplog):
    api = MockAPI(sse_events(["Trunc"], stop_reason="max_tokens"))
    service = make_service(api.client)
    try:
        with caplog.at_level(logging.INFO, logger=TRANSLATOR_LOGGER):
            result = await service.translate("text", TranslationDirection.KO_TO_EN, SharedTranslationContext())
    finally:
        await api.aclose()

    assert result == "Trunc"
    assert "truncated at max_tokens" in caplog.text


# --- Pipelines ---------------------------------------------------------------


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", PIPELINES)
@pytest.mark.parametrize(
    "refused_tokens",
    [[], ["partial", " words"]],  # No phrase boundary, so nothing reaches TTS before the refusal
    ids=["pre_output", "mid_stream"],
)
async def test_pipeline_refusal_emits_no_translation_and_clears_phrase_buffer(caplog, kind, refused_tokens):
    """A refused segment emits no TranslationResult or audio, and its partial never leaks into the next one."""
    client = FakeAnthropic(
        Script(refused_tokens, final_message("refusal", category="general_harms")),
        Script(["Hello there."]),
    )
    tts = FakeTTS(MP3_CHUNKS)
    pipeline, audio_out, translations = make_pipeline(kind, translator=make_service(client), tts=tts)
    text = PIPELINES[kind][2]

    with caplog.at_level(logging.INFO):
        await pipeline._translate_and_speak(text, "seg-refused")

    # An expected policy decline is a warning, not an error
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert any("seg-refused not translated" in r.getMessage() for r in caplog.records)
    assert translations == []
    assert audio_out == []
    assert pipeline.phrase_buffer.is_empty
    assert len(pipeline.context) == 0

    # The next segment is spoken without the refused partial glued on
    await pipeline._translate_and_speak(text, "seg-next")

    assert [t.translated for t in translations] == ["Hello there."]
    assert [t.segment_id for t in translations] == ["seg-next"]
    assert tts.phrases == ["Hello there."]
    assert len(audio_out) == 1
    assert len(pipeline.context) == 1
