"""Stage 1: temporal-state graph, features, rule-based gate, digest (CLAUDE.md §5.3)."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from . import digest
from .features import Features, extract
from .gate import Gate, GateConfig, GateDecision, score
from .graph import ActionEvent, ErrorEvent, FocusEvent, TemporalGraph

__all__ = [
    "ActionEvent", "ErrorEvent", "Features", "FocusEvent", "Gate", "GateConfig",
    "GateDecision", "GateFire", "Stage1", "TemporalGraph", "extract", "score",
]


@dataclass(frozen=True)
class GateFire:
    """Handed to Stage 2 (Phase 3) when the gate fires."""
    decision: GateDecision
    digest: str


class Stage1:
    """Graph + gate. Feed it every `tkg_event`; it calls `on_fire` when the gate fires."""

    def __init__(
        self,
        on_fire: Callable[[GateFire], None] | None = None,
        gate_config: GateConfig = GateConfig(),
        window_s: float = 600.0,
        half_life_s: float = 180.0,  # matches the 3-min episode scale the features use
    ) -> None:
        self.graph = TemporalGraph(window_s=window_s, half_life_s=half_life_s)
        self.gate = Gate(gate_config)
        self._on_fire = on_fire or (lambda _fire: None)

    def ingest(self, event: dict[str, Any]) -> GateDecision:
        self.graph.ingest(event)
        decision = self.gate.evaluate(extract(self.graph))
        if decision.fired:
            self._on_fire(GateFire(decision, digest.render(self.graph, decision.features)))
        return decision
