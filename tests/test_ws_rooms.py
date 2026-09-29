"""Offline tests for /ws/translate room cleanup and disconnect handling (scripted sockets, fake orchestrator)."""

import asyncio
import json
import logging
import time

import pytest

from src import main as main_module
from src.main import ConversationRoom, rooms, websocket_translate


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
        self.sent.append(json.loads(text))

    def push(self, data: dict) -> None:
        self.incoming.put_nowait({"type": "websocket.receive", "text": json.dumps(data)})

    def close(self) -> None:
        self.incoming.put_nowait({"type": "websocket.disconnect", "code": 1000})

    def types(self) -> list[str]:
        return [m.get("type") for m in self.sent]


class FakeOrchestrator:
    """Stands in for BidirectionalOrchestrator; stop() can be made slow like a real finalize."""

    stop_delay_s = 0.0

    def __init__(self, session, websocket, room=None, user_language=None):
        self.session = session

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
