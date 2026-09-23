"""Templated natural-language digest of recent history (CLAUDE.md §5.3).

This is what gives Stage 2 situational *history* instead of a single snapshot: v1's attempt
at the multi-token / situational-concept problem (§2). Plain facts only, no interpretation
("user is stuck" is for Stage 2 to conclude, not for the template to assert).
"""

from __future__ import annotations

from .features import Features
from .graph import TemporalGraph


def _dur(seconds: float) -> str:
    seconds = max(0, round(seconds))
    if seconds < 60:
        return f"{seconds}s"
    m, s = divmod(seconds, 60)
    return f"{m}min" if s < 10 else f"{m}min {s}s"


def _title(title: str, limit: int = 60) -> str:
    title = " ".join(title.split())
    return title if len(title) <= limit else title[: limit - 1] + "…"


def render(g: TemporalGraph, f: Features) -> str:
    parts: list[str] = []

    if f.current_app:
        where = g.app_name(f.current_app)
        if f.current_title:
            where += f" ('{_title(f.current_title)}')"
        parts.append(f"In {where} for {_dur(f.current_focus_s)}")

    if f.top_pair and f.top_pair_switches_3min >= 3:
        pair = sorted(f.top_pair, key=lambda app: app != f.current_app)  # current app first
        a, b = (g.app_name(x) for x in pair)
        parts.append(f"switched {a}↔{b} {f.top_pair_switches_3min}x in the last 3min")
    elif f.app_switches_3min >= 3:
        parts.append(f"{f.app_switches_3min} app switches across {f.distinct_apps_2min} apps recently")

    if f.max_error_recurrence >= 1 and f.error_app and f.last_error_age_s is not None:
        app = g.app_name(f.error_app)
        when = "just now" if f.last_error_age_s < 5 else f"{_dur(f.last_error_age_s)} ago"
        if f.max_error_recurrence >= 2:
            parts.append(f"the same error dialog in {app} appeared {f.max_error_recurrence}x, last {when}")
        else:
            parts.append(f"an error dialog appeared in {app} {when}")

    if f.undo_count_2min >= 2:
        parts.append(f"{f.undo_count_2min} undos in the last 2min")

    if f.is_idle:
        parts.append("currently idle")
    elif f.last_idle_s and f.last_idle_age_s is not None and f.last_idle_age_s <= 300 and f.last_idle_s >= 30:
        parts.append(f"was idle {_dur(f.last_idle_s)} until {_dur(f.last_idle_age_s)} ago")

    if f.burst_count_2min:
        parts.append(f"{f.burst_count_2min} typing bursts in the last 2min")

    if not parts:
        return "No notable activity."
    text = "; ".join(parts)
    return text[0].upper() + text[1:] + "."
