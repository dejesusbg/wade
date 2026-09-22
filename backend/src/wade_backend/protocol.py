"""Wire protocol between the Swift app and this backend (CLAUDE.md §5.2).

Transport: AF_UNIX stream socket, newline-delimited JSON (one object per line).

Swift -> Python:  tkg_event (frequent, one-directional), ping
Python -> Swift:  trigger_fired (rare, one-shot), pong

`ping`/`pong` are not in the brief's two-shape spec; they exist only as a
liveness check so the app can tell "backend down" from "backend quiet".
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

TKG_EVENT_TYPES = frozenset(
    {"focus_change", "keypress_burst", "undo", "error_dialog", "idle_start", "idle_end"}
)

SOCKET_ENV_VAR = "WADE_SOCKET_PATH"


def default_socket_path() -> Path:
    override = os.environ.get(SOCKET_ENV_VAR)
    if override:
        return Path(override)
    return Path.home() / "Library" / "Application Support" / "Wade" / "wade.sock"


class ProtocolError(ValueError):
    pass


def encode(message: dict[str, Any]) -> bytes:
    return json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n"


def decode(line: bytes) -> dict[str, Any]:
    try:
        message = json.loads(line)
    except json.JSONDecodeError as e:
        raise ProtocolError(f"invalid JSON: {e}") from e
    if not isinstance(message, dict) or not isinstance(message.get("type"), str):
        raise ProtocolError("message must be an object with a string 'type'")
    if message["type"] == "tkg_event":
        validate_tkg_event(message)
    return message


def validate_tkg_event(message: dict[str, Any]) -> None:
    event_type = message.get("event_type")
    if event_type not in TKG_EVENT_TYPES:
        raise ProtocolError(f"unknown event_type: {event_type!r}")
    if not isinstance(message.get("timestamp"), (int, float)):
        raise ProtocolError("tkg_event.timestamp must be a number")
    if not isinstance(message.get("app_bundle_id"), str):
        raise ProtocolError("tkg_event.app_bundle_id must be a string")
    if not isinstance(message.get("window_title", ""), str):
        raise ProtocolError("tkg_event.window_title must be a string")
    if not isinstance(message.get("metadata", {}), dict):
        raise ProtocolError("tkg_event.metadata must be an object")


def trigger_fired(
    *,
    suggestion_id: str,
    gate_score: float,
    jspace_concepts: list[str],
    tkg_digest: str,
    timestamp: float,
) -> dict[str, Any]:
    return {
        "type": "trigger_fired",
        "suggestion_id": suggestion_id,
        "gate_score": gate_score,
        "jspace_concepts": jspace_concepts,
        "tkg_digest": tkg_digest,
        "timestamp": timestamp,
    }
