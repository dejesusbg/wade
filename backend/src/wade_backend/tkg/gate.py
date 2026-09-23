"""Stage 1 gate: a rule-based scorer over TKG features (CLAUDE.md §5.3).

Deliberately rules, not a learned model: there's no usage data to learn from yet. The gate is
a cheap pre-filter in front of the expensive Stage 2 check, so it leans toward recall. But
no single weak signal fires it on its own: comparing two documents (ping-pong), undoing a
typo, or one error dialog are ordinary work. Each rule saturates, so any one pattern caps
out, and the threshold takes either a strong error signal or two patterns together.

Weights and thresholds are hand-set against the synthetic scenarios in `wade_backend.synthetic`.
That set is constructed, not observed, so passing it shows the rules behave as designed,
not that they predict "needs help". That's Phase 7's job.
"""

from __future__ import annotations

from dataclasses import dataclass

from .features import Features


@dataclass(frozen=True)
class GateConfig:
    threshold: float = 0.5
    cooldown_s: float = 120.0

    # Each rule contributes weight * saturation, where saturation is clamped to [0, 1].
    # Same error, decayed count: 2 fresh → 0.4 (fires only with one more pattern), 2.5+ → full.
    error_weight: float = 0.6
    pingpong_weight: float = 0.35  # same app pair, decayed switches: 2 → 0, 6 → full
    undo_weight: float = 0.25  # decayed undos: 1 → 0, 5 → full
    idle_burst_weight: float = 0.15  # long pause, then errors/switches/undos
    thrash_weight: float = 0.1  # ≥5 distinct apps in 2 min
    thrash_apps: int = 5


@dataclass(frozen=True)
class GateDecision:
    fired: bool
    score: float
    reasons: tuple[str, ...]
    features: Features
    suppressed_by_cooldown: bool = False


def _sat(x: float) -> float:
    return max(0.0, min(1.0, x))


def score(f: Features, cfg: GateConfig = GateConfig()) -> tuple[float, tuple[str, ...]]:
    parts: list[tuple[float, str]] = [
        (cfg.error_weight * _sat((f.error_pressure - 1) / 1.5), "recurring_error"),
        (cfg.pingpong_weight * _sat((f.top_pair_pressure - 2) / 4), "app_pingpong"),
        (cfg.undo_weight * _sat((f.undo_pressure - 1) / 4), "undo_cluster"),
        (cfg.idle_burst_weight if f.idle_then_burst else 0.0, "idle_then_burst"),
        (cfg.thrash_weight if f.distinct_apps_2min >= cfg.thrash_apps else 0.0, "app_thrash"),
    ]
    total = min(1.0, sum(v for v, _ in parts))
    reasons = tuple(name for v, name in sorted(parts, reverse=True) if v > 0)
    return round(total, 3), reasons


class Gate:
    """Stateful wrapper: applies the threshold and a cooldown so one episode fires once."""

    def __init__(self, cfg: GateConfig = GateConfig()) -> None:
        self.cfg = cfg
        self.last_fire_ts: float | None = None

    def evaluate(self, f: Features) -> GateDecision:
        s, reasons = score(f, self.cfg)
        over = s >= self.cfg.threshold
        cooling = self.last_fire_ts is not None and f.now - self.last_fire_ts < self.cfg.cooldown_s
        fired = over and not cooling
        if fired:
            self.last_fire_ts = f.now
        return GateDecision(fired, s, reasons, f, suppressed_by_cooldown=over and cooling)
