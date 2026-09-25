from __future__ import annotations

import argparse
import asyncio
import json
import logging
import signal
import time
from pathlib import Path

from . import protocol
from .research_log import DEFAULT_PATH as EVAL_LOG_PATH
from .research_log import ResearchLog, entry
from .server import BackendServer
from .stage2.runner import Stage2Runner, new_suggestion_id
from .tkg import CheckRequest, Stage1

log = logging.getLogger("wade_backend")


def pid_alive(pid: int) -> bool:
    import os

    try:
        os.kill(pid, 0)  # signal 0: existence check only
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by someone else
    return True


def explanation_order(concepts: list[tuple[str, float]]) -> list[str]:
    """J-space concepts for the "why" line: anchor-family words first (the ones that explain
    the decision), then the rest by weight. Task-framing tokens that sit on every check
    ("prompt", 念头 "thought") stay in the list but no longer lead it."""
    from .stage2 import anchors

    family = [w for w, _ in concepts if anchors.family_of(w) not in (None, "null")]
    return family + [w for w, _ in concepts if w not in family]


def main() -> None:
    parser = argparse.ArgumentParser(description="Wade backend (TKG gate + J-lens trigger)")
    parser.add_argument("--socket", type=Path, default=None, help="UDS path (default: $WADE_SOCKET_PATH or ~/Library/Application Support/Wade/wade.sock)")
    parser.add_argument("--record", type=Path, default=None, metavar="FILE",
                        help="append every raw tkg_event to FILE as JSON lines (includes window titles; off by default)")
    parser.add_argument("--eval-log", type=Path, nargs="?", const=EVAL_LOG_PATH, default=None, metavar="FILE",
                        help=f"append every check and Stage 2 decision to FILE (no screen text; default {EVAL_LOG_PATH})")
    parser.add_argument("--exit-with-pid", type=int, default=None, metavar="PID",
                        help="exit when process PID is gone (the app passes its own PID when it starts the backend)")
    parser.add_argument("-v", "--verbose", action="store_true", help="log every event and gate score")
    parser.add_argument("--stage1-only", action="store_true", help="don't load the Stage 2 model")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    research = ResearchLog(args.eval_log) if args.eval_log else None
    if research:
        log.info("research log on: %s (no screen text)", research.path)
    loop_ref: dict[str, asyncio.AbstractEventLoop] = {}
    server: BackendServer  # assigned below; referenced from Stage 2 results

    # Stage 2 result: only a fire on a surfaceable moment becomes `trigger_fired` for the app.
    # Audits are judged and logged too (that's their point) but never reach the user.
    def on_stage2(check: CheckRequest, result) -> None:
        concepts = ", ".join(f"{w} {c:.3f}" for w, c in result.concepts[:5])
        log.info("STAGE2 %s kind=%s mode=%s %.0fms | %s", "FIRE" if result.fire else "quiet",
                 check.kind, result.mode, result.latency_ms, concepts)
        surfaced = result.fire and check.surface
        suggestion_id = new_suggestion_id() if surfaced else None
        if research:
            research.write(entry(check, result, suggestion_id, runner.config_label if runner else ""))
        if not surfaced:
            return
        message = protocol.trigger_fired(
            suggestion_id=suggestion_id,
            gate_score=check.score if check.score is not None else 0.0,
            jspace_concepts=explanation_order(result.concepts),
            tkg_digest=check.digest,
            timestamp=time.time(),
            mode=result.mode,
            kind=check.kind,
            context=check.context,
        )
        loop = loop_ref["loop"]
        loop.call_soon_threadsafe(lambda: loop.create_task(server.broadcast(message)))

    reason = None if args.stage1_only else Stage2Runner.available()
    runner = Stage2Runner(on_stage2) if reason is None and not args.stage1_only else None
    if runner is None:
        log.warning("Stage 2 off: %s. Checks are logged only.", reason or "--stage1-only")

    def on_check(check: CheckRequest) -> None:
        score = f" score={check.score:.2f}" if check.score is not None else ""
        log.info("CHECK REQUESTED kind=%s%s surface=%s reasons=%s | %s", check.kind, score,
                 check.surface, ",".join(check.reasons), check.digest)
        # Screen content (excerpt, selection, error text) only at -v, never at INFO.
        log.debug("check context: %s", check.context)
        if runner:
            if not runner.submit(check) and research:
                research.write(entry(check) | {"dropped": True})  # Stage 2 busy or loading
        elif research:
            research.write(entry(check))

    stage1 = Stage1(on_check=on_check)
    record = args.record.open("a", encoding="utf-8") if args.record else None

    def on_tkg_event(event: dict) -> None:
        if record:
            record.write(json.dumps(event, ensure_ascii=False) + "\n")
            record.flush()
        decision = stage1.ingest(event)
        log.debug(
            "tkg_event %-16s %s | %r %s | stuck %.2f %s",
            event["event_type"], event["app_bundle_id"], event.get("window_title", ""),
            event.get("metadata") or "", decision.score, ",".join(decision.reasons),
        )

    def on_config(message: dict) -> None:
        if "settled_dwell_s" in message:
            try:
                applied = stage1.moments.set_settle(message["settled_dwell_s"])
                log.info("config: settled after %.0fs", applied)
            except (TypeError, ValueError):
                log.warning("ignoring bad settled_dwell_s %r", message.get("settled_dwell_s"))

    server = BackendServer(args.socket or protocol.default_socket_path(), on_tkg_event, on_config)

    async def run() -> None:
        # SIGTERM is how launchd / the app will stop us; SIGINT is ignored when run as a
        # background job. Handle both explicitly so the socket file is always removed.
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        loop_ref["loop"] = loop
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)

        async def ticker() -> None:
            # Dwell, held selections and audits are about time passing, not events arriving.
            while True:
                stage1.tick(time.time())
                await asyncio.sleep(1)

        async def watch_parent(pid: int) -> None:
            # The app may be killed or crash without a chance to stop us: don't outlive it.
            while True:
                await asyncio.sleep(2)
                if not pid_alive(pid):
                    log.info("app (pid %d) is gone; shutting down", pid)
                    stop.set()
                    return

        await server.start()
        serve = asyncio.create_task(server.serve_forever())
        ticks = asyncio.create_task(ticker())
        watcher = asyncio.create_task(watch_parent(args.exit_with_pid)) if args.exit_with_pid else None
        try:
            await stop.wait()
            log.info("shutting down")
        finally:
            ticks.cancel()
            serve.cancel()
            if watcher:
                watcher.cancel()
            if runner:
                runner.close()
            await server.close()
            if record:
                record.close()
            if research:
                research.close()

    asyncio.run(run())


if __name__ == "__main__":
    main()
