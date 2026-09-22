import asyncio
import tempfile
from pathlib import Path

import pytest

from wade_backend import protocol
from wade_backend.server import BackendServer

TKG_EVENT = {
    "type": "tkg_event",
    "event_type": "focus_change",
    "timestamp": 1234567890.123,
    "app_bundle_id": "com.apple.dt.Xcode",
    "window_title": "Wade — main.swift",
    "metadata": {},
}


def test_decode_rejects_unknown_event_type():
    with pytest.raises(protocol.ProtocolError):
        protocol.decode(protocol.encode({**TKG_EVENT, "event_type": "mouse_wiggle"}))


def test_decode_rejects_non_object():
    with pytest.raises(protocol.ProtocolError):
        protocol.decode(b"[1,2,3]\n")


def test_round_trip_over_socket():
    async def scenario():
        # Short dir: AF_UNIX paths are capped at 104 bytes on macOS.
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            received: list[dict] = []
            server = BackendServer(Path(tmp) / "t.sock", received.append)
            await server.start()
            serve = asyncio.create_task(server.serve_forever())
            try:
                reader, writer = await asyncio.open_unix_connection(str(server.socket_path))

                writer.write(b"not json\n")  # must be dropped, not fatal
                writer.write(protocol.encode(TKG_EVENT))
                writer.write(protocol.encode({"type": "ping"}))
                await writer.drain()
                pong = protocol.decode(await asyncio.wait_for(reader.readline(), 2))
                assert pong["type"] == "pong"
                assert received == [TKG_EVENT]

                fired = protocol.trigger_fired(
                    suggestion_id="abc",
                    gate_score=0.83,
                    jspace_concepts=["stuck", "error"],
                    tkg_digest="digest",
                    timestamp=1.0,
                )
                await server.broadcast(fired)
                assert protocol.decode(await asyncio.wait_for(reader.readline(), 2)) == fired

                writer.close()
            finally:
                serve.cancel()
                await server.close()
            assert not server.socket_path.exists()

    asyncio.run(scenario())
