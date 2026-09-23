"""Cheap scalar features derived from the TKG, for the gate and the digest."""

from __future__ import annotations

from dataclasses import dataclass

from .graph import ErrorEvent, TemporalGraph

SWITCH_WINDOW_S = 180.0
RECENT_S = 120.0
LONG_IDLE_S = 45.0


@dataclass(frozen=True)
class Features:
    now: float

    # Where the user is.
    current_app: str | None
    current_title: str
    current_focus_s: float

    # Context switching.
    distinct_apps_2min: int
    app_switches_3min: int
    top_pair: tuple[str, str] | None  # the two apps switched between most (unordered)
    top_pair_switches_3min: int
    top_pair_pressure: float  # decayed switch count for that pair (all of the window)

    # Errors.
    max_error_recurrence: int  # occurrences of the most repeated signature in the window
    error_signature: str | None
    error_app: str | None
    error_title: str
    last_error_age_s: float | None
    error_pressure: float  # decayed occurrence count of that signature

    # Undo and typing.
    undo_count_2min: int
    undo_pressure: float
    burst_count_2min: int

    # Pauses.
    is_idle: bool
    last_idle_s: float | None  # length of the most recent completed idle period
    last_idle_age_s: float | None  # time since that idle period ended
    idle_then_burst: bool  # a long pause ended recently and activity picked up right after


def extract(g: TemporalGraph) -> Features:
    now = g.now
    focus = g.current_focus()

    recent_focus = [f for f in g.focus_events() if now - f.ts <= RECENT_S or f is focus]
    switches_3min = [(a, b) for a, b in g.app_switches() if now - b.ts <= SWITCH_WINDOW_S]

    # Ping-pong: switches between the same two apps, in either direction.
    pair_counts: dict[frozenset[str], int] = {}
    pair_pressure: dict[frozenset[str], float] = {}
    for a, b in g.app_switches():
        key = frozenset((a.app_bundle_id, b.app_bundle_id))
        pair_pressure[key] = pair_pressure.get(key, 0.0) + g.weight(b)
        if now - b.ts <= SWITCH_WINDOW_S:
            pair_counts[key] = pair_counts.get(key, 0) + 1
    top_key = max(pair_pressure, key=pair_pressure.__getitem__, default=None)

    # Most-repeated error signature, by decayed pressure (so an old storm loses to a fresh one).
    by_sig: dict[str, list[ErrorEvent]] = {}
    for e in g.errors():
        by_sig.setdefault(e.signature, []).append(e)
    top_errors = max(by_sig.values(), key=lambda es: sum(g.weight(e) for e in es), default=[])
    last_error = top_errors[-1] if top_errors else None

    undos = g.actions("undo")
    bursts = g.actions("keypress_burst")

    idle_starts = g.actions("idle_start")
    idle_ends = g.actions("idle_end")
    is_idle = bool(idle_starts) and (not idle_ends or idle_starts[-1].ts > idle_ends[-1].ts)
    last_idle = idle_ends[-1] if idle_ends else None
    last_idle_s = float(last_idle.metadata.get("idle_seconds", 0)) if last_idle else None
    last_idle_age = now - last_idle.ts if last_idle else None

    idle_then_burst = False
    if last_idle and last_idle_s is not None and last_idle_s >= LONG_IDLE_S and last_idle_age <= RECENT_S:
        after = [n for n in g.nodes if n.ts >= last_idle.ts and n is not last_idle]
        switches_after = sum(1 for _, b in g.app_switches() if b.ts >= last_idle.ts)
        errors_after = sum(1 for n in after if isinstance(n, ErrorEvent))
        undos_after = sum(1 for n in undos if n.ts >= last_idle.ts)
        idle_then_burst = switches_after >= 3 or errors_after >= 1 or undos_after >= 2

    return Features(
        now=now,
        current_app=focus.app_bundle_id if focus else None,
        current_title=focus.window_title if focus else "",
        current_focus_s=now - focus.ts_start if focus else 0.0,
        distinct_apps_2min=len({f.app_bundle_id for f in recent_focus}),
        app_switches_3min=len(switches_3min),
        top_pair=tuple(sorted(top_key)) if top_key else None,  # type: ignore[arg-type]
        top_pair_switches_3min=pair_counts.get(top_key, 0) if top_key else 0,
        top_pair_pressure=pair_pressure.get(top_key, 0.0) if top_key else 0.0,
        max_error_recurrence=len(top_errors),
        error_signature=last_error.signature if last_error else None,
        error_app=last_error.app_bundle_id if last_error else None,
        error_title=last_error.window_title if last_error else "",
        last_error_age_s=now - last_error.ts if last_error else None,
        error_pressure=sum(g.weight(e) for e in top_errors),
        undo_count_2min=sum(1 for u in undos if now - u.ts <= RECENT_S),
        undo_pressure=sum(g.weight(u) for u in undos),
        burst_count_2min=sum(1 for b in bursts if now - b.ts <= RECENT_S),
        is_idle=is_idle,
        last_idle_s=last_idle_s,
        last_idle_age_s=last_idle_age,
        idle_then_burst=idle_then_burst,
    )
