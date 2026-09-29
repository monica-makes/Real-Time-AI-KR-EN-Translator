"""Offline tests for /ws/translate rooms: cleanup, disconnects and partner delivery (scripted sockets, fake orchestrator)."""

import asyncio
import base64
import json
import logging
import time

import pytest

from src import main as main_module
from src.main import BidirectionalOrchestrator, ConversationRoom, rooms, websocket_translate
from src.models import (
    AudioOut,
    ClassifierDecision,
    ErrorMessage,
    ERROR_CODE_TRANSLATION_FAILED,
    ERROR_CODE_TRANSLATION_REFUSED,
    GenderDetected,
    TranscriptFinal,
    TranscriptInterim,
    TranslationDirection,
    TranslationResult,
)


class ScriptedWebSocket:
    """Stands in for a Starlette WebSocket; the test pushes client messages."""

    def __init__(self, name: str):
        self.client = (name, 0)
        self.incoming: asyncio.Queue = asyncio.Queue()
        self.sent: list[dict] = []
        self.disconnected = False
        self.receive_after_disconnect = False

    async def accept(self) -> None:
        pass

    async def receive(self) -> dict:
        if self.disconnected:
            # Starlette raises here: 'Cannot call "receive" once a disconnect message has been received.'
            self.receive_after_disconnect = True
            raise RuntimeError('Cannot call "receive" once a disconnect message has been received.')
        message = await self.incoming.get()
        if message["type"] == "websocket.disconnect":
            self.disconnected = True
        return message

    async def send_text(self, text: str) -> None:
        await asyncio.sleep(0)  # A real socket write suspends; let concurrent senders interleave
        self.sent.append(json.loads(text))

    def push(self, data: dict) -> None:
        self.incoming.put_nowait({"type": "websocket.receive", "text": json.dumps(data)})

    def close(self) -> None:
        self.incoming.put_nowait({"type": "websocket.disconnect", "code": 1000})

    def types(self) -> list[str]:
        return [m.get("type") for m in self.sent]


class FakeOrchestrator(BidirectionalOrchestrator):
    """
    BidirectionalOrchestrator without pipelines or services.

    Keeps the real send path (_schedule_send / _send_audio / _send_json and the
    send lock) so partner delivery is exercised for real; stop() can be made
    slow like a real finalize.
    """

    stop_delay_s = 0.0

    def __init__(self, session, websocket, room=None, user_language=None):
        self.session = session
        self.ws = websocket
        self.room = room
        self.user_language = user_language
        self._send_lock = asyncio.Lock()
        self.kr_to_en = None
        self.en_to_kr = None

    async def start(self) -> None:
        pass

    async def stop(self) -> None:
        await asyncio.sleep(self.stop_delay_s)


@pytest.fixture(autouse=True)
def fake_orchestrator(monkeypatch):
    """Keep the handler offline: no STT/TTS/translator services."""
    FakeOrchestrator.stop_delay_s = 0.0
    monkeypatch.setattr(main_module, "BidirectionalOrchestrator", FakeOrchestrator)
    yield
    rooms.clear()


async def wait_until(predicate, timeout: float = 2.0) -> None:
    """Poll until predicate() is true or fail after timeout."""
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met before timeout")
        await asyncio.sleep(0.01)


async def join(ws: ScriptedWebSocket, language: str, room_id: str) -> asyncio.Task:
    """Open a handler for ws and join room_id as language."""
    task = asyncio.create_task(websocket_translate(ws))
    ws.push({"type": "start_session", "user_language": language, "room_id": room_id})
    await wait_until(lambda: "session_started" in ws.types())
    return task


async def paired_room(room_id: str):
    """Korean and English participants in one room; returns (ko, en, [tasks])."""
    ko, en = ScriptedWebSocket("ko"), ScriptedWebSocket("en")
    ko_task = await join(ko, "ko", room_id)
    en_task = await join(en, "en", room_id)
    await wait_until(lambda: "partner_joined" in ko.types() and "partner_joined" in en.types())
    return ko, en, [ko_task, en_task]


async def close_all(sockets, tasks) -> None:
    for ws in sockets:
        ws.close()
    await asyncio.wait_for(asyncio.gather(*tasks), timeout=2)


def sent_of_type(ws: ScriptedWebSocket, msg_type: str) -> list[dict]:
    return [m for m in ws.sent if m.get("type") == msg_type]


def ko_says(segment_id: str = "seg1"):
    """The Korean speaker's transcript and translation for one segment."""
    return (
        TranscriptFinal(direction=TranslationDirection.KO_TO_EN, text="안녕하세요", segment_id=segment_id),
        TranslationResult(
            direction=TranslationDirection.KO_TO_EN, original="안녕하세요", translated="Hello", segment_id=segment_id
        ),
    )


def test_remove_participant_ignores_stale_socket():
    """Removing with an old socket leaves the same language's newer socket in the room."""
    room = ConversationRoom("ABC123")
    old_ws, new_ws, partner_ws = object(), object(), object()
    room.add_participant("ko", partner_ws, None)
    room.add_participant("en", old_ws, None)
    room.add_participant("en", new_ws, None)

    assert not room.remove_participant("en", old_ws)
    assert room.participants["en"] is new_ws
    assert room.remove_participant("en", new_ws)
    assert "en" not in room.participants


@pytest.mark.asyncio
async def test_rejoin_during_slow_stop_keeps_new_socket_in_room():
    """Stop, then a quick mic tap re-joins on a new socket: the old socket's cleanup must not evict it."""
    ko, en_old, en_new = ScriptedWebSocket("ko"), ScriptedWebSocket("en-old"), ScriptedWebSocket("en-new")
    ko_task = await join(ko, "ko", "RACE01")
    en_old_task = await join(en_old, "en", "RACE01")
    await wait_until(lambda: "partner_joined" in ko.types())

    # Stop: the old handler spends a while in orchestrator.stop() (finalize + last phrase)
    FakeOrchestrator.stop_delay_s = 0.3
    en_old.push({"type": "session_end"})
    await asyncio.sleep(0.05)

    # Mic tap: the app closes the old socket and re-joins on a new one
    en_new_task = await join(en_new, "en", "RACE01")
    en_old.close()
    await asyncio.wait_for(en_old_task, timeout=2)

    room = rooms["RACE01"]
    assert room.participants["en"] is en_new
    assert room.participants["ko"] is ko
    assert "partner_left" not in ko.types()
    assert not en_old.receive_after_disconnect

    FakeOrchestrator.stop_delay_s = 0.0
    en_new.close()
    ko.close()
    await asyncio.wait_for(asyncio.gather(en_new_task, ko_task), timeout=2)
    assert "RACE01" not in rooms


@pytest.mark.asyncio
async def test_disconnect_removes_participant_and_notifies_partner():
    """A normal close still removes the user and tells the partner, without a receive() error."""
    ko, en = ScriptedWebSocket("ko"), ScriptedWebSocket("en")
    ko_task = await join(ko, "ko", "LEAVE1")
    en_task = await join(en, "en", "LEAVE1")

    en.close()
    await asyncio.wait_for(en_task, timeout=2)

    assert "en" not in rooms["LEAVE1"].participants
    assert "partner_left" in ko.types()
    assert not en.receive_after_disconnect

    ko.close()
    await asyncio.wait_for(ko_task, timeout=2)
    assert "LEAVE1" not in rooms


@pytest.mark.asyncio
async def test_client_close_is_not_logged_as_error(caplog):
    """A client closing the socket exits the receive loop cleanly (no RuntimeError traceback)."""
    ws = ScriptedWebSocket("solo")
    task = asyncio.create_task(websocket_translate(ws))
    ws.close()

    with caplog.at_level(logging.INFO, logger="src.main"):
        await asyncio.wait_for(task, timeout=2)

    assert not ws.receive_after_disconnect
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert any("WebSocket disconnected" in r.getMessage() for r in caplog.records)


@pytest.mark.asyncio
async def test_audio_chunk_payload_not_logged_at_info(caplog):
    """audio_chunk messages don't put their base64 payload in the INFO log."""
    ws = ScriptedWebSocket("solo")
    task = asyncio.create_task(websocket_translate(ws))

    with caplog.at_level(logging.INFO, logger="src.main"):
        ws.push({"type": "audio_chunk", "direction": "ko_to_en", "data": "QUJDRA=="})
        ws.close()
        await asyncio.wait_for(task, timeout=2)

    assert not any("QUJDRA==" in r.getMessage() for r in caplog.records if r.levelno >= logging.INFO)


# ---------------------------------------------------------------------------
# Partner delivery: the chat shows both sides, so text goes to both phones
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_transcript_and_translation_reach_partner_and_speaker():
    """The Korean speaker's transcript_final and translation arrive on both sockets, direction unchanged."""
    ko, en, tasks = await paired_room("TEXT01")
    final, translation = ko_says()

    speaker = rooms["TEXT01"].orchestrators["ko"]
    speaker._schedule_send(final)
    speaker._schedule_send(translation)
    await wait_until(lambda: sent_of_type(en, "translation") and sent_of_type(ko, "translation"))

    for ws in (ko, en):
        assert sent_of_type(ws, "transcript_final") == [final.model_dump()]
        assert sent_of_type(ws, "translation") == [translation.model_dump()]
        # The English listener's app treats ko_to_en as the partner's direction
        assert sent_of_type(ws, "translation")[0]["direction"] == "ko_to_en"
        assert sent_of_type(ws, "translation")[0]["segment_id"] == "seg1"

    await close_all([ko, en], tasks)


@pytest.mark.asyncio
async def test_english_speaker_text_reaches_korean_partner():
    """Same for the other direction: en_to_ko text lands on the Korean socket."""
    ko, en, tasks = await paired_room("TEXT02")
    translation = TranslationResult(
        direction=TranslationDirection.EN_TO_KO, original="Hello", translated="안녕하세요", segment_id="s9"
    )

    rooms["TEXT02"].orchestrators["en"]._schedule_send(translation)
    await wait_until(lambda: sent_of_type(ko, "translation"))

    assert sent_of_type(ko, "translation") == [translation.model_dump()]
    assert sent_of_type(en, "translation") == [translation.model_dump()]

    await close_all([ko, en], tasks)


@pytest.mark.asyncio
async def test_interim_transcript_is_forwarded_for_live_captions():
    """transcript_interim also reaches the partner (the chat can show live captions)."""
    ko, en, tasks = await paired_room("TEXT03")
    interim = TranscriptInterim(direction=TranslationDirection.KO_TO_EN, text="안녕")

    rooms["TEXT03"].orchestrators["ko"]._schedule_send(interim)
    await wait_until(lambda: sent_of_type(en, "transcript_interim"))

    assert sent_of_type(en, "transcript_interim") == [interim.model_dump()]
    assert sent_of_type(ko, "transcript_interim") == [interim.model_dump()]

    await close_all([ko, en], tasks)


@pytest.mark.asyncio
async def test_solo_speaker_still_gets_own_text():
    """Without a partner the speaker's socket receives its own transcript and translation as before."""
    ko = ScriptedWebSocket("ko")
    task = await join(ko, "ko", "SOLO01")
    final, translation = ko_says()

    speaker = rooms["SOLO01"].orchestrators["ko"]
    speaker._schedule_send(final)
    speaker._schedule_send(translation)
    await wait_until(lambda: sent_of_type(ko, "translation"))

    assert sent_of_type(ko, "transcript_final") == [final.model_dump()]
    assert sent_of_type(ko, "translation") == [translation.model_dump()]

    await close_all([ko], [task])


@pytest.mark.asyncio
async def test_speaker_only_messages_stay_with_speaker():
    """Classifier decisions, gender detection and generic errors are not the partner's business."""
    ko, en, tasks = await paired_room("PRIV01")
    speaker = rooms["PRIV01"].orchestrators["ko"]

    speaker._schedule_send(ClassifierDecision(clause="안녕", decision="safe"))
    speaker._schedule_send(GenderDetected(gender="female", direction=TranslationDirection.KO_TO_EN))
    speaker._schedule_send(ErrorMessage(direction=TranslationDirection.KO_TO_EN, message="STT dropped"))
    # A message the partner does see, to know the earlier ones have been delivered
    speaker._schedule_send(ko_says()[0])
    await wait_until(lambda: sent_of_type(en, "transcript_final"))

    assert sent_of_type(ko, "classifier_decision") and sent_of_type(ko, "gender_detected")
    assert sent_of_type(ko, "error") == [
        {"type": "error", "direction": "ko_to_en", "message": "STT dropped", "recoverable": True,
         "code": None, "segment_id": None, "original": None}
    ]
    assert not sent_of_type(en, "classifier_decision")
    assert not sent_of_type(en, "gender_detected")
    assert not sent_of_type(en, "error")

    await close_all([ko, en], tasks)


@pytest.mark.asyncio
@pytest.mark.parametrize("code", [ERROR_CODE_TRANSLATION_REFUSED, ERROR_CODE_TRANSLATION_FAILED])
async def test_untranslatable_segment_error_reaches_both_phones(code):
    """A segment that couldn't be translated is reported to speaker and listener, with its segment_id."""
    ko, en, tasks = await paired_room("REFUSE1")
    error = ErrorMessage(
        direction=TranslationDirection.KO_TO_EN,
        message="Couldn't translate that - please rephrase.",
        code=code,
        segment_id="seg7",
        original="문제의 문장",
    )

    rooms["REFUSE1"].orchestrators["ko"]._schedule_send(error)
    await wait_until(lambda: sent_of_type(en, "error") and sent_of_type(ko, "error"))

    for ws in (ko, en):
        [received] = sent_of_type(ws, "error")
        assert received["code"] == code
        assert received["segment_id"] == "seg7"
        assert received["original"] == "문제의 문장"
        assert received["direction"] == "ko_to_en"

    await close_all([ko, en], tasks)


@pytest.mark.asyncio
async def test_audio_goes_only_to_listener_through_their_send_lock():
    """Translated audio reaches the listener only, serialized with the listener's own sends."""
    ko, en, tasks = await paired_room("AUDIO1")
    speaker, listener = rooms["AUDIO1"].orchestrators["ko"], rooms["AUDIO1"].orchestrators["en"]
    audio = AudioOut(direction=TranslationDirection.KO_TO_EN, data=b"mp3-bytes")

    # While the listener's lock is held, nothing may be written to the listener's socket
    async with listener._send_lock:
        speaker._schedule_send_audio(audio)
        await asyncio.sleep(0.05)
        assert not sent_of_type(en, "audio")
    await wait_until(lambda: sent_of_type(en, "audio"))

    assert sent_of_type(en, "audio") == [{
        "type": "audio", "direction": "ko_to_en", "format": "mp3",
        "data": base64.b64encode(b"mp3-bytes").decode(),
    }]
    assert not sent_of_type(ko, "audio")

    await close_all([ko, en], tasks)


@pytest.mark.asyncio
async def test_partner_text_waits_for_partner_send_lock():
    """The partner's copy of a translation is written under the partner's lock, not concurrently."""
    ko, en, tasks = await paired_room("LOCK01")
    speaker, listener = rooms["LOCK01"].orchestrators["ko"], rooms["LOCK01"].orchestrators["en"]
    _, translation = ko_says()

    async with listener._send_lock:
        speaker._schedule_send(translation)
        await wait_until(lambda: sent_of_type(ko, "translation"))  # speaker's own copy is not blocked
        await asyncio.sleep(0.05)
        assert not sent_of_type(en, "translation")
    await wait_until(lambda: sent_of_type(en, "translation"))

    await close_all([ko, en], tasks)


@pytest.mark.asyncio
async def test_partner_receives_audio_then_text_in_order():
    """Messages scheduled in order arrive on the partner's socket in that order."""
    ko, en, tasks = await paired_room("ORDER1")
    speaker = rooms["ORDER1"].orchestrators["ko"]
    final, translation = ko_says()

    speaker._schedule_send(final)
    speaker._schedule_send_audio(AudioOut(direction=TranslationDirection.KO_TO_EN, data=b"a"))
    speaker._schedule_send(translation)
    speaker._schedule_send_audio(AudioOut(direction=TranslationDirection.KO_TO_EN, data=b"b"))
    await wait_until(lambda: len(sent_of_type(en, "audio")) == 2)

    conversation = [m["type"] for m in en.sent if m["type"] in ("transcript_final", "audio", "translation")]
    assert conversation == ["transcript_final", "audio", "translation", "audio"]

    await close_all([ko, en], tasks)


@pytest.mark.asyncio
async def test_solo_speaker_hears_own_audio():
    """Without a partner the speaker's socket still gets the audio (solo testing)."""
    ko = ScriptedWebSocket("ko")
    task = await join(ko, "ko", "SOLO02")

    rooms["SOLO02"].orchestrators["ko"]._schedule_send_audio(
        AudioOut(direction=TranslationDirection.KO_TO_EN, data=b"x")
    )
    await wait_until(lambda: sent_of_type(ko, "audio"))
    assert sent_of_type(ko, "audio")[0]["direction"] == "ko_to_en"

    await close_all([ko], [task])


@pytest.mark.asyncio
async def test_text_stops_going_to_partner_after_they_leave():
    """Once the partner has left, the speaker's text goes to the speaker only (no send errors)."""
    ko, en, tasks = await paired_room("LEFT01")
    en.close()
    await asyncio.wait_for(tasks[1], timeout=2)
    await wait_until(lambda: "partner_left" in ko.types())
    en_messages_before = len(en.sent)

    speaker = rooms["LEFT01"].orchestrators["ko"]
    speaker._schedule_send(ko_says()[1])
    await wait_until(lambda: sent_of_type(ko, "translation"))
    await asyncio.sleep(0.02)

    assert len(en.sent) == en_messages_before

    await close_all([ko], [tasks[0]])


@pytest.mark.asyncio
async def test_partner_joined_and_left_go_through_partner_send_lock():
    """Room notifications to the partner wait for that partner's send lock too."""
    ko = ScriptedWebSocket("ko")
    ko_task = await join(ko, "ko", "NOTIF1")
    ko_orch = rooms["NOTIF1"].orchestrators["ko"]

    en = ScriptedWebSocket("en")
    async with ko_orch._send_lock:
        en_task = asyncio.create_task(websocket_translate(en))
        en.push({"type": "start_session", "user_language": "en", "room_id": "NOTIF1"})
        await wait_until(lambda: "session_started" in en.types())
        await asyncio.sleep(0.05)
        assert "partner_joined" not in ko.types()
    await wait_until(lambda: "partner_joined" in ko.types())

    async with ko_orch._send_lock:
        en.close()
        await asyncio.sleep(0.05)
        assert "partner_left" not in ko.types()
    await wait_until(lambda: "partner_left" in ko.types())
    await asyncio.wait_for(en_task, timeout=2)

    await close_all([ko], [ko_task])


def test_partner_should_see_rules():
    """Conversation messages are shared; diagnostics and generic errors are not."""
    assert main_module.partner_should_see({"type": "transcript_interim"})
    assert main_module.partner_should_see({"type": "transcript_final"})
    assert main_module.partner_should_see({"type": "translation"})
    assert main_module.partner_should_see({"type": "error", "code": ERROR_CODE_TRANSLATION_REFUSED})
    assert main_module.partner_should_see({"type": "error", "code": ERROR_CODE_TRANSLATION_FAILED})
    assert not main_module.partner_should_see({"type": "error", "code": None})
    assert not main_module.partner_should_see({"type": "error"})
    assert not main_module.partner_should_see({"type": "classifier_decision"})
    assert not main_module.partner_should_see({"type": "gender_detected"})
    assert not main_module.partner_should_see({"type": "audio"})


# ---------------------------------------------------------------------------
# Real orchestrator wiring (pipelines built for real, services faked)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_refused_segment_reaches_both_phones_through_real_orchestrator(monkeypatch):
    """A refusal raised inside the real KO->EN pipeline ends up as an error on both sockets."""
    from tests.test_pipeline_audio import FakeSTT, FakeTTS, MP3_CHUNKS, RefusingTranslator

    class OrchestratorFakeTTS(FakeTTS):
        async def start(self) -> None:
            pass

        async def stop(self) -> None:
            pass

        def set_gender(self, gender) -> None:
            pass

    monkeypatch.setattr(main_module, "BidirectionalOrchestrator", BidirectionalOrchestrator)
    monkeypatch.setattr(main_module, "STTService", lambda language: FakeSTT())
    monkeypatch.setattr(main_module, "TTSService", lambda: OrchestratorFakeTTS(MP3_CHUNKS))
    monkeypatch.setattr(main_module, "TranslatorService", lambda: RefusingTranslator())

    ko, en, tasks = await paired_room("REAL01")
    speaker = rooms["REAL01"].orchestrators["ko"]
    assert isinstance(speaker, BidirectionalOrchestrator) and speaker.kr_to_en is not None

    await speaker.kr_to_en._translate_and_speak("문제의 문장", "seg-real")
    await wait_until(lambda: sent_of_type(en, "error") and sent_of_type(ko, "error"))

    for ws in (ko, en):
        [error] = sent_of_type(ws, "error")
        assert error["code"] == ERROR_CODE_TRANSLATION_REFUSED
        assert error["segment_id"] == "seg-real"
        assert error["original"] == "문제의 문장"
        assert error["direction"] == "ko_to_en"
        assert not sent_of_type(ws, "translation")
    # The first phrase had been spoken before the refusal arrived: audio for the listener only
    assert sent_of_type(en, "audio") and not sent_of_type(ko, "audio")

    await close_all([ko, en], tasks)
