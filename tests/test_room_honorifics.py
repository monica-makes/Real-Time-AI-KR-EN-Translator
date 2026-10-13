"""Honorifics are a room-wide setting shared by both phones."""

import pytest

from src.main import ConversationRoom, config_status


class FakeOrchestrator:
    """Records config updates and the frames sent to its phone."""

    def __init__(self):
        self.honorific_updates: list = []
        self.sent: list = []

    async def update_config(self, honorific_mode=None, gender_override=None):
        self.honorific_updates.append(honorific_mode)

    async def _send_json(self, data: dict):
        self.sent.append(data)


def test_first_joiner_sets_the_room_mode_and_later_joiners_inherit_it():
    room = ConversationRoom("ABC123")
    assert room.honorific_mode is None

    # The English speaker joins with Honorifics ON; the room keeps that
    assert room.resolve_honorific_mode(True) is True
    assert room.honorific_mode is True

    # The Korean speaker's phone asks for OFF on join, but inherits the room's ON
    assert room.resolve_honorific_mode(False) is True
    assert room.honorific_mode is True


def test_first_joiner_can_start_the_room_casual():
    room = ConversationRoom("ABC123")
    assert room.resolve_honorific_mode(False) is False
    assert room.resolve_honorific_mode(True) is False


@pytest.mark.asyncio
async def test_set_honorific_mode_reaches_both_orchestrators_and_both_phones():
    room = ConversationRoom("ABC123")
    en, ko = FakeOrchestrator(), FakeOrchestrator()
    room.add_participant("en", websocket=object(), orchestrator=en)
    room.add_participant("ko", websocket=object(), orchestrator=ko)
    room.resolve_honorific_mode(True)

    # The Korean speaker taps the card off: the English speaker's EN->KO pipeline must follow
    await room.set_honorific_mode(False)

    assert room.honorific_mode is False
    assert en.honorific_updates == [False]
    assert ko.honorific_updates == [False]
    assert en.sent == [config_status(honorific_mode=False)]
    assert ko.sent == [config_status(honorific_mode=False)]


@pytest.mark.asyncio
async def test_set_honorific_mode_with_one_participant():
    room = ConversationRoom("ABC123")
    en = FakeOrchestrator()
    room.add_participant("en", websocket=object(), orchestrator=en)

    await room.set_honorific_mode(True)

    assert en.honorific_updates == [True]
    assert en.sent == [config_status(honorific_mode=True)]
    # A partner joining afterwards inherits the change
    assert room.resolve_honorific_mode(False) is True


def test_config_status_shape():
    assert config_status(True) == {
        "type": "status",
        "status": "config_updated",
        "honorific_mode": True,
        "gender": None,
    }
