"""Unix-domain-socket server the Swift app connects to."""

from __future__ import annotations

import asyncio
import logging
import os
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from . import protocol

log = logging.getLogger(__name__)

EventHandler = Callable[[dict[str, Any]], None]


class BackendServer:
    def __init__(self, socket_path: Path, on_tkg_event: EventHandler | None = None,
                 on_config: EventHandler | None = None) -> None:
        self.socket_path = socket_path
        self._on_tkg_event = on_tkg_event or (lambda _event: None)
        self._on_config = on_config or (lambda _message: None)
        self._writers: set[asyncio.StreamWriter] = set()
        self._server: asyncio.AbstractServer | None = None

    async def start(self) -> None:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        # A stale socket file from a crashed run would make bind() fail.
        if self.socket_path.exists():
            self.socket_path.unlink()
        self._server = await asyncio.start_unix_server(self._handle_client, path=str(self.socket_path))
        os.chmod(self.socket_path, 0o600)
        log.info("listening on %s", self.socket_path)

    async def serve_forever(self) -> None:
        assert self._server is not None
        async with self._server:
            await self._server.serve_forever()

    async def close(self) -> None:
        for writer in list(self._writers):
            writer.close()
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
        self.socket_path.unlink(missing_ok=True)

    async def broadcast(self, message: dict[str, Any]) -> None:
        """Send to every connected app instance (normally exactly one)."""
        data = protocol.encode(message)
        for writer in list(self._writers):
            writer.write(data)
            await writer.drain()

    async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self._writers.add(writer)
        log.info("client connected")
        try:
            while line := await reader.readline():
                try:
                    message = protocol.decode(line)
                except protocol.ProtocolError as e:
                    # Never let one bad line take the connection down.
                    log.warning("dropping malformed message: %s", e)
                    continue
                await self._dispatch(message, writer)
        except ConnectionResetError:
            pass
        finally:
            self._writers.discard(writer)
            writer.close()
            log.info("client disconnected")

    async def _dispatch(self, message: dict[str, Any], writer: asyncio.StreamWriter) -> None:
        match message["type"]:
            case "ping":
                writer.write(protocol.encode({"type": "pong", "timestamp": time.time()}))
                await writer.drain()
            case "tkg_event":
                self._on_tkg_event(message)
            case "config":  # the app's settings that Stage 1 uses (e.g. the settled dwell)
                self._on_config(message)
            case other:
                log.warning("ignoring unknown message type %r", other)
