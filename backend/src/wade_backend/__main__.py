from __future__ import annotations

import argparse
import asyncio
import json
import logging
import signal
from pathlib import Path

from . import protocol
from .server import BackendServer
from .tkg import GateFire, Stage1

log = logging.getLogger("wade_backend")


def main() -> None:
    parser = argparse.ArgumentParser(description="Wade backend (TKG gate + J-lens trigger)")
    parser.add_argument("--socket", type=Path, default=None, help="UDS path (default: $WADE_SOCKET_PATH or ~/Library/Application Support/Wade/wade.sock)")
    parser.add_argument("--record", type=Path, default=None, metavar="FILE",
                        help="append every raw tkg_event to FILE as JSON lines (includes window titles; off by default)")
    parser.add_argument("-v", "--verbose", action="store_true", help="log every event and gate score")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    # Phase 2: a gate fire is only logged. Phase 3 hands it to the Stage 2 J-lens check,
    # and only a Stage 2 fire becomes a `trigger_fired` message to the app.
    def on_fire(fire: GateFire) -> None:
        d = fire.decision
        log.info("GATE FIRED score=%.2f reasons=%s | %s", d.score, ",".join(d.reasons), fire.digest)

    stage1 = Stage1(on_fire=on_fire)
    record = args.record.open("a", encoding="utf-8") if args.record else None

    def on_tkg_event(event: dict) -> None:
        if record:
            record.write(json.dumps(event, ensure_ascii=False) + "\n")
            record.flush()
        decision = stage1.ingest(event)
        log.debug(
            "tkg_event %-14s %s | %r %s | gate %.2f %s",
            event["event_type"], event["app_bundle_id"], event.get("window_title", ""),
            event.get("metadata") or "", decision.score, ",".join(decision.reasons),
        )

    server = BackendServer(args.socket or protocol.default_socket_path(), on_tkg_event)

    async def run() -> None:
        # SIGTERM is how launchd / the app will stop us; SIGINT is ignored when run as a
        # background job. Handle both explicitly so the socket file is always removed.
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)

        await server.start()
        serve = asyncio.create_task(server.serve_forever())
        try:
            await stop.wait()
            log.info("shutting down")
        finally:
            serve.cancel()
            await server.close()
            if record:
                record.close()

    asyncio.run(run())


if __name__ == "__main__":
    main()
