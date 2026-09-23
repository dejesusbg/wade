"""Replay recorded tkg_events (from `wade-backend --record FILE`) through Stage 1.

    uv run wade-replay session.jsonl            # moments only, plus a per-kind summary
    uv run wade-replay session.jsonl --all      # also every event with its stuck score

Real recordings are how the constructed scenarios get checked against actual behavior,
and how the check budget (checks/hour by kind) gets measured.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from collections import Counter
from pathlib import Path

from . import protocol
from .tkg import CheckRequest, Stage1


def _hms(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).strftime("%H:%M:%S")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file", type=Path)
    parser.add_argument("--all", action="store_true", help="print every event, not just moments")
    args = parser.parse_args()

    events = []
    for lineno, line in enumerate(args.file.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            events.append(protocol.decode(line.encode()))
        except protocol.ProtocolError as e:
            print(f"{args.file}:{lineno}: skipped: {e}", file=sys.stderr)
    if not events:
        print("no events")
        return

    def on_check(c: CheckRequest) -> None:
        score = f" score={c.score:.2f}" if c.score is not None else ""
        hidden = "" if c.surface else " (audit, never shown)"
        print(f"{_hms(c.ts)} CHECK {c.kind}{score}{hidden} reasons={','.join(c.reasons)}\n         {c.digest}")

    stage1 = Stage1(on_check=on_check)
    checks: list[CheckRequest] = []
    original = stage1._on_check
    stage1._on_check = lambda c: (checks.append(c), original(c))  # type: ignore[method-assign]

    if args.all:
        for e in events:
            d = stage1.replay([e])
            print(f"{_hms(e['timestamp'])} {e['event_type']:16} {e['app_bundle_id']:30} stuck={d[0].score:.2f}")
    else:
        stage1.replay(events, until=events[-1]["timestamp"])

    hours = max((events[-1]["timestamp"] - events[0]["timestamp"]) / 3600, 1 / 60)
    by_kind = Counter(c.kind for c in checks)
    summary = ", ".join(f"{k} {n}" for k, n in sorted(by_kind.items())) or "none"
    print(f"\n{len(events)} events over {hours * 60:.0f} min; checks: {summary}; "
          f"{len(checks) / hours:.0f} checks/hour")


if __name__ == "__main__":
    main()
