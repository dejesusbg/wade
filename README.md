# Wade v2

Context-aware macOS menu-bar assistant that decides *on its own* when help is warranted,
using J-space engagement in a local model as the trigger. See `CLAUDE.md` for the full brief.

```
app/       SwiftUI menu-bar app (SwiftPM). WadeIPC = wire protocol + UDS client.
backend/   Python interpretability core (uv project). Currently: UDS server only.
```

## Status: Phase 0 (environment, inventory, UDS round-trip)

### Run it

```sh
# Terminal 1: backend (owns the socket)
cd backend && uv sync && uv run wade-backend

# Terminal 2: headless round-trip check (exit 0 = pong received)
cd app && swift build && .build/debug/wade-ipc-check

# or the menu bar skeleton (glyph: dashed = backend down, circle = connected)
cd app && swift run Wade
```

Tests: `cd backend && uv run pytest`.

Socket: `~/Library/Application Support/Wade/wade.sock` (mode 0600), overridable on both
sides with `WADE_SOCKET_PATH`. Either process can start first; the app reconnects every 2s.

### Protocol

Newline-delimited JSON over `AF_UNIX`, shapes exactly as in CLAUDE.md §5.2
(`tkg_event` Swift→Py, `trigger_fired` Py→Swift), plus a `ping`/`pong` liveness pair.
Source of truth: `backend/src/wade_backend/protocol.py` ↔ `app/Sources/WadeIPC/Messages.swift`.

Deliberate choices:
- Events sent while disconnected are **dropped, not queued**. A stale TKG backlog
  replayed on reconnect would feed the gate a false burst.
- Malformed lines are logged and skipped. They never drop the connection.
- `metadata` is `[String: String]` on the Swift side for now. Widen it if Phase 1 needs numbers.

### Environment (verified 2026-09-22)

| Requirement (§6) | Found | OK |
|---|---|---|
| macOS 26+ | macOS 27.0 (26A428) | ✅ |
| Apple Silicon, 16GB | Apple M5, 16GB | ✅ |
| Apple Intelligence | opted in | ✅ |
| Xcode 26+ | **Command Line Tools only** | ⚠️ see below |
| Swift 6 | Swift 6.4 | ✅ |
| Python 3.11+ | system 3.9.6. Installed uv 0.12.17 → Python 3.12.14 (project-local) | ✅ |
| mlx / mlx-lm | on PyPI: mlx 0.32.2, mlx-lm 0.31.3 (not installed yet, Phase 3) | ✅ |
| FoundationModels.framework | present in CLT SDK | ✅ |

**Xcode gap:** CLT builds a SwiftPM executable fine, but it lacks the SwiftUI macro
plugin (`@State` fails; worked around in the skeleton). It also can't produce a signed `.app`
bundle. Phase 1 needs one, because Accessibility (TCC) permission attaches to a stable
bundle identity. Install Xcode before Phase 1.

### Legacy inventory (§3)

- `src-tauri/src/lib.rs`: `WadePacket {type: "message"|"action", data, skill?, arguments?}`
  over HTTP POST to `127.0.0.1:9090`. `rdev` Alt+Space executes the *pending* action, and
  the same `rdev` listener streams every mouse move to the overlay. Carried forward: typed,
  `type`-tagged JSON messages. Dropped: the TCP port and the global mouse tap.
- `OverlayWindow.tsx` / `Wade.tsx`: full-screen transparent click-through window with
  spring physics chasing the cursor, and a 15s auto-dismiss. `useTextStream` fakes streaming
  by revealing a finished string at 30–60ms/char. All dropped (§5.1, §5.5).
- `skills/*/manifest.json`: `{name, version, description, main, arguments: [string]}`.
  `arguments` is untyped names only, so an MCP `inputSchema` is a strict upgrade.
  `utils.py` = env loading + packet send + a hardcoded Gemini call. Skills report back by
  POSTing to the app, which is the kind of back-channel the UDS design removes.
- Ignored per brief: `backend/` (Neo4j/vector-DB services), `docker-compose.yml`.
