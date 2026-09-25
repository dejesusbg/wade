"""Real-use analysis: the backend's check log joined with the app's verdict log.

Both logs are opt-in and hold no screen text (see `research_log` and the app's `VerdictLog`).
The join key is `suggestion_id`, set by the backend when a Stage 2 fire is sent to the app.
"""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path

POSITIVE = {"accepted", "action_done"}
NEGATIVE = {"rejected", "corrected"}


def load(path: Path) -> list[dict]:
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue  # a line cut off by a crash; skip it
    return rows


def outcome(events: list[str]) -> str:
    """One label per suggestion, from everything that happened to it."""
    ev = set(events)
    if "composed" in ev and not ev & {"shown_auto", "opened"} and not ev & (POSITIVE | NEGATIVE):
        return "not shown"  # e.g. the writer said NOTHING, or it failed
    if ev & NEGATIVE:
        return "corrected" if "corrected" in ev and not ev & {"rejected"} else "rejected"
    if ev & POSITIVE:
        return "accepted"
    if "closed_unseen" in ev and "opened" not in ev:
        return "ignored"
    return "seen, no verdict"


def report(checks: list[dict], verdicts: list[dict], include_samples: bool = False) -> str:
    lines: list[str] = []
    if not checks and not verdicts:
        return "No research logs yet. Turn on Settings → Suggestions → Research log, and start the backend with --eval-log."
    if checks:
        span_h = max((checks[-1]["ts"] - checks[0]["ts"]) / 3600, 1e-9)
        by_kind = Counter(c["kind"] for c in checks)
        ran = [c for c in checks if "stage2" in c]
        fired = [c for c in ran if c["stage2"]["fire"]]
        lines.append(f"checks: {len(checks)} over {span_h * 60:.0f} min ({len(checks) / span_h:.0f}/h) · "
                     + ", ".join(f"{k} {n}" for k, n in sorted(by_kind.items())))
        lines.append(f"Stage 2 ran on {len(ran)}, fired on {len(fired)} "
                     f"({len(fired) / max(len(ran), 1):.0%}); dropped while busy {sum(1 for c in checks if c.get('dropped'))}")
        lat = sorted(c["stage2"]["latency_ms"] for c in ran)
        if lat:
            lines.append(f"Stage 2 latency median {lat[len(lat) // 2]:.0f} ms, max {lat[-1]:.0f} ms")
        fire_by = Counter((c["kind"], c["stage2"]["mode"]) for c in fired)
        if fire_by:
            lines.append("fires: " + ", ".join(f"{k}/{m} {n}" for (k, m), n in fire_by.most_common()))

    by_sid: dict[str, list[dict]] = defaultdict(list)
    for v in verdicts:
        if include_samples or not v.get("sample"):
            by_sid[v["suggestion_id"]].append(v)
    if by_sid:
        outcomes = {sid: outcome([v["event"] for v in vs]) for sid, vs in by_sid.items()}
        counts = Counter(outcomes.values())
        lines.append(f"\nsuggestions: {len(by_sid)} · " + ", ".join(f"{k} {n}" for k, n in counts.most_common()))
        judged = counts["accepted"] + counts["rejected"] + counts["corrected"]
        if judged:
            lines.append(f"welcome rate (accepted / judged): {counts['accepted'] / judged:.0%} of {judged}; "
                         f"ignored {counts['ignored']} are not counted either way")
        per_mode: dict[str, Counter] = defaultdict(Counter)
        for sid, vs in by_sid.items():
            per_mode[next((v.get("mode") for v in vs if v.get("mode")), "?")][outcomes[sid]] += 1
        for mode, c in sorted(per_mode.items()):
            lines.append(f"  {mode:12} " + ", ".join(f"{k} {n}" for k, n in c.most_common()))
        check_sids = {c.get("suggestion_id") for c in checks if c.get("suggestion_id")}
        unmatched = [sid for sid in by_sid if sid not in check_sids and not sid.startswith("sample")]
        if checks and unmatched:
            lines.append(f"({len(unmatched)} suggestions have no backend check row: backend log was off)")
    return "\n".join(lines)
