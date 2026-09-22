from __future__ import annotations

import argparse
import asyncio
import logging
import signal
from pathlib import Path

from . import protocol
from .server import BackendServer

log = logging.getLogger("wade_backend")


def main() -> None:
    parser = argparse.ArgumentParser(description="Wade backend (TKG gate + J-lens trigger)")
    parser.add_argument("--socket", type=Path, default=None, help="UDS path (default: $WADE_SOCKET_PATH or ~/Library/Application Support/Wade/wade.sock)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    # Phase 0: events are only logged. Phase 2 replaces this with TKG ingestion.
    def on_tkg_event(event: dict) -> None:
        log.info("tkg_event %s from %s", event["event_type"], event["app_bundle_id"])

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

    asyncio.run(run())


if __name__ == "__main__":
    main()
