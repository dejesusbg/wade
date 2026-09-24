"""Runs Stage 2 off the event loop, one check at a time.

The model loads in the worker thread at startup (a few seconds), so the socket is live at once.
A check that arrives while another is running is dropped and logged rather than queued: Stage 1's
budget makes that rare, and a stale moment isn't worth judging late.
"""

from __future__ import annotations

import logging
import threading
import uuid
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from ..tkg import CheckRequest

log = logging.getLogger("wade_backend.stage2")

OnResult = Callable[[CheckRequest, "object"], None]


class Stage2Runner:
    def __init__(self, on_result: OnResult, lens_path: Path | None = None) -> None:
        from .jlens import DEFAULT_PATH

        self.lens_path = lens_path or DEFAULT_PATH
        self._on_result = on_result
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="stage2")
        self._busy = threading.Lock()
        self._stage2 = None
        self._pool.submit(self._load)

    @staticmethod
    def available(lens_path: Path | None = None) -> str | None:
        """None if Stage 2 can run; otherwise the reason it can't."""
        try:
            import mlx.core  # noqa: F401
            import mlx_lm  # noqa: F401
        except ImportError:
            return "the stage2 extra isn't installed (uv sync --extra stage2)"
        from .jlens import DEFAULT_PATH

        if not (lens_path or DEFAULT_PATH).exists():
            return f"no J-lens at {lens_path or DEFAULT_PATH} (uv run wade-stage2 build)"
        return None

    def _load(self) -> None:
        from .check import Stage2

        log.info("loading Stage 2 model and J-lens …")
        self._stage2 = Stage2.load(lens_path=self.lens_path)
        log.info("Stage 2 ready (J-lens layers %s)", self._stage2.jl.layers)

    def submit(self, check: CheckRequest) -> None:
        if not self._busy.acquire(blocking=False):
            log.info("Stage 2 busy; dropped %s check", check.kind)
            return
        self._pool.submit(self._run, check)

    def _run(self, check: CheckRequest) -> None:
        try:
            if self._stage2 is None:  # still loading: the load task runs first in this thread
                log.info("Stage 2 not ready; dropped %s check", check.kind)
                return
            result = self._stage2.evaluate(check)
            self._on_result(check, result)
        except Exception:
            log.exception("Stage 2 failed on %s check", check.kind)
        finally:
            self._busy.release()

    def close(self) -> None:
        self._pool.shutdown(wait=False, cancel_futures=True)


def new_suggestion_id() -> str:
    return str(uuid.uuid4())
