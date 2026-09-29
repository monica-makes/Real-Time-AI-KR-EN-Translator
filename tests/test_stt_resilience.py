"""Offline tests for STTService reconnect, KeepAlive and finalize (fake Deepgram, no network)."""

import asyncio
import queue
import threading
import time
from types import SimpleNamespace

import pytest

from src.services import stt as stt_module
from src.services.stt import STTService

_CLOSE = object()


class FakeConnection:
    """Stands in for deepgram V1SocketClient: records sends, iterates server messages."""

    def __init__(self):
        self.sent: list[bytes] = []
        self.keepalives = 0
        self.finalizes = 0
        self.fail_sends = False
        self._inbox: queue.Queue = queue.Queue()

    def on(self, event, handler) -> None:
        pass

    def send_media(self, data: bytes) -> None:
        if self.fail_sends:
            raise ConnectionError("socket is closed")
        self.sent.append(data)

    def send_keep_alive(self) -> None:
        self.keepalives += 1

    def send_finalize(self) -> None:
        self.finalizes += 1

    def __iter__(self):
        while True:
            item = self._inbox.get()
            if item is _CLOSE:
                return
            if isinstance(item, BaseException):
                raise item
            yield item

    def server_close(self, error: BaseException = None) -> None:
        """Simulate Deepgram ending the stream (cleanly, or with an error like 1011)."""
        self._inbox.put(error if error is not None else _CLOSE)


class FakeContextManager:
    """Stands in for the context manager returned by client.listen.v1.connect()."""

    def __init__(self, connection: FakeConnection, close_ends_stream: bool):
        self.connection = connection
        self.close_ends_stream = close_ends_stream
        self.exited = threading.Event()

    def __enter__(self) -> FakeConnection:
        return self.connection

    def __exit__(self, *exc) -> bool:
        self.exited.set()
        if self.close_ends_stream:
            self.connection.server_close()
        return False


class FakeDeepgramClient:
    """Stands in for DeepgramClient; every connect() opens a new FakeConnection."""

    def __init__(self, api_key: str = "", **kwargs):
        self.connections: list[FakeConnection] = []
        self.context_managers: list[FakeContextManager] = []
        self.close_ends_stream = True
        self.fail_connect = False
        self.connect_attempts = 0
        self.listen = SimpleNamespace(v1=SimpleNamespace(connect=self._connect))

    def _connect(self, **options) -> FakeContextManager:
        self.connect_attempts += 1
        if self.fail_connect:
            raise ConnectionError("HTTP 429: too many concurrent requests")
        connection = FakeConnection()
        context_manager = FakeContextManager(connection, self.close_ends_stream)
        self.connections.append(connection)
        self.context_managers.append(context_manager)
        return context_manager


@pytest.fixture(autouse=True)
def fake_deepgram(monkeypatch):
    """Replace the Deepgram client so no test touches the network."""
    monkeypatch.setattr(stt_module, "DeepgramClient", FakeDeepgramClient)


async def wait_until(predicate, timeout: float = 2.0) -> None:
    """Poll until predicate() is true or fail after timeout."""
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met before timeout")
        await asyncio.sleep(0.01)


def join_listener(name: str, timeout: float = 2.0) -> None:
    """Join the STT listener thread with the given name."""
    for thread in threading.enumerate():
        if thread.name == name:
            thread.join(timeout)
            assert not thread.is_alive(), f"{name} did not exit"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "close_error",
    [ConnectionError("received 1011 (internal error) NET-0001"), None],
    ids=["error_close", "clean_close"],
)
async def test_reconnects_on_next_send_after_listener_exits(close_error):
    """Deepgram closing the stream marks STT disconnected; the next chunk reconnects."""
    stt = STTService(language="en")
    await stt.connect()
    try:
        await stt.send_audio(b"chunk-1")
        client = stt._client
        assert stt.is_connected
        assert client.connections[0].sent == [b"chunk-1"]

        # Deepgram times out the idle stream
        client.connections[0].server_close(close_error)
        await wait_until(lambda: not stt.is_connected)
        await wait_until(client.context_managers[0].exited.is_set)

        await stt.send_audio(b"chunk-2")
        assert stt.is_connected
        assert len(client.connections) == 2
        assert client.connections[1].sent == [b"chunk-2"]

        await stt.send_audio(b"chunk-3")
        assert client.connections[1].sent == [b"chunk-2", b"chunk-3"]
    finally:
        await stt.disconnect()


@pytest.mark.asyncio
async def test_send_failure_reconnects_on_next_chunk():
    """A send_media error drops the connection so the following chunk reconnects."""
    stt = STTService(language="ko")
    await stt.connect()
    try:
        await stt.send_audio(b"chunk-1")
        client = stt._client
        client.connections[0].fail_sends = True

        await stt.send_audio(b"chunk-2")
        assert not stt.is_connected

        await stt.send_audio(b"chunk-3")
        assert stt.is_connected
        assert len(client.connections) == 2
        assert client.connections[1].sent == [b"chunk-3"]
        await wait_until(client.context_managers[0].exited.is_set)
    finally:
        await stt.disconnect()


@pytest.mark.asyncio
async def test_stale_listener_does_not_clobber_newer_connection():
    """A listener for a replaced connection exiting late leaves the new connection alone."""
    stt = STTService(language="en")
    await stt.connect()
    try:
        client = stt._client
        # Keep listener 1 blocked after its socket is closed so it exits late
        client.close_ends_stream = False
        await stt.send_audio(b"chunk-1")
        old_connection = client.connections[0]

        # Send fails -> connection 1 marked dead, next chunk opens connection 2
        old_connection.fail_sends = True
        await stt.send_audio(b"chunk-2")
        client.close_ends_stream = True
        await stt.send_audio(b"chunk-3")
        new_connection = client.connections[1]
        assert new_connection.sent == [b"chunk-3"]

        # Only now does the stale listener see its stream end
        old_connection.server_close(ConnectionError("received 1011 (internal error)"))
        await asyncio.to_thread(join_listener, "stt-listener-en-1")

        assert stt.is_connected
        assert stt._connection is new_connection
        assert not client.context_managers[1].exited.is_set()

        await stt.send_audio(b"chunk-4")
        assert new_connection.sent == [b"chunk-3", b"chunk-4"]
        assert len(client.connections) == 2
    finally:
        await stt.disconnect()


@pytest.mark.asyncio
async def test_keepalive_sent_while_idle():
    """KeepAlive is sent repeatedly once no audio has been sent for the idle threshold."""
    stt = STTService(language="en")
    stt.keepalive_idle_s = 0.05
    stt.keepalive_interval_s = 0.05
    stt.keepalive_check_interval_s = 0.01
    await stt.connect()
    try:
        await stt.send_audio(b"chunk-1")
        connection = stt._client.connections[0]
        await wait_until(lambda: connection.keepalives >= 2)
    finally:
        await stt.disconnect()
    assert stt._keepalive_task is None


@pytest.mark.asyncio
async def test_no_keepalive_while_audio_flowing():
    """No KeepAlive is sent while audio keeps arriving."""
    stt = STTService(language="en")
    stt.keepalive_idle_s = 0.3
    stt.keepalive_interval_s = 0.3
    stt.keepalive_check_interval_s = 0.01
    await stt.connect()
    try:
        for _ in range(20):
            await stt.send_audio(b"chunk")
            await asyncio.sleep(0.02)
        assert stt._client.connections[0].keepalives == 0
    finally:
        await stt.disconnect()


@pytest.mark.asyncio
async def test_keepalive_stops_after_max_silence():
    """After the max silence window KeepAlive stops so Deepgram can close the stream."""
    stt = STTService(language="en")
    stt.keepalive_idle_s = 0.02
    stt.keepalive_interval_s = 0.02
    stt.keepalive_check_interval_s = 0.01
    stt.keepalive_max_silence_s = 0.15
    await stt.connect()
    try:
        await stt.send_audio(b"chunk-1")
        connection = stt._client.connections[0]
        await asyncio.sleep(0.4)
        sent = connection.keepalives
        assert sent >= 1
        await asyncio.sleep(0.2)
        assert connection.keepalives == sent
    finally:
        await stt.disconnect()


@pytest.mark.asyncio
async def test_finalize_calls_send_finalize():
    """finalize() uses send_finalize on deepgram-sdk 7.x connections."""
    stt = STTService(language="ko")
    stt.finalize_wait_s = 0.01
    await stt.connect()
    try:
        await stt.send_audio(b"chunk-1")
        await stt.finalize()
        assert stt._client.connections[0].finalizes == 1
    finally:
        await stt.disconnect()


@pytest.mark.asyncio
async def test_finalize_falls_back_to_finish():
    """finalize() falls back to finish() on connections without send_finalize."""
    stt = STTService(language="en")
    stt.finalize_wait_s = 0.01
    calls = []
    stt._connection = SimpleNamespace(finish=lambda: calls.append("finish"))
    stt._is_connected = True
    await stt.finalize()
    assert calls == ["finish"]


@pytest.mark.asyncio
async def test_finalize_without_connection_is_noop():
    """finalize() returns immediately when there is no live connection."""
    stt = STTService(language="en")
    await stt.finalize()
    assert not stt.is_connected


def deepgram_results(transcript, is_final, speech_final=None, from_finalize=None, start=1.2):
    """Build a Deepgram Results message shaped like deepgram-sdk's ListenV1Results."""
    alternative = SimpleNamespace(
        transcript=transcript, confidence=0.9, words=[SimpleNamespace(start=start)]
    )
    return SimpleNamespace(
        type="Results",
        channel=SimpleNamespace(alternatives=[alternative]),
        is_final=is_final,
        speech_final=speech_final,
        from_finalize=from_finalize,
    )


def test_results_carry_end_of_speech_and_utterance_end_timing():
    """speech_final/from_finalize mark the end of speech; UtteranceEnd carries last_word_end."""
    results = []
    stt = STTService(language="ko", on_result=results.append)

    stt._on_message(deepgram_results("안녕하세요.", is_final=True, speech_final=True))
    stt._on_message(deepgram_results("감사합니다.", is_final=True, from_finalize=True))
    stt._on_message(deepgram_results("오늘 날씨가", is_final=True, speech_final=False))
    stt._on_message(deepgram_results("오늘", is_final=False))
    stt._on_message(SimpleNamespace(type="UtteranceEnd", channel=[0, 1], last_word_end=2.395))

    assert [(r.text, r.is_final, r.speech_final) for r in results[:4]] == [
        ("안녕하세요.", True, True),
        ("감사합니다.", True, True),
        ("오늘 날씨가", True, False),
        ("오늘", False, False),
    ]
    assert results[0].timestamp_ms == 1200
    assert results[4].is_utterance_end
    assert results[4].last_word_end_ms == 2395


@pytest.mark.asyncio
async def test_idle_finalize_sent_once_per_silence():
    """When audio stops (mic paused) Finalize is sent once, and again after the next silence."""
    stt = STTService(language="ko")
    stt.idle_finalize_s = 0.05
    stt.keepalive_idle_s = 60.0
    stt.keepalive_check_interval_s = 0.01
    await stt.connect()
    try:
        await stt.send_audio(b"chunk-1")
        connection = stt._client.connections[0]
        await wait_until(lambda: connection.finalizes == 1)
        await asyncio.sleep(0.15)
        assert connection.finalizes == 1

        await stt.send_audio(b"chunk-2")
        await wait_until(lambda: connection.finalizes == 2)
        assert stt.is_connected
    finally:
        await stt.disconnect()


@pytest.mark.asyncio
async def test_repeated_connect_failures_back_off():
    """After a failed retry, chunks are dropped without a handshake until the backoff passes."""
    stt = STTService(language="en")
    stt.reconnect_backoff_initial_s = 0.2
    await stt.connect()
    try:
        client = stt._client
        client.fail_connect = True

        await stt.send_audio(b"chunk-1")  # Fails
        await stt.send_audio(b"chunk-2")  # First retry is immediate, fails again
        assert client.connect_attempts == 2
        await stt.send_audio(b"chunk-3")  # Backing off: no handshake
        assert client.connect_attempts == 2
        assert not stt.is_connected

        client.fail_connect = False
        await asyncio.sleep(0.25)
        await stt.send_audio(b"chunk-4")
        assert client.connect_attempts == 3
        assert stt.is_connected
        assert client.connections[0].sent == [b"chunk-4"]
    finally:
        await stt.disconnect()


@pytest.mark.asyncio
async def test_stream_closing_right_after_opening_backs_off():
    """A stream Deepgram keeps closing right after it opens doesn't reconnect on every chunk."""
    stt = STTService(language="en")
    stt.reconnect_backoff_initial_s = 0.2
    await stt.connect()
    try:
        client = stt._client
        await stt.send_audio(b"chunk-1")
        client.connections[0].server_close(ConnectionError("received 1011"))
        await wait_until(lambda: not stt.is_connected)

        await stt.send_audio(b"chunk-2")  # First reconnect is immediate
        assert len(client.connections) == 2
        client.connections[1].server_close(ConnectionError("received 1011"))
        await wait_until(lambda: not stt.is_connected)

        await stt.send_audio(b"chunk-3")  # Second early drop: backing off
        assert len(client.connections) == 2

        await asyncio.sleep(0.25)
        await stt.send_audio(b"chunk-4")
        assert len(client.connections) == 3
        assert client.connections[2].sent == [b"chunk-4"]
    finally:
        await stt.disconnect()


@pytest.mark.asyncio
async def test_long_lived_stream_drop_reconnects_immediately():
    """Drops of streams that stayed up (e.g. idle timeouts) never wait for a backoff."""
    stt = STTService(language="ko")
    stt.reconnect_backoff_initial_s = 5.0
    stt.reconnect_stable_s = 0.05
    await stt.connect()
    try:
        client = stt._client
        await stt.send_audio(b"chunk-1")
        for index in range(3):
            await asyncio.sleep(0.1)
            client.connections[index].server_close()
            await wait_until(lambda: not stt.is_connected)
            await stt.send_audio(b"chunk")
            assert len(client.connections) == index + 2
    finally:
        await stt.disconnect()
