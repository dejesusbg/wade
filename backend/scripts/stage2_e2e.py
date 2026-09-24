"""End-to-end Stage 2 check without observing anyone: start a real backend on a temp socket,
replay a synthetic scenario into it (time-shifted to now), and wait for `trigger_fired`.

    uv run python scripts/stage2_e2e.py [scenario]      # default: build_loop
"""

import asyncio
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from wade_backend import protocol, synthetic


async def main(name: str) -> int:
    session = synthetic.SCENARIOS[name].build()
    offset = time.time() - session.events[-1]["timestamp"]  # last event lands at "now"
    with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
        sock = Path(tmp) / "e2e.sock"
        log = open(Path(tmp) / "backend.log", "w+")
        backend = subprocess.Popen(
            [sys.executable, "-m", "wade_backend", "--socket", str(sock)],
            stdout=log, stderr=subprocess.STDOUT, env={"PYTHONUNBUFFERED": "1", **__import__("os").environ})
        try:
            t0 = time.time()
            while "Stage 2 ready" not in Path(log.name).read_text():
                if backend.poll() is not None or time.time() - t0 > 120:
                    print(Path(log.name).read_text()); return 1
                await asyncio.sleep(0.5)
            reader, writer = await asyncio.open_unix_connection(str(sock))
            for e in session.events:
                writer.write(protocol.encode({**e, "timestamp": e["timestamp"] + offset}))
            await writer.drain()
            print(f"sent {len(session.events)} events of '{name}'; waiting for trigger_fired …")
            line = await asyncio.wait_for(reader.readline(), 60)
            message = protocol.decode(line)
            print(json.dumps(message, indent=2, ensure_ascii=False))
            writer.close()
            print("\nbackend log (Stage 1 / Stage 2):")
            print("\n".join(l for l in Path(log.name).read_text().splitlines() if "CHECK" in l or "STAGE2" in l))
            return 0 if message["type"] == "trigger_fired" else 1
        finally:
            backend.terminate()
            backend.wait()


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "build_loop")))
