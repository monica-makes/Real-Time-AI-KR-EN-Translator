"""Offline tests for /ws/pair: Wi-Fi matching, the one-shot timeout, and manual create/join (scripted sockets)."""

import asyncio
import json
import time

import pytest
from fastapi import WebSocketDisconnect

from src import main as main_module
from src.main import pairing_clients, pairing_rooms, websocket_pair


class Client:
    """Stands in for a Starlette WebSocket on /ws/pair; the test pushes client messages."""

    def __init__(self, host: str = "192.168.1.10"):
        self.client = type("Addr", (), {"host": host})()
        self.incoming: asyncio.Queue = asyncio.Queue()
        self.sent: list[dict] = []
        self.closed = False

    async def accept(self) -> None:
        pass

    async def receive_text(self) -> str:
        if self.closed:
            raise RuntimeError('Cannot call "receive" once a disconnect message has been received.')
        message = await self.incoming.get()
        if message is None:
            self.closed = True
            raise WebSocketDisconnect(1000)
        return message

    async def send_text(self, text: str) -> None:
        self.sent.append(json.loads(text))

    def push(self, data: dict) -> None:
        self.incoming.put_nowait(json.dumps(data))

    def close(self) -> None:
        self.incoming.put_nowait(None)

    def types(self) -> list[str]:
        return [m.get("type") for m in self.sent]

    def last(self, msg_type: str) -> dict:
        return [m for m in self.sent if m.get("type") == msg_type][-1]


@pytest.fixture(autouse=True)
def fast_timeout(monkeypatch):
    """Keep the Wi-Fi match timeout short and the registries clean."""
    monkeypatch.setattr(main_module, "PAIRING_MATCH_TIMEOUT_S", 0.15)
    pairing_clients.clear()
    pairing_rooms.clear()
    yield
    pairing_clients.clear()
    pairing_rooms.clear()


async def wait_until(predicate, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met before timeout")
        await asyncio.sleep(0.01)


def start(ws: Client, direction: str = "ko_to_en", mode: str = "wifi") -> asyncio.Task:
    return asyncio.create_task(websocket_pair(ws, direction=direction, mode=mode))


async def finish(clients, tasks) -> None:
    for ws in clients:
        if not ws.closed:
            ws.close()
    await asyncio.wait_for(asyncio.gather(*tasks, return_exceptions=True), timeout=2)


@pytest.mark.asyncio
async def test_wifi_partners_with_headphones_match():
    """Opposite directions on the same network, both with headphones, get the same room id."""
    ko, en = Client("192.168.1.10"), Client("192.168.1.11")
    ko_task = start(ko, "ko_to_en")
    await wait_until(lambda: "searching" in ko.types())
    en_task = start(en, "en_to_ko")
    await wait_until(lambda: "partner_connected" in ko.types() and "partner_connected" in en.types())

    ko.push({"type": "headphone_status", "connected": True})
    await wait_until(lambda: "partner_ready" in en.types())
    en.push({"type": "headphone_status", "connected": True})
    await wait_until(lambda: "matched" in ko.types() and "matched" in en.types())

    assert ko.last("matched")["room_id"] == en.last("matched")["room_id"]
    await asyncio.wait_for(asyncio.gather(ko_task, en_task), timeout=2)
    assert not pairing_clients


@pytest.mark.asyncio
async def test_onboarding_direction_spelling_is_accepted():
    """?direction=en_to_kr (onboarding spelling) pairs with a ko_to_en partner."""
    ko, en = Client("10.0.0.2"), Client("10.0.0.3")
    ko_task = start(ko, "ko_to_en")
    await wait_until(lambda: "searching" in ko.types())
    en_task = start(en, "en_to_kr")
    await wait_until(lambda: "partner_connected" in en.types())

    assert "partner_connected" in ko.types()
    await finish([ko, en], [ko_task, en_task])


@pytest.mark.asyncio
async def test_same_direction_clients_do_not_pair():
    """Two Korean speakers on one network are not partners."""
    a, b = Client("10.0.0.2"), Client("10.0.0.3")
    a_task = start(a, "ko_to_en")
    await wait_until(lambda: "searching" in a.types())
    b_task = start(b, "ko_to_en")
    await wait_until(lambda: "searching" in b.types())
    b.push({"type": "headphone_status", "connected": True})
    await asyncio.sleep(0.05)

    assert "partner_connected" not in a.types() and "partner_connected" not in b.types()
    await finish([a, b], [a_task, b_task])


@pytest.mark.asyncio
async def test_timeout_sends_no_match_exactly_once():
    """After the match timeout the client gets one no_match with a code, not one per loop iteration."""
    ws = Client()
    task = start(ws)
    await wait_until(lambda: "no_match" in ws.types())
    # Keep the loop spinning past the deadline: messages and idle time alike
    ws.push({"type": "headphone_status", "connected": True})
    ws.push({"type": "headphone_status", "connected": False})
    await asyncio.sleep(0.4)

    assert ws.types().count("no_match") == 1
    code = ws.last("no_match")["room_code"]
    assert len(code) == 6 and code.isdigit()
    assert pairing_rooms[code]["creator"]["websocket"] is ws

    await finish([ws], [task])
    assert code not in pairing_rooms  # the code dies with its creator


@pytest.mark.asyncio
async def test_join_after_wifi_timeout_matches_creator():
    """The code offered on timeout can be joined; both sides get the same room id."""
    creator, joiner = Client("10.0.0.2"), Client("172.16.0.9")
    creator_task = start(creator)
    await wait_until(lambda: "no_match" in creator.types())
    code = creator.last("no_match")["room_code"]

    joiner_task = start(joiner, "en_to_ko", mode="manual")
    joiner.push({"type": "join_room", "room_code": code})
    await wait_until(lambda: "matched" in creator.types() and "matched" in joiner.types())

    assert creator.last("matched")["room_id"] == joiner.last("matched")["room_id"]
    assert "searching" not in joiner.types()  # manual mode never looks for Wi-Fi partners
    assert code not in pairing_rooms
    await asyncio.wait_for(asyncio.gather(creator_task, joiner_task), timeout=2)


@pytest.mark.asyncio
async def test_manual_create_and_join():
    """A client-generated code is registered with create_room and joined with join_room."""
    creator, joiner = Client("10.0.0.2"), Client("10.0.0.3")
    creator_task = start(creator, "en_to_ko", mode="manual")
    creator.push({"type": "create_room", "room_code": "208098"})
    await wait_until(lambda: "room_created" in creator.types())
    assert creator.last("room_created")["room_code"] == "208098"
    assert "208098" in pairing_rooms

    joiner_task = start(joiner, "ko_to_en", mode="manual")
    joiner.push({"type": "join_room", "room_code": "208098"})
    await wait_until(lambda: "matched" in creator.types() and "matched" in joiner.types())

    assert creator.last("matched")["room_id"] == joiner.last("matched")["room_id"]
    assert "208098" not in pairing_rooms
    await asyncio.wait_for(asyncio.gather(creator_task, joiner_task), timeout=2)


@pytest.mark.asyncio
async def test_manual_mode_never_times_out():
    """A manual-mode creator keeps waiting well past the Wi-Fi timeout without a no_match."""
    creator = Client()
    task = start(creator, mode="manual")
    creator.push({"type": "create_room", "room_code": "111111"})
    await wait_until(lambda: "room_created" in creator.types())
    await asyncio.sleep(0.4)

    assert "no_match" not in creator.types()
    assert "111111" in pairing_rooms
    await finish([creator], [task])


@pytest.mark.asyncio
async def test_unknown_code_is_rejected_and_retry_works():
    """A wrong code gets join_failed; the socket stays open so the right code still joins."""
    creator, joiner = Client("10.0.0.2"), Client("10.0.0.3")
    creator_task = start(creator, mode="manual")
    creator.push({"type": "create_room", "room_code": "654321"})
    await wait_until(lambda: "room_created" in creator.types())

    joiner_task = start(joiner, mode="manual")
    joiner.push({"type": "join_room", "room_code": "999999"})
    await wait_until(lambda: "join_failed" in joiner.types())
    assert joiner.last("join_failed") == {"type": "join_failed", "room_code": "999999", "reason": "unknown_code"}
    assert "matched" not in creator.types()

    joiner.push({"type": "join_room", "room_code": "654321"})
    await wait_until(lambda: "matched" in joiner.types() and "matched" in creator.types())
    await asyncio.wait_for(asyncio.gather(creator_task, joiner_task), timeout=2)


@pytest.mark.asyncio
async def test_code_dies_with_its_creator():
    """Once the creator disconnects, joining its code fails instead of matching a dead socket."""
    creator, joiner = Client("10.0.0.2"), Client("10.0.0.3")
    creator_task = start(creator, mode="manual")
    creator.push({"type": "create_room", "room_code": "424242"})
    await wait_until(lambda: "room_created" in creator.types())
    creator.close()
    await asyncio.wait_for(creator_task, timeout=2)
    assert "424242" not in pairing_rooms

    joiner_task = start(joiner, mode="manual")
    joiner.push({"type": "join_room", "room_code": "424242"})
    await wait_until(lambda: "join_failed" in joiner.types())
    await finish([joiner], [joiner_task])


@pytest.mark.asyncio
async def test_code_in_use_by_another_creator_is_refused():
    """Two live creators can't offer the same code; re-registering your own is fine."""
    first, second = Client("10.0.0.2"), Client("10.0.0.3")
    first_task = start(first, mode="manual")
    first.push({"type": "create_room", "room_code": "777777"})
    await wait_until(lambda: "room_created" in first.types())

    second_task = start(second, mode="manual")
    second.push({"type": "create_room", "room_code": "777777"})
    await wait_until(lambda: "create_failed" in second.types())
    assert second.last("create_failed")["reason"] == "code_in_use"

    first.push({"type": "create_room", "room_code": "777777"})
    await wait_until(lambda: first.types().count("room_created") == 2)
    await finish([first, second], [first_task, second_task])


@pytest.mark.asyncio
async def test_disconnect_is_not_logged_as_error(caplog):
    """A client closing the pairing socket exits cleanly (no 'Error in pairing loop')."""
    import logging

    ws = Client()
    task = start(ws)
    await wait_until(lambda: "searching" in ws.types())
    with caplog.at_level(logging.INFO, logger="src.main"):
        ws.close()
        await asyncio.wait_for(task, timeout=2)

    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert any("Pairing client disconnected" in r.getMessage() for r in caplog.records)
    assert not pairing_clients


@pytest.mark.asyncio
async def test_new_code_replaces_the_previous_one():
    """A creator offers one code at a time: the old code stops being joinable and dies with the creator."""
    creator, joiner = Client("10.0.0.2"), Client("10.0.0.3")
    creator_task = start(creator, mode="manual")
    creator.push({"type": "create_room", "room_code": "111111"})
    creator.push({"type": "create_room", "room_code": "222222"})
    await wait_until(lambda: creator.types().count("room_created") == 2)
    assert sorted(pairing_rooms) == ["222222"]

    joiner_task = start(joiner, mode="manual")
    joiner.push({"type": "join_room", "room_code": "111111"})
    await wait_until(lambda: "join_failed" in joiner.types())

    creator.close()
    await asyncio.wait_for(creator_task, timeout=2)
    assert not pairing_rooms
    await finish([joiner], [joiner_task])


@pytest.mark.asyncio
async def test_wifi_timeout_keeps_a_code_the_client_registered(monkeypatch):
    """A Wi-Fi client that already offered a code keeps it: no_match repeats it instead of minting another."""
    monkeypatch.setattr(main_module, "PAIRING_MATCH_TIMEOUT_S", 1.0)  # create_room must land before the deadline
    ws = Client()
    task = start(ws)
    await wait_until(lambda: "searching" in ws.types())
    ws.push({"type": "create_room", "room_code": "333333"})
    await wait_until(lambda: "room_created" in ws.types())
    await wait_until(lambda: "no_match" in ws.types())

    assert ws.last("no_match")["room_code"] == "333333"
    assert sorted(pairing_rooms) == ["333333"]
    await finish([ws], [task])


@pytest.mark.asyncio
async def test_simultaneous_headphone_status_matches_once():
    """Both clients reporting headphones in the same instant get one matched message each, same room."""
    ko, en = Client("192.168.1.10"), Client("192.168.1.11")
    ko_task = start(ko, "ko_to_en")
    await wait_until(lambda: "searching" in ko.types())
    en_task = start(en, "en_to_ko")
    await wait_until(lambda: "partner_connected" in ko.types() and "partner_connected" in en.types())

    ko.push({"type": "headphone_status", "connected": True})
    en.push({"type": "headphone_status", "connected": True})
    await asyncio.wait_for(asyncio.gather(ko_task, en_task), timeout=2)

    assert ko.types().count("matched") == 1 and en.types().count("matched") == 1
    assert ko.last("matched")["room_id"] == en.last("matched")["room_id"]


@pytest.mark.asyncio
async def test_partner_who_left_is_replaced_by_a_new_one():
    """After the first partner disconnects, the next opposite-direction client can still match."""
    ko, en1, en2 = Client("10.0.0.2"), Client("10.0.0.3"), Client("10.0.0.4")
    ko_task = start(ko, "ko_to_en")
    await wait_until(lambda: "searching" in ko.types())
    en1_task = start(en1, "en_to_ko")
    await wait_until(lambda: "partner_connected" in ko.types())
    en1.close()
    await asyncio.wait_for(en1_task, timeout=2)
    await wait_until(lambda: "partner_disconnected" in ko.types())

    en2_task = start(en2, "en_to_ko")
    await wait_until(lambda: "partner_connected" in en2.types())
    ko.push({"type": "headphone_status", "connected": True})
    en2.push({"type": "headphone_status", "connected": True})
    await wait_until(lambda: "matched" in ko.types() and "matched" in en2.types())

    assert ko.last("matched")["room_id"] == en2.last("matched")["room_id"]
    await asyncio.wait_for(asyncio.gather(ko_task, en2_task), timeout=2)
