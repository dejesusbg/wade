"""Replay recorded tkg_events (from `wade-backend --record FILE`) through Stage 1.

    uv run wade-replay session.jsonl            # gate fires only
    uv run wade-replay session.jsonl --all      # every event with its score

Real recordings are how the constructed scenarios get checked against actual behavior.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from pathlib import Path

from . import protocol
from .tkg import Stage1


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file", type=Path)
    parser.add_argument("--all", action="store_true", help="print every event, not just fires")
    args = parser.parse_args()

    fires = []
    stage1 = Stage1(on_fire=fires.append)
    count, peak = 0, 0.0
    for lineno, line in enumerate(args.file.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = protocol.decode(line.encode())
        except protocol.ProtocolError as e:
            print(f"{args.file}:{lineno}: skipped: {e}", file=sys.stderr)
            continue
        count += 1
        before = len(fires)
        d = stage1.ingest(event)
        peak = max(peak, d.score)
        when = dt.datetime.fromtimestamp(event["timestamp"]).strftime("%H:%M:%S")
        if args.all:
            print(f"{when} {event['event_type']:14} {event['app_bundle_id']:30} gate={d.score:.2f} {','.join(d.reasons)}")
        if len(fires) > before:
            print(f"{when} GATE FIRED score={d.score:.2f} reasons={','.join(d.reasons)}\n         {fires[-1].digest}")

    print(f"\n{count} events, {len(fires)} gate fires, peak score {peak:.2f}")


if __name__ == "__main__":
    main()
