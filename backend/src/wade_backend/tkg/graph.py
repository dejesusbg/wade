"""Stage 1 temporal-state graph (CLAUDE.md §5.3).

In-process and ephemeral: a sliding window of recent nodes, nothing persisted. It answers one
question only, "is right now worth checking further?". Cross-session user preference lives in
the Swift memory stores (§5.7), never here.

Nodes are kept in timestamp order. Edges are *derived* from the nodes on demand, not stored,
so pruning old nodes can never leave dangling edges behind:

  NEXT         consecutive nodes in time
  SWITCHES_TO  consecutive FocusEvents in different apps, weighted by decayed frequency
  REPEATS      an ErrorEvent to the next ErrorEvent with the same signature

All times come from event timestamps, never the wall clock, so replays and tests are
deterministic. "Now" is the latest timestamp seen.
"""

from __future__ import annotations

import bisect
import math
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, Iterator


@dataclass
class FocusEvent:
    app_bundle_id: str
    app_name: str
    window_title: str
    ts_start: float
    ts_end: float | None = None  # None while it's the current focus

    @property
    def ts(self) -> float:
        return self.ts_start


@dataclass
class ActionEvent:
    type: str  # keypress_burst | undo | idle_start | idle_end
    ts: float
    app_context: str  # bundle id of the app in front when it happened
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class ErrorEvent:
    app_bundle_id: str
    signature: str
    ts: float
    recurrence_count: int  # 1 for the first occurrence of this signature within the window
    window_title: str = ""


Node = FocusEvent | ActionEvent | ErrorEvent


class TemporalGraph:
    def __init__(self, window_s: float = 600.0, half_life_s: float = 180.0) -> None:
        self.window_s = window_s
        self.half_life_s = half_life_s
        self.nodes: list[Node] = []
        self.now = 0.0
        self.app_names: dict[str, str] = {}

    # ---- ingestion -------------------------------------------------------------------

    def ingest(self, event: dict[str, Any]) -> Node | None:
        """Add one validated `tkg_event`. Returns the node created, or None if it was a no-op."""
        ts = float(event["timestamp"])
        app = event["app_bundle_id"]
        meta = event.get("metadata") or {}
        self.now = max(self.now, ts)

        if name := meta.get("app_name"):
            self.app_names[app] = name

        match event["event_type"]:
            case "focus_change":
                node = self._focus(app, event.get("window_title", ""), ts)
            case "error_dialog":
                sig = str(meta.get("signature", ""))
                prior = sum(1 for n in self.errors() if n.signature == sig)
                node = ErrorEvent(app, sig, ts, prior + 1, event.get("window_title", ""))
            case other:
                node = ActionEvent(other, ts, app, dict(meta))

        if node is not None:
            self._insert(node)
        self.prune()
        return node

    def _focus(self, app: str, title: str, ts: float) -> FocusEvent | None:
        current = self.current_focus()
        if current and current.app_bundle_id == app and current.window_title == title:
            return None
        if current and current.ts_end is None:
            current.ts_end = ts
        return FocusEvent(app, self.app_name(app), title, ts)

    def _insert(self, node: Node) -> None:
        # Events can arrive slightly out of order (e.g. a typing burst is stamped at its end but
        # sent after the next focus change), so insert by time, not arrival.
        idx = bisect.bisect_right([n.ts for n in self.nodes], node.ts)
        self.nodes.insert(idx, node)

    def prune(self) -> None:
        cutoff = self.now - self.window_s
        # Keep the current focus even if it began long ago: it's still where the user is.
        current = self.current_focus()
        self.nodes = [n for n in self.nodes if n.ts >= cutoff or n is current]

    # ---- views -----------------------------------------------------------------------

    def weight(self, node: Node) -> float:
        """Exponential decay: 1.0 now, 0.5 one half-life ago."""
        return math.pow(0.5, max(0.0, self.now - node.ts) / self.half_life_s)

    def focus_events(self) -> list[FocusEvent]:
        return [n for n in self.nodes if isinstance(n, FocusEvent)]

    def errors(self) -> list[ErrorEvent]:
        return [n for n in self.nodes if isinstance(n, ErrorEvent)]

    def actions(self, type: str | None = None) -> list[ActionEvent]:
        return [n for n in self.nodes if isinstance(n, ActionEvent) and (type is None or n.type == type)]

    def current_focus(self) -> FocusEvent | None:
        for n in reversed(self.nodes):
            if isinstance(n, FocusEvent):
                return n
        return None

    def app_name(self, bundle_id: str) -> str:
        return self.app_names.get(bundle_id) or _fallback_app_name(bundle_id)

    # ---- edges -----------------------------------------------------------------------

    def next_edges(self) -> Iterator[tuple[Node, Node]]:
        return zip(self.nodes, self.nodes[1:])

    def app_switches(self) -> list[tuple[FocusEvent, FocusEvent]]:
        """Consecutive focus events that crossed an app boundary, oldest first."""
        focus = self.focus_events()
        return [(a, b) for a, b in zip(focus, focus[1:]) if a.app_bundle_id != b.app_bundle_id]

    def switch_edges(self) -> dict[tuple[str, str], float]:
        """SWITCHES_TO: (from_app, to_app) -> decayed frequency."""
        edges: dict[tuple[str, str], float] = defaultdict(float)
        for a, b in self.app_switches():
            edges[(a.app_bundle_id, b.app_bundle_id)] += self.weight(b)
        return dict(edges)

    def repeat_edges(self) -> list[tuple[ErrorEvent, ErrorEvent]]:
        """REPEATS: each error to the next occurrence of the same signature."""
        last: dict[str, ErrorEvent] = {}
        edges = []
        for e in self.errors():
            if e.signature in last:
                edges.append((last[e.signature], e))
            last[e.signature] = e
        return edges


# Only used when the app didn't send `app_name`. The last bundle-id component is usually right.
_KNOWN_APPS = {
    "com.apple.dt.Xcode": "Xcode",
    "com.google.Chrome": "Chrome",
    "com.microsoft.VSCode": "VS Code",
    "com.apple.systempreferences": "System Settings",
}


def _fallback_app_name(bundle_id: str) -> str:
    if bundle_id in _KNOWN_APPS:
        return _KNOWN_APPS[bundle_id]
    last = bundle_id.rsplit(".", 1)[-1]
    return last[:1].upper() + last[1:] if last else bundle_id
