"""Opt-in research log of moments and Stage 2 verdicts (CLAUDE.md §9, Phase 7: "log gate fires,
Stage 2 fires, and user verdicts for offline analysis").

One JSON line per check Stage 1 requested, with Stage 2's decision when it ran. The app
writes the matching user verdicts (shown, accepted, rejected, corrected, ignored) to its own
file keyed by the same ``suggestion_id``. ``wade-eval verdicts`` joins the two.

**No screen text, by construction:** no excerpt, selection, error text, window title or
digest. Only the app name, the page's domain, the moment kind and reasons, scores, the
J-space concepts (the same words Wade shows as "why") and timing. Off unless the backend is
started with ``--eval-log``.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from urllib.parse import urlparse

from .tkg import CheckRequest

DEFAULT_PATH = Path.home() / "Library/Application Support/Wade/eval/checks.jsonl"


def domain(url: str | None) -> str | None:
    if not url:
        return None
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return None  # file paths can be personal
    return parsed.netloc.removeprefix("www.") or None


def entry(check: CheckRequest, result=None, suggestion_id: str | None = None, config: str = "",
          now: float | None = None) -> dict:
    """The logged record for one check. Pure, so tests can assert what is (not) written."""
    ctx = check.context
    row = {
        "ts": round(now if now is not None else time.time(), 3),
        "kind": check.kind,
        "surface": check.surface,
        "reasons": list(check.reasons),
        "stuck_score": check.score,
        "app": ctx.get("app"),
        "domain": domain(ctx.get("url")),
        "has": sorted(k for k in ("excerpt", "selection", "error_text") if ctx.get(k)),
    }
    if result is not None:
        row["stage2"] = {
            "fire": result.fire,
            "mode": result.mode,
            "families": result.family_scores,
            "null": result.null_score,
            "concepts": [w for w, _ in result.concepts],
            "output_word": result.output_word,
            "latency_ms": round(result.latency_ms, 1),
            "config": config,
        }
    if suggestion_id:
        row["suggestion_id"] = suggestion_id
    return row


class ResearchLog:
    def __init__(self, path: Path = DEFAULT_PATH) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self._file = path.open("a", encoding="utf-8")
        self._lock = threading.Lock()  # Stage 2 results arrive on its worker thread

    def write(self, row: dict) -> None:
        with self._lock:
            self._file.write(json.dumps(row, ensure_ascii=False) + "\n")
            self._file.flush()

    def close(self) -> None:
        with self._lock:
            self._file.close()
