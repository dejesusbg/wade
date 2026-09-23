"""Stage 1: temporal-state graph, features, moment detection, digest (CLAUDE.md §5.3)."""

from __future__ import annotations

from collections.abc import Callable, Iterable
from typing import Any

from . import digest
from .features import Features, extract
from .gate import Gate, GateConfig, GateDecision, score
from .graph import ActionEvent, ErrorEvent, FocusEvent, TemporalGraph
from .moments import CheckRequest, MomentConfig, MomentDetector

__all__ = [
    "ActionEvent", "CheckRequest", "ErrorEvent", "Features", "FocusEvent", "Gate", "GateConfig",
    "GateDecision", "MomentConfig", "MomentDetector", "Stage1", "TemporalGraph", "digest",
    "extract", "score",
]


class Stage1:
    """Graph + moment detector. Feed it every `tkg_event` and call `tick` about once a second;
    it calls `on_check` with each moment that deserves a Stage 2 look.

    Stage 1 has no way to reach the user: it only produces CheckRequests.
    """

    def __init__(
        self,
        on_check: Callable[[CheckRequest], None] | None = None,
        gate_config: GateConfig = GateConfig(),
        moment_config: MomentConfig = MomentConfig(),
        window_s: float = 600.0,
        half_life_s: float = 180.0,  # matches the 3-min episode scale the features use
    ) -> None:
        self.graph = TemporalGraph(window_s=window_s, half_life_s=half_life_s)
        self.moments = MomentDetector(moment_config, gate_config)
        self._on_check = on_check or (lambda _check: None)

    def ingest(self, event: dict[str, Any]) -> GateDecision:
        self.graph.ingest(event)
        decision, check = self.moments.on_event(self.graph)
        if check:
            self._on_check(check)
        return decision

    def tick(self, now: float) -> CheckRequest | None:
        if not self.graph.nodes:
            return None
        self.graph.advance(now)
        check = self.moments.on_tick(self.graph)
        if check:
            self._on_check(check)
        return check

    def replay(self, events: Iterable[dict[str, Any]], until: float | None = None,
               step: float = 1.0) -> list[GateDecision]:
        """Feed recorded/synthetic events with a simulated 1s clock between them."""
        decisions: list[GateDecision] = []
        clock: float | None = None
        for event in events:
            ts = float(event["timestamp"])
            if clock is None:
                clock = ts
            while clock + step <= ts:
                clock += step
                self.tick(clock)
            decisions.append(self.ingest(event))
        if clock is not None and until is not None:
            while clock + step <= until:
                clock += step
                self.tick(clock)
        return decisions
