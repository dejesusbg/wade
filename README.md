# Wade v2

Context-aware macOS menu-bar assistant that decides *on its own* when help is warranted,
using J-space engagement in a local model as the trigger. See `CLAUDE.md` for the full brief.

```
app/       SwiftUI menu-bar app (SwiftPM).
             WadeIPC   wire protocol + reconnecting UDS client
             WadeCore  memory stores (SQLite), integrations catalog, event detectors
             Wade      menu bar, onboarding, settings, AX/NSWorkspace observation
backend/   Python interpretability core (uv project).
             tkg/       Stage 1: temporal graph, features, rule-based gate, digest
             synthetic  scenario builder + should/shouldn't-fire scenario library
```

## Status: Phase 2 (TKG + Stage 1 gate) done, check-in pending before Phase 3

Phase 1 (SwiftUI shell) was completed and verified on-device on 2026-09-23.

### Run it

```sh
# Terminal 1: backend (owns the socket)
cd backend && uv sync && uv run wade-backend

# Terminal 2: build + launch the signed app bundle (needed for the Accessibility grant)
cd app && scripts/bundle.sh && open build/Wade.app
```

Tests: `cd app && swift test` (14) and `cd backend && uv run pytest` (29).
Headless IPC check: `cd app && swift build && .build/debug/wade-ipc-check`.

Menu bar glyph: dashed = not observing (backend down, setup unfinished, or no Accessibility
access); circle = observing; filled = a trigger arrived.

Socket: `~/Library/Application Support/Wade/wade.sock` (mode 0600), overridable on both
sides with `WADE_SOCKET_PATH`. Either process can start first; the app reconnects every 2s.
Memory: `~/Library/Application Support/Wade/memory.sqlite`.

### Stage 1: TKG and gate (Phase 2)

Every `tkg_event` goes into an in-process graph (`backend/src/wade_backend/tkg/`). The graph
keeps a 10-minute sliding window and decays older nodes with a 180s half-life. Nothing is
persisted.
- **Nodes:** `FocusEvent`, `ActionEvent`, `ErrorEvent`.
- **Edges:** `NEXT`, `SWITCHES_TO` (app-level, decayed frequency), `REPEATS` (same error
  signature). Edges are derived from the nodes on demand, so pruning can't leave dangling ones.

After each event the **rule-based gate** scores the current state. Each rule saturates:

| Rule | Max | Saturation |
|---|---|---|
| `recurring_error` (same signature, decayed count) | 0.60 | 2 fresh → 0.4, 2.5+ → full |
| `app_pingpong` (same two apps, decayed switches) | 0.35 | 2 → 0, 6 → full |
| `undo_cluster` (decayed undos) | 0.25 | 1 → 0, 5 → full |
| `idle_then_burst` (≥45s pause, then errors/switches/undos within 2 min) | 0.15 | flag |
| `app_thrash` (≥5 distinct apps in 2 min) | 0.10 | flag |

It fires at **≥ 0.5**, with a 120s cooldown so one episode fires once. By construction, no
single non-error pattern can fire it. It takes three recent identical errors, or a repeated
error plus one more pattern, or several weaker patterns together. On a fire, the backend
logs the score, the reasons and the **digest**, e.g.:

> In Xcode ('Wade — ActivityObserver.swift') for 11s; switched Xcode↔Safari 4x in the last
> 3min; the same error dialog in Xcode appeared 3x, last just now; 3 typing bursts in the last 2min.

In Phase 2 a gate fire is only logged. Phase 3 passes it to the Stage 2 J-lens check, and only
a Stage 2 fire becomes `trigger_fired`.

**Scenarios** (`wade_backend.synthetic`): all 4 should-fire scenarios score ≥ 0.56, and all 8
should-not-fire scenarios score ≤ 0.21. The should-not-fire set includes stuck-looking
routines: copy-paste ping-pong, typo undos, a one-off error, errors 8 min apart, many tabs,
and opening many apps. The set is **constructed**, so passing it shows the rules do what
they're designed to do, not that they predict need. That's Phase 7.

**Real data:** one 20-minute on-device session (not committed) peaked at 0.28 during routine
work (Chrome↔Terminal ping-pong only). It fired once, on the dialog-probe run (the same
error twice, plus switching).

Record and replay real sessions (the recording includes window titles, so it's opt-in, and
`*.jsonl` is gitignored):

```sh
cd backend && uv run wade-backend --record ~/wade-session.jsonl   # -v logs every event + score
uv run wade-replay ~/wade-session.jsonl [--all]
```

### What Phase 1 observes

Nothing is observed until onboarding is finished **and** Accessibility is granted. Revoking
access in System Settings stops observation within about a second.

| `event_type` | Source | Metadata |
|---|---|---|
| `focus_change` | app activation / AX focused-window change (300ms settle); focused-window title change only once stable for 2s, so title spinners and progress counters don't read as context switches; deduped | `cause` |
| `error_dialog` | a sheet/dialog with error-like text (EN+ES keywords), found on window creation, focus change, or app activation; each dialog is reported once, while a new dialog with the same text counts as a recurrence | `signature` (16-hex hash, digits masked), `role` |
| `keypress_burst` | global keyDown monitor → typing runs (gap 2s, ≥5 keys), closed on focus change | `key_count`, `duration_s`, `started_at` |
| `undo` | global keyDown monitor, ⌘Z | none |
| `idle_start` / `idle_end` | `CGEventSource` seconds-since-any-input, 30s threshold | `idle_seconds` (end) |

Privacy: key contents are never stored or sent (only counts and a ⌘Z flag), and dialog text
is reduced to a hash. Wade's own windows are excluded.

Known gaps, kept on purpose for v1:
- In-window error UI that isn't a dialog (e.g. Xcode's "Build Failed" banner) is not detected.
  Revisit if Phase 7 shows it matters.
- No global hotkey (dropped for v1), so no Input Monitoring permission is needed.
  Accessibility alone covers the key monitor.

### Signing

`scripts/bundle.sh` signs with the first **Apple Development** certificate in your keychain
(or `$WADE_SIGN_IDENTITY`). macOS then ties the Accessibility grant to "this bundle id,
signed by this developer", which survives rebuilds and can't be claimed by other apps.

Without a certificate it falls back to ad-hoc signing, with the requirement pinned to
`identifier "com.ricardo.wade"` only. That also survives rebuilds (verified), but any locally
built app claiming that id would inherit Wade's Accessibility access. It's fine for bootstrapping.

Get a certificate once: Xcode → Settings → Accounts → your Apple ID → Manage Certificates…
→ **+** → Apple Development. If `security find-identity -v -p codesigning` then says
"0 valid identities", the keychain is missing Apple's current intermediate. Install it with
`curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer && security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db`.
(This Mac only had the G1 intermediate, which expired in 2023.)

After switching signing identity, run `tccutil reset Accessibility com.ricardo.wade`, then
use menu bar → Grant Accessibility Access…, so the grant is recorded against the new,
certificate-based requirement.

### Manual checks

`scripts/dialog-probe.sh` pops up two clearly labeled *fake* error alerts for about 11s. With
Wade running, expect exactly two `error_dialog` events from `com.wade.dialog-probe` with
equal signatures.

### Memory stores (§5.7)

One SQLite file, separate tables: `onboarding_facts` + `integration_opt_ins` (user-stated,
editable in Settings → About You) and `correction_facts` (provenance-tagged, shown in
Settings → Corrections, empty until Phase 6 writes to it). Explicit feedback only.

### Protocol

Newline-delimited JSON over `AF_UNIX`, shapes exactly as in CLAUDE.md §5.2
(`tkg_event` Swift→Py, `trigger_fired` Py→Swift), plus a `ping`/`pong` liveness pair.
Source of truth: `backend/src/wade_backend/protocol.py` ↔ `app/Sources/WadeIPC/Messages.swift`.

Deliberate choices:
- Events sent while disconnected are **dropped, not queued**. A stale TKG backlog
  replayed on reconnect would feed the gate a false burst.
- Malformed lines are logged and skipped. They never drop the connection.
- `metadata` values are scalar JSON (string/int/double/bool).

### Environment (verified 2026-09-23)

| Requirement (§6) | Found | OK |
|---|---|---|
| macOS 26+ | macOS 27.0 (26A428) | ✅ |
| Apple Silicon, 16GB | Apple M5, 16GB | ✅ |
| Apple Intelligence | opted in | ✅ |
| Xcode 26+ | Xcode 27.0 (27A266a) | ✅ |
| Swift 6 | Swift 6.4 | ✅ |
| Python 3.11+ | system 3.9.6. Installed uv 0.12.17 → Python 3.12.14 (project-local) | ✅ |
| mlx / mlx-lm | on PyPI: mlx 0.32.2, mlx-lm 0.31.3 (not installed yet, Phase 3) | ✅ |
| FoundationModels.framework | present in SDK | ✅ |

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
