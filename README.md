# Wade v2

Context-aware macOS menu-bar assistant that decides *on its own* when there's something worth
saying (you're stuck, or what's in front of you invites an action), using J-space engagement
in a local model as the trigger. See `CLAUDE.md` for the full brief.

```
app/       SwiftUI menu-bar app (SwiftPM).
             WadeIPC   wire protocol + reconnecting UDS client
             WadeCore  memory stores (SQLite), integrations catalog, event detectors
             Wade      menu bar, onboarding, settings, AX/NSWorkspace observation
backend/   Python interpretability core (uv project).
             tkg/       Stage 1: temporal graph, features, stuck scorer, moments, digest
             synthetic  scenario builder + scenario library (expected/forbidden moments)
```

## Status: Phase 7 done (2026-09-25): v1 definition of done met (see below); next steps are listed at the end of the Phase 7 notes

### Open items carried forward

Deferred on purpose, so the phases stay in order. Each names the phase that owns it.

- **Phase 5 goal, real-trigger part: closed 2026-09-25.** A real moment (an apple.com phone
  comparison page) led to a Stage 2 fire, a suggestion, **Do it**, and a note written by the
  filesystem MCP server. See "Live run with the calibration" below.
- **Done in Phase 7 (details below):**
  - Stage 2 calibration against a labeled, family-split evaluation set.
  - The fair J = I vs learned J-lens comparison.
  - The "Clone" text / fork button mismatch.
- **Not reproduced:** `list_releases` failed once in Phase 5. In about 15 later runs it never
  failed, and `github-e2e` logs call arguments and errors in case it recurs.

Phase 1 (SwiftUI shell) was completed and verified on-device on 2026-09-23.

### Run it

```sh
# Terminal 1: backend (owns the socket)
cd backend && uv sync && uv run wade-backend

# Terminal 2: build + launch the signed app bundle (needed for the Accessibility grant)
cd app && scripts/bundle.sh && open build/Wade.app
```

Tests: `cd app && swift test` (56) and `cd backend && uv run pytest` (77).
Headless IPC check: `cd app && swift build && .build/debug/wade-ipc-check`.

Menu bar icon:
- dashed circle: not observing (backend down, setup unfinished, or no Accessibility access)
- circle: observing
- dotted circle: writing a suggestion
- filled: a suggestion is waiting that you haven't seen

Click the icon for the popover. Its **…** menu has Settings, Setup, Quit and the samples.

Socket: `~/Library/Application Support/Wade/wade.sock` (mode 0600), overridable on both
sides with `WADE_SOCKET_PATH`. Either process can start first; the app reconnects every 2s.
Memory: `~/Library/Application Support/Wade/memory.sqlite`.

### Stage 1: TKG and moments (Phase 2)

Wade speaks at **moments worth speaking**: when you're stuck, and at opportunities (a repo
page you could clone, a paragraph you could cite, a paper to save, a flight search, a
comparison). Stage 1 can't judge which moments are worth it, and it **never interrupts**. It
picks which moments get a Stage 2 look, within a compute budget. Only Stage 2 (Phase 3) can
surface anything. A test enforces that nothing in Stage 1 can send `trigger_fired`.

Every `tkg_event` goes into an in-process graph (`backend/src/wade_backend/tkg/`). The graph
keeps a 10-minute sliding window and decays older nodes with a 180s half-life. Nothing is
persisted.
- **Nodes:** `FocusEvent` (plus URL/excerpt once snapshotted), `ActionEvent`, `ErrorEvent`
  (plus text).
- **Edges:** `NEXT`, `SWITCHES_TO` (app-level, decayed frequency), `REPEATS` (same error
  signature), derived from the nodes on demand.

**Moment kinds** (`tkg/moments.py`):

| Kind | When | Shown to user? |
|---|---|---|
| `stuck` | the stuck scorer (below) crosses 0.5; 120s cooldown | if Stage 2 agrees |
| `selection` | you selected ≥15 chars and held the selection 2s | if Stage 2 agrees |
| `settled` | a content snapshot arrived and you stayed ≥15s; each context (app + URL/title) once per 10 min | if Stage 2 agrees |
| `audit` | nothing else checked for 5 min, and you're active | **never**, logged only, to measure what the other kinds miss |

**Budget:** at most one check per 20s and 60 per rolling hour. `stuck` bypasses both: it's
rare and the most valuable.

**Stuck scorer** (`tkg/gate.py`). Each rule saturates:

| Rule | Max | Saturation |
|---|---|---|
| `recurring_error` (same signature, decayed count) | 0.60 | 2 fresh → 0.4, 2.5+ → full |
| `app_pingpong` (same two apps, decayed switches) | 0.35 | 2 → 0, 6 → full |
| `undo_cluster` (decayed undos) | 0.25 | 1 → 0, 5 → full |
| `idle_then_burst` (≥45s pause, then errors/switches/undos within 2 min) | 0.15 | flag |
| `app_thrash` (≥5 distinct apps in 2 min) | 0.10 | flag |

No single non-error pattern can reach 0.5. The threshold stays there until Phase 3 measures
what a Stage 2 check costs, then it can move toward firing more often.

Known cheap false positive: coming back from a break (≥45s idle), then copy-pasting quickly
between two apps, scores 0.35 + 0.15 = 0.50 and requests a `stuck` check. It costs one Stage 2
look, never an interruption.

Each check carries Stage 2's two inputs (§5.4):
- **(a) context:** app, title, URL, excerpt, selection, recent error text
- **(b) digest:** plain facts only, with the domain but never the page text

The digest looks like this:

> In Xcode ('Wade — ActivityObserver.swift') for 11s; switched Xcode↔Safari 4x in the last
> 3min; the same error dialog in Xcode appeared 3x, last just now; 3 typing bursts in the last 2min.

The backend logs `CHECK REQUESTED kind=… | digest`. Screen text is logged only at `-v`.

**Scenarios** (`wade_backend.synthetic.SCENARIOS`): each states which kinds it must and must
not produce.
- **Stuck:** 4 scenarios, ≥ 0.56.
- **Routine:** 9 scenarios, stuck ≤ 0.35 and only occasional audits. They include
  `fast_copy_paste`, shaped after a real session: Chrome↔Figma, a switch every 1–5s.
- **Demo-derived opportunities:** repo page, cite a selection, read a paper, flight search,
  compare products.
- **Non-moments:** quick glances, a one-word selection.

The set is **constructed**, so passing it shows the rules behave as designed, not that they
predict need. That's Phase 7.

**Privacy check on-device** (2026-09-23): a fake password typed into a login field and text
typed into a web text box never appeared in any event. Chrome's address bar auto-selecting its
URL on click did produce `selection` events, which is why single-line inputs are now ignored.

**First real sample** (14 min, 2026-09-23): 30 checks/hour (4 settled, 1 selection, 1 audit,
1 stuck). The stuck check came from the developer's own test loop (Finder↔Chrome after an idle
minute).

Record and replay real sessions (the recording includes window titles and screen text, so
it's opt-in, and `*.jsonl` is gitignored). The replay prints checks per hour by kind:

```sh
cd backend && uv run wade-backend --record ~/wade-session.jsonl   # -v logs every event + score
uv run wade-replay ~/wade-session.jsonl [--all]
```

### Stage 2: J-lens trigger (Phase 3; calibrated in Phase 7)

The model is `mlx-community/Qwen3-4B-Instruct-2507-4bit`, loaded in 0.7s and run block by block.
Install it with `uv sync --extra stage2`. Stage 2 is optional: without it the backend runs
Stage 1 only.

```sh
uv run wade-stage2 build [--identity]   # J_ℓ precompute (slow) or J = I (seconds)
uv run wade-stage2 validate             # J-lens vs logit lens, top-5 agreement, held-out text
uv run wade-stage2 eval -v              # synthetic scenarios → Stage 2 → modes, concepts, latency
```

**Findings so far (2026-09-23):**
- **Latency:** median 0.93–0.97s, p95 0.98s per check on the M5. One prefill with no
  generation, plus J-space decomposition at 5 layers.
- **J-lens definition:** J must map into the **pre-norm** final residual, with the model's own
  norm applied after J, so that J = I is exactly the logit lens. Using the post-norm residual
  zeroes h's own direction, because RMSNorm is scale-invariant.
- **The learned J loses to the logit lens** at every layer, when estimated from 3–8 prompts (at
  L32: about 60% vs 82.5% top-5). All three estimators behave the same way: pairs, present-only
  and per-source. So does linearizing around the mean. That points to estimation noise. One
  prompt costs about 3 minutes of M5 GPU time, so the paper's 1,000 prompts would take about
  50 hours here.
- **Current lens: J = I** (the logit lens, the paper's named special case), built with
  `build --identity`. It is **not** the full J-lens, and nothing downstream should call it that.
- **Scenario eval with J = I**, first run: 5 of 14 correct (only the quiet audits).
  - The **prompt** matters. A yes/no question fills J-space with "yes"/"if"/"none". Listing
    Wade's affordances and asking for one verb makes the model's *output* mostly right.
  - The **J-space holds the right concepts but fragmented**: word pieces ("summariz"),
    Chinese tokens (检查 "check"), and filler. Families are now matched as *concepts*:
    translations plus unambiguous pieces of 4+ characters.
- **Readout choice, measured.** Reading the **final prompt position** at the lens-validated
  layers **23/27/32** gives **9 of 14 fire/quiet decisions correct in 375ms** (p95 378ms).
  - Stuck: 4 of 4 fire as "fixing".
  - Routine audits: 4 of 5 stay quiet. The one that fires sees a fresh error dialog.
  - Opportunities: 1 of 5 fire (repo page → coding). The others stay quiet: "nothing"
    outweighs the action concept. On a comparison page J-space holds *both* "compare" and
    "nothing", while the model's output picks "compare".
  - Reading the last 6 positions scores 8 of 14; all 5 layers, 9 of 14 but slower. The
    threshold was *not* tuned to these 14 hand-written checks.
- **End to end:** `uv run python scripts/stage2_e2e.py` replays a scenario into a real backend
  over the socket, with no screen observation. Result: a stuck check → Stage 2 in 437ms →
  `trigger_fired` with `mode: "fixing"`, the concepts and the digest.
- **Overnight learned J** (`scripts/overnight-jlens.sh`, 2026-09-25): 120 prompts × 32 tokens
  (hand-written set plus stdlib code and docstrings). Compute took 485 min with 1-min pauses
  (2 min every 5th) to limit heat. Top-5 agreement with the model's next token:

  | layer | learned J | logit lens (J = I) |
  |---|---|---|
  | 13 | **9.8%** | 2.8% |
  | 18 | **8.4%** | 6.3% |
  | 23 | 15.4% | **25.2%** |
  | 27 | 29.4% | **54.5%** |
  | 32 | 67.8% | **82.5%** |

  The learned J beats the logit lens in the **early** workspace layers, as the paper says it
  should, but not later on. At 120 prompts, not the paper's 1,000, its noise costs more than the
  correction gains once the model is near its output.
- **Readouts compared on the scenarios** (`scripts/compare_lenses.py`, fire/quiet correct):
  - J = I at 23/27/32: **9/14, 369ms**
  - learned J, all layers: 8/14, 464ms
  - learned J, 13/18 only: 5/14 (never fires)
  - mix (learned at 13/18, J = I later): 9/14, 467ms

  **Default stays J = I at 23/27/32.** Two observations:
  - The learned J gives cleaner, whole-word concepts (retry, grant, resolve, summarize,
    annotate) and exposes the model's multilingual workspace (Polish *wyjaśni* "explain",
    Chinese 念头 "thought").
  - Early-layer J-space reads the same concepts on *every* check ("prompt", 念头, "quiet",
    "suggestion", "ready"): it tracks the **task framing** ("suggest or stay quiet?"), not the
    user's situation. That's a finding for Phase 7 and the write-up, not a bug.
- **Archive:** `~/Library/Application Support/Wade/jlens-learned-120prompts.checkpoint.npz`
  (131 MB) holds the raw Jacobian sums for all 120 prompts. It's verified to match
  `jlens-learned.npz`. It can be **extended** rather than recomputed: copy it to
  `jlens-learned.checkpoint.npz` and run the build with `--prompts 240`, and the resume logic skips
  the first 120.
- **Latency target** (brief §10): p95 ≤ 1s per Stage 2 check on the M5. Measured: median
  369ms, p95 ~380ms with J = I; about 465ms with a learned J at all layers.

### Execution: writing the suggestion (Phase 4)

`app/Sources/WadeExecution/` implements the `ExecutionProvider` protocol (brief §5.5).
Implementations are interchangeable and yield **text deltas** through an
`AsyncThrowingStream`. It throws rather than using the brief's `AsyncStream`, so key, rate-limit
and network errors reach the UI.

**Catalog: vendor × model × route** (`ProviderCatalog`), all built by one factory into the same
protocol:

| Entry | Route | Leaves the Mac? |
|---|---|---|
| Gemini Flash (`gemini-flash-latest`) | direct API: `streamGenerateContent?alt=sse`, key in `x-goog-api-key`, `thinkingLevel: minimal` | yes, Google |
| **Gemini Flash-Lite** (`gemini-flash-lite-latest`), **default fallback** | same | yes, Google |
| Gemini Flash via Foundation Models | Firebase AI Logic `GeminiLanguageModel`: **needs a Firebase project + App Check + `GoogleService-Info.plist`**, listed as "needs setup" | yes |
| Claude Haiku 4.5 / Sonnet 5 / Opus 5 | Foundation Models, Anthropic's official [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels) 0.2.1 | yes, Anthropic |
| Claude Haiku 4.5 | direct API: Messages SSE | yes, Anthropic |
| **Apple on-device**, **default primary** | Foundation Models, `SystemLanguageModel.default` | **no** |

- **Default selection (a user decision, 2026-09-25, after live latency tests):** Apple on-device
  primary, Gemini Flash-Lite fallback. This departs from the brief's Claude Haiku default: there
  are no Claude credits yet, and Gemini's latency is unpredictable (below). Claude stays in the
  list.
- **No special-cased fallback** (brief §5.5). The *primary* and the optional *fallback* are two
  settings chosen from the same list, and `ProviderChain` runs them through one code path.
  - A provider is skipped when it can't start (no key, setup missing) or fails before any text.
  - Once text has streamed, an error is shown, never a switch mid-sentence.
  - Skips are shown to the user.
- **Direct route is vendor-neutral:** one HTTP/SSE loop plus a small `DirectWire` per vendor
  (`AnthropicWire`, `GeminiWire`).
- **Keys:** one per vendor, in the **Keychain** (Settings → Suggestions). A cloud entry without
  a key simply can't run. Claude's `.apiKey` auth is the package's development mode; shipping
  would use `.appAttest` or `.proxied`.
- **Prompt** (`ExecutionPrompt`):
  - The instructions are stable and cache-friendly.
  - The message carries the mode, the J-space concepts, the digest, the screen context
    (`trigger_fired.context`), your onboarding facts and your last corrections.
  - At most two sentences. `NOTHING` drops the suggestion, a second anti-Clippy guard.
- **Surface:** the menu-bar popover (Phase 6, below).
- **Measured, Apple on-device:** first words in **1.2–1.5s**, done in **1.3–1.7s**, both headless
  and inside the app. Output: *"Clone the repository using the web URL:
  https://github.com/dejesusbg/monet.git."*
- **No-text timeout: 2.5s by default, adjustable from 1.5 to 10s** (Settings → Suggestions →
  "Give up after"). `ProviderChain` skips any provider with no text by then (a late suggestion
  is useless) and moves to the next entry. Same rule for every provider. On-device fits at
  2.5s: 0.64–1.0s to first text in the app. At 1.0s even on-device misses its first answer
  after launch (verified), hence the 1.5s floor.
- **Older Gemini models, same session, real prompt, 5 runs each (2026-09-25):**

  | Model | Answered | First text | Under 2.5s |
  |---|---|---|---|
  | `gemini-3.5-flash` | 0/5 | 503 ×2, 30s timeout ×3 | 0 |
  | `gemini-3.5-flash-lite` | 5/5 | 0.76, 1.00, 1.61, 8.16, 14.86s | 3 |
  | `gemini-3.1-flash-lite` | 3/5 | 5.22, 12.80, 21.81s (+1 timeout, +1×503) | 0 |
  | `gemini-flash-lite-latest` (fallback) | 5/5 | 1.09, 1.63, 2.62, 2.67, 9.06s | 2 |

  Older models aren't faster. Flash-Lite 3.5 and the current alias behave about the same
  (median around 1.6s, long tails), and 3.1-lite is worse. Five runs in one session is a small,
  noisy sample.
- **Gemini, tested live (2026-09-25):**
  - The key can use `gemini-flash-latest`, `gemini-3.8-flash`, `gemini-3.5-flash`,
    `gemini-flash-lite-latest` and others (`wade-exec-check gemini-models`).
  - `gemini-2.5-flash` returns 404 for new keys. Google's message recommends its newer
    Interactions API.
  - **The wire is verified**: `gemini-flash-lite-latest` streamed *"Clone it with `git clone
    https://github.com/dejesusbg/monet.git`."*, with incremental chunks and `thoughtSignature`
    parts skipped. But the first token took 14s.
  - Full Flash models returned **503 "high demand"** repeatedly. Flash-Lite later hit the 8s
    timeout.
  - In the app, the default chain skipped Gemini and the on-device model wrote the suggestion:
    first text after 9.4s (the 8s timeout plus about 1.3s on-device).
- **Why Gemini is slow, measured (2026-09-25):** mostly **Google-side queueing**, not the model.
  - The same tiny prompt ("Say hello in five words") took **0.8s** on one run and **7.6s** on
    another. The Interactions API reported `total_thought_tokens: 0` on a 9.9s response.
  - With the real suggestion prompt and `thinkingLevel: minimal`, Flash-Lite answers in
    **0.8–0.95s** about half the time and is skipped at 2.5s otherwise.
  - Full Flash models kept returning 503 "high demand".
- **Interactions API (`/v1beta/interactions`), tried and not adopted:**
  - Its stream format was learned by probing: `interaction.created` → `step.start{thought}` →
    `step.delta{thought_signature}` → `step.start{model_output}` → `step.delta{text}`… →
    `interaction.completed` → `[DONE]`.
  - On the same prompt it took **5.6–8.8s**, against **0.8–0.9s** for `streamGenerateContent`,
    even with minimal thinking.
  - Re-run with `wade-exec-check gemini-raw <path> <body.json>`.
- **Dev tools:** `swift run wade-exec-check list` shows the catalog and key status;
  `wade-exec-check gemini-models` lists the Flash models the key can call;
  `wade-exec-check <id> [model]` overrides the model; `WADE_DEBUG_SSE=1` prints the raw stream.
  More:
  `swift run wade-exec-check <id>` streams the sample (keys from the Keychain);
  `open build/Wade.app --args --sample-suggestion` runs it inside the app.
- **Bug found end to end:** a Swift exclusivity crash in the engine (reading and writing
  `current` in one expression). Fixed.
- **§5.6 spike answer, for Phase 5:** ClaudeForFoundationModels exposes only server tools (web
  search, fetch, code execution), **not** the Messages API's remote MCP connector. So MCP through
  the Foundation Models route means the framework's client-side `Tool` protocol. The direct route
  could use Anthropic's connector (`mcp_servers` + `mcp_toolset`, beta `mcp-client-2025-11-20`).

### MCP tool layer (Phase 5)

`app/Sources/WadeTools/` runs the MCP servers for the integrations you opted into (official
[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) 0.12.1, stdio):

| Integration | Server | Access |
|---|---|---|
| Files | official `@modelcontextprotocol/server-filesystem@2026.8.31` (via `npx`, version pinned) | only the folders you pick in Settings → Integrations; notes go in the first |
| GitHub | official `github-mcp-server` 1.12.2 (`brew install github-mcp-server`) | your personal access token (Keychain), passed only in the server's environment |

**The action rule** (user decision, enforced once in `ToolBox`, the same for every provider):
- A tool the server explicitly marks `readOnlyHint: true` may run while a suggestion is being
  written, to make it specific.
- **Every other tool, unmarked ones included, never runs during composition.** Calling it
  records a *proposed action*, shown with a **Do it** button, and it runs only on that click.
- Servers' own labels: filesystem has 10 read-only and 4 write tools; GitHub has 26 read-only and
  19 write tools (incl. `merge_pull_request`, `delete_file`, `push_files`: none of those are offered).

**Tool selection** (`ToolSelection`). The on-device model has about a 4K-token context, and 45+
tool schemas don't fit, so each suggestion gets a small curated set:
- *notes moments* (selection, writing, research): the composed `save_note`
- *github.com pages*: `get_latest_release`, `list_releases` (lookups) plus `fork_repository`,
  `issue_write` (click-only)

**Tool composition** (`ComposedTools`): `wade__save_note(title, content)` maps onto the filesystem
server's `write_file`, with a path Wade builds itself (`<folder>/<date> <title>.md`; a title can't
escape the folder). Raw `write_file` needs a path the model doesn't know, and the small model
described the action instead of proposing it. With `save_note` it proposed in 5 of 5 runs.

**Bridges:**
- Foundation Models: each MCP tool becomes a `Tool` via `DynamicGenerationSchema` (on-device, and
  Claude later).
- Gemini: a function-calling loop that echoes the model's parts, including `thoughtSignature`.
  Schemas go in `parametersJsonSchema`: the older `parameters` field accepts only an OpenAPI
  subset and rejected GitHub's real schemas (`x-mcp-header`, `additionalProperties`, type lists).
- Claude's direct route: no tools yet (untested without credits).

**Timeout:** tool activity counts as progress, so a model busy proposing an action isn't cut off
before its first word.

**Verified:**
- Headless (`wade-exec-check tools-e2e <folder>`): on-device model → `save_note` proposed in about
  2s → simulated **Do it** → the filesystem server wrote the note, 5 of 5 runs.
- In the app (`--sample-note`): Wade starts the filesystem server itself, and the suggestion
  arrives with 1 proposal.
- In the app, by hand (2026-09-25): menu → Try a Sample Note Action → **Do it** wrote
  `~/Documents/Wade/2026-09-25 1226 Medical Image Analysis.md` through the filesystem server.

- GitHub, headless (`wade-exec-check github-e2e <owner/repo> [provider]`), on `ml-explore/mlx`:
  on-device proposed `fork_repository` in 2.8s, and Gemini Flash-Lite in 5.9s. The fork was only
  printed, never run. A direct `get_latest_release` returned v0.32.2. The server hides tools
  the token can't use: a read-only token exposed 24 tools, and read + write exposed 45.
- **Open issues:**
  - The on-device text said "Clone the repository" while its button would fork.
  - `list_releases` failed once, with no error captured. The check tool now logs call
    arguments and errors.

**Live run with Stage 2 (2026-09-25): 11 real checks, 0 fires.**
- The moments: Google and Reddit pages, a Wikipedia article, the GitHub dashboard, two repo
  pages, and three text selections.
- Each check took 0.5–1.0s. Every time, the "nothing" family matched or beat the best action
  family; "summarize" and "share" came up but lost.
- So no real trigger reached the tool path. The Phase 5 goal "from a real trigger through to a
  completed action" is **not met**. What's verified is the path from a made-up trigger to a
  completed action.
- This is the §8 generalization risk showing live: the one tested moment that fires (a repo page
  with the Clone menu open) doesn't carry over to ordinary pages. The threshold was **not**
  retuned on these few examples; calibration is Phase 7's job.

**Build note:** `scripts/build-check.sh` signs the check tool with your Apple Development
certificate, so a Keychain "Always Allow" survives rebuilds. Exception: Keychain items that
were approved for *earlier ad-hoc builds* keep stale per-build entries, and macOS keeps
prompting for them. Re-saving the key in Settings recreates the item and clears them.

### Menu bar suggestion UI (Phase 6)

**Status item and popover.** `StatusItemController` uses AppKit's `NSStatusItem` + `NSPopover`
rather than SwiftUI's `MenuBarExtra`, because Wade has to open the popover itself, and
`MenuBarExtra` opens only on a click. The popover is anchored to the icon: no cursor-follow,
and no floating window.

**When the popover opens by itself** (`SuggestionSurface`, pure and unit-tested):
- On the suggestion's first words, at most once per suggestion. If you close it, it stays
  closed, and the icon stays filled until you look.
- Never for an empty, "nothing worth offering", or failed suggestion.
- It opens without activating Wade, so whatever you're typing keeps focus. Clicking the icon, or
  **Correct…**, activates Wade so the popover can take keyboard focus.
- Untouched, it closes after 20s, unless the pointer is over it. Any click inside keeps it open.

**Feedback,** all explicit (§5.7):
- **Do it** runs a proposed action. That counts as accepting.
- **Thanks** accepts. Nothing is stored, since there's nothing to correct.
- **Not helpful** stores a `user_rejection` correction.
- **Correct…** stores what you type as a `user_correction`. It stays available after Thanks
  or Do it (e.g. "save it in another folder next time").
- Both kinds show up in Settings → Corrections, where you can forget them, and the next
  suggestions' prompts include the last 10.

**Windows:** Onboarding and Settings are AppKit windows (`WindowPresenter`), because
SwiftUI's `openWindow` / `SettingsLink` don't work from inside an AppKit popover. The separate
Phase 4 "Wade Suggestion" window is gone. There's no hotkey, which v1 dropped.

**Tried by hand (2026-09-25):**
- `--sample-note`: the popover opened by itself. **Do it** wrote
  `~/Documents/Wade/2026-09-25 1234 AI in Medical Imaging.md`.
- Sample repo suggestion: **Not helpful** stored `user_rejection` "Not helpful here."
- A second one: **Correct…** stored `user_correction` "just show me the latest release".

- With the backend running (`--sample-suggestion --sample-delay 30`):
  - Icons, in order: plain circle while watching → dotted while writing → filled when the popover
    opened by itself → still filled after it closed untouched → plain again after you opened it.
  - **Typing kept focus** in the other app when the popover opened by itself.
- Seen rule, fixed during this check: an auto-opened popover no longer counts as seen, so
  untouched suggestions keep the filled icon.

**Not yet seen live:** a real Stage 2 fire reaching the popover. It goes through the same
`execution.run` path as the samples, but no live fire has happened yet (see Open items).

### Evaluation harness (Phase 7)

```sh
uv run wade-eval cases                                  # the labeled set
uv run wade-eval collect --lens identity --prompt v2    # one model pass per lens × prompt (~1 min)
uv run wade-eval report [--save]                        # calibrate on one half, score the other
uv run wade-eval timing                                 # latency of the saved configuration
uv run wade-eval verdicts                               # real use: research logs joined
```

**The evaluation set** (`backend/src/wade_backend/evalset/cases.py`):
- **80 hand-written moments.** Each is what Stage 1 would hand Stage 2: the moment kind, the
  screen context and a digest in the template's own wording. None of it comes from your
  screen.
- **Labels were written before any run**, from one rule: *fire* only when a specific action
  would plausibly be welcome right now. *either* cases (a README with no Clone panel, a
  selection while reading) count in no score.
- **Split by situation family, not at random** (the §8 generalization risk):
  - *Calibration (41 cases):* developer errors and routine work, GitHub, documents, papers,
    shopping, everyday apps.
  - *Held-out (39 cases):* non-developer errors (spreadsheet, printer, VPN, Zoom, Figma, git
    merge, a campus upload); opportunities on unseen sites (GitLab, npm, Hugging Face, PubMed,
    SSRN, hotels, phones, Spanish text, medical and tax text); everyday apps the calibration
    half never shows; and **pages like the first live run's** (search results, a forum thread,
    an encyclopedia article, the GitHub dashboard, this terminal).
- The 14 Stage 1 pipeline scenarios join the calibration half, since Phase 3 already saw them.

**How it runs:**
- One forward pass per case per lens × prompt keeps every lens layer's family scores, so
  layers, rules and thresholds are swept **offline**. That's 3,816 configurations from 4 GPU
  runs of about 1 minute each. The "mix" lens is assembled from two runs.
- **Rules** (`stage2/rules.py`):
  - *beat-null*: the Phase 3 rule.
  - *margin*: best family − "nothing" ≥ m.
  - *z-score*: each family against its own level on quiet calibration cases.
  - The model's own next word, as a **control**.
- **Prompts:** v2 (Phase 3, names "nothing" as an answer) and v3 (leaves that out).
- **Objective:** F0.5 on fire/quiet, so precision counts twice recall, because a wrong
  interruption costs more trust than a missed one.
- **Intervals:** 95% Wilson.

**Results (2026-09-25, full report in `backend/eval/report-2026-09-25.txt`).** Held-out,
36 labeled cases:

| configuration | precision | recall | right mode |
|---|---|---|---|
| Phase 3 rule as shipped (J = I, v2, 23/27/32, beat-null) | 71% [36–92] | 26% [12–49] | 100% |
| control: the model's own next word | 88% | 37% | 71% |
| J = I, v2, 27/32, margin −0.04 | 88% [64–97] | 74% [51–88] | 64% |
| in-sample pick: learned J, v3, 32, z-score k=2.5 | 80% [55–93] | 63% [41–81] | 83% |
| **deployed, the CV pick: learned J, v3, all layers, z-score k=4** | **91% [62–98]** | **53% [32–73]** | 70% |

**What it shows:**
- **J-space adds something over asking the model.** At the same ~88% precision, a J-space rule
  finds about twice the moments the model's own answer does (74% vs 37%). That's the project's
  core thesis, supported on held-out data for the first time. With n = 36 the intervals are
  wide, so it's evidence, not proof.
- **The Phase 3 rule was far too quiet.** "Nothing" is named in the prompt and leads on almost
  every check, which is why the first live run fired 0 times.
- **Learned J vs J = I, the fair comparison: no meaningful difference** at the layers that
  decide. Configurations of both trade places within the intervals, and the early layers
  13/18 (the learned J's strength in validation) were never selected.
  - The learned J does read cleaner whole-word verbs (retry, allow, grant, clone, save,
    compare).
  - But **"share"** lights up almost everywhere on held-out pages, and that caused the
    in-sample pick's false fires (a forum thread, a terminal, an email).
- **Calibration overfits.** Among thousands of near-tied configurations, the best in-sample
  one lost 0.10 F0.5 on held-out.
  - So the deployed configuration is chosen by **leave-one-family-out cross-validation within
    the calibration half**: each family is predicted by parameters fitted on the others.
  - That criterion was added **after** the first held-out look. The held-out numbers above are
    therefore no longer a clean test of it. Clean evidence has to come from new data, i.e. the
    research log in real use.
- **Deployed behavior, precision first.** It fires on recurring errors, comparison pages and
  some paper pages. It stays quiet on **8 of 8 live-style pages** and 11 of 12 everyday ones.
  It **misses text selections** (translate, explain, cite) and most package pages. That's the
  open weakness.
- **Fragility:** "comparing" never appears on quiet calibration cases, so its z-score uses the
  spread floor, and any clear "compare" reading fires.
- **Latency** (deployed, 94 checks): median **465ms**, p95 **555ms**, max 1.2s. The target is
  p95 ≤ 1s.
- **Deployed config:** `~/Library/Application Support/Wade/stage2-calibration.json`, with a
  snapshot in `backend/eval/`. The backend loads the lens and rule together, since a rule
  calibrated on one lens means nothing on another. Without the file it falls back to the
  Phase 3 default.
- **The "why" line** now lists action-family concepts first ("fix, explain" before
  task-framing tokens like "prompt" or 念头 "thought").

**Research log (opt-in, off by default, no screen text):**
- Backend: `uv run wade-backend --eval-log` appends each check and Stage 2 decision to
  `~/Library/Application Support/Wade/eval/checks.jsonl`. It records app, domain, kind,
  scores, concepts and latency; never excerpts, selections, titles or the digest.
- App: Settings → Suggestions → **Research log** writes `verdicts.jsonl`: shown (auto or
  opened), ignored, accepted, rejected, corrected, action done or failed. It records mode,
  timings, provider and proposed tool names; never suggestion or correction text.
- `wade-eval verdicts` joins them on `suggestion_id`. It reports checks per hour, the fire rate
  per kind, and a real-use **welcome rate** (accepted ÷ judged, where ignored counts neither
  way).
- Tests assert that a check full of a made-up secret logs none of it.

**Live run with the calibration (2026-09-25, research logs on):**

| # | moment | Stage 2 | why |
|---|---|---|---|
| 1 | lock screen, settled (before the lock-screen fix) | quiet | "nothing, none, pause" |
| 2–3 | Frontiers paper: a selection, then settled 27s | quiet ×2 | "summarize, highlight" |
| 4 | this terminal, settled | quiet | "prompt, share" |
| 5 | arXiv abstract, settled | quiet | "summarize" |
| 6 | dialog probe ×2 → **stuck 0.73** (3rd repeat + ping-pong) | quiet | "wait, pause, stay, quiet". The dialog says "simulated error, nothing is wrong", so arguably right |
| 7 | **apple.com "iPhone Duo vs iPhone 17 Pro", settled 15s** | **FIRE comparing, 664ms** | "compare 0.027" |
| 8 | Finder selection | quiet | "share, navigate" |

- **#7 went end to end:**
  - The popover opened by itself.
  - Gemini Flash-Lite wrote the suggestion in 5.1s (the on-device model missed the 2.5s window).
  - It proposed `save_note`, and you clicked **Do it**.
  - The note `~/Documents/Wade/2026-09-25 153408 Apple iPhone Comparison.md` holds a titled
    link to the page.
  - The verdict log recorded `shown_auto → composed → accepted → action_done`, and
    `wade-eval verdicts` reported 8 checks, 1 fire (12%), median 676ms, welcome rate 1/1.
- **Finding, the evaluation set vs what Wade sees:** the hand-written paper cases fired
  "researching" because their excerpts included the page chrome ("Cite as · Download PDF").
  Real snapshots read the **main content** (the abstract), where the lens reads "summarize",
  not "save". So the evaluation set is closer to ideal pages than to real captures. Future
  cases should be written from what the observer actually captures, and the research log is
  the real test.
- **Finding, a context leak (fixed):** the probe's error text rode along on the apple.com
  page. Selections and error text now belong to the app in front. The one exception is error
  text on stuck checks, where the error is often in the app just left. The calibration wasn't
  re-run for this change: it only touches the pipeline scenarios' contexts, not the 80 cases.

**Notes that hold something (fixed after the live run):**
- **The problem:** the live note held only the page's link. In headless tests, a page showing
  only its title led the on-device model to **invent** content in 3 of 3 runs: made-up specs
  ("Snapdragon 8 Gen 3, 128 GB"), vague claims ("higher specs, faster processing"), or links
  padded with the title.
- **The fix, part 1:** `save_note` now asks for the substance (the passage, or one line per
  difference for a comparison, then `Source: <URL>`) and "only facts shown on screen".
- **The fix, part 2:** Wade checks every note before offering it (`Grounding`, in
  WadeExecution, deterministic):
  - Every number must appear on screen.
  - At most 30% of its content words (matched by word stem) may be missing from the screen.
  - At least 3 words must come from the page text itself, not the title.
  - A note that's only a link (Markdown links removed) is refused.
- **What a refusal does:** the note isn't proposed, and the model is told why. If a
  suggestion's only action was refused, the suggestion is dropped, like `NOTHING`, since
  there'd be nothing to click.
- **Measured, on-device, 11 runs:**
  - title-only page: **5 of 5 refused**, where before they were link-only or invented notes
  - rich comparison: **3 of 3** difference lists, where before they were a flat copy or a URL
    line
  - selection: **3 of 3** written, quoted or faithfully paraphrased
- **Unit tests** use those real good and bad notes as fixtures.

**Also fixed in Phase 7:**
- **Text vs button.** The on-device model's text now names the proposed action: "Fork
  repository …" in 7 of 7 runs, from 0 of 5. The tool result spells out the exact action the
  button runs, and the prompt's "The error means …" example only applies when an error is on
  screen.
- **Note overwrites.** Note filenames now include seconds, because two notes with the same
  title in the same minute overwrote each other.
- **Lock screen.** The observer ignores it (`loginwindow`, screen saver): a locked Mac was
  producing "settled" checks.

### Definition of done for v1 (brief §10), checked 2026-09-25

| requirement | status |
|---|---|
| The TKG gate fires / stays quiet correctly on the synthetic scenarios | ✅ `uv run pytest` (77), incl. moment, budget and "Stage 1 can't reach the user" tests |
| Stage 2 runs on-device within a measured latency target | ✅ target p95 ≤ 1s; deployed median 465ms, p95 555ms (94 checks); live median 676ms |
| At least one MCP-backed suggestion executes from a real trigger to a completed action | ✅ live run #7: comparison page → Stage 2 → popover → Do it → note written by the filesystem MCP server |
| Onboarding facts viewable/editable; correction facts accumulate from real interactions | ✅ Settings → About You / Corrections; Phase 6 run stored a `user_rejection` and a `user_correction` |
| All wired through the menu-bar UI, no cursor-following | ✅ NSStatusItem popover; no cursor-follow code anywhere |

**Honest limits, carried into v2:**
- Stage 2's precision is measured on 36 held-out hand-written cases (91% [62–98%]) and one
  short live session. Its recall on opportunities is low: text selections and paper pages
  don't fire.
- The evaluation set's excerpts are more idealized than real captures (see Phase 7).
- The research log (opt-in) is the way to get real numbers. Collect verdicts in real use,
  then recalibrate with `wade-eval` on fresh data. Don't recalibrate on the held-out set
  again: it has been looked at.
- Candidate next steps, each to be measured, not assumed:
  - write cases from real captures
  - add calibration-only anchor words the learned lens reads ("resolve", "allow",
    "troubleshoot")
  - make selections fire: "summarize" is already a writing word, but it also shows up on quiet
    reading pages, so that family's baseline is high and a selection's z stays around 2
  - an 8B model (§5.4's upgrade path)
  - selection-specific prompting

### What the app observes

Nothing is observed until onboarding is finished **and** Accessibility is granted. Revoking
access in System Settings stops observation within about a second.

| `event_type` | Source | Metadata |
|---|---|---|
| `focus_change` | app activation / AX focused-window change (300ms settle); focused-window title change only once stable for 2s, so title spinners and progress counters don't read as context switches; deduped | `cause`, `app_name` |
| `content_snapshot` | 4s after a focus change, if still there: the top-level page/document URL, plus a ≤500-char excerpt. Native editors: the visible text range. Web pages: page text from the `main` landmark or the web area under the window center | `url`, `excerpt`, `app_name` |
| `selection` | AX selected-text change, 1s debounce, ≥15 chars; ignored in single-line inputs (address bars, search boxes, form fields auto-select their content on click) | `text` (≤500), `length` |
| `error_dialog` | a sheet/dialog with error-like text (EN+ES keywords), found on window creation, focus change, or app activation; each dialog is reported once, while a new dialog with the same text counts as a recurrence | `signature` (16-hex hash, digits masked), `role`, `text` (≤200) |
| `keypress_burst` | global keyDown monitor → typing runs (gap 2s, ≥5 keys), closed on focus change | `key_count`, `duration_s`, `started_at` |
| `undo` | global keyDown monitor, ⌘Z | none |
| `idle_start` / `idle_end` | `CGEventSource` seconds-since-any-input, 30s threshold | `idle_seconds` (end) |

Privacy:
- **Keystrokes** are never captured, only counts and a ⌘Z flag.
- **Screen text** goes only to the local backend and is capped: excerpt 500, selection 500,
  dialog 200 characters.
- **Never read:** secure (password) fields, and any text field, text area, combo box or search
  field. That excludes what you type into forms, search boxes and chat inputs, including
  editable areas inside web pages.
- **Glances** shorter than 4s never read content.
- **Wade's own windows** are excluded.

Chromium browsers (Chrome, Brave, Edge, Arc, Vivaldi) only expose page content after an
assistive app sets `AXManualAccessibility`. Wade sets it for running Chromium browsers when
observation starts. The tree builds lazily, so a snapshot retries once after 3s.

Known gaps, kept on purpose for v1:
- Web-based editors (e.g. Google Docs) produce no excerpt, because their content is an editable
  area. Selection still works there.
- Canvas apps (e.g. Figma) expose noisy text; Stage 2 has to cope.
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
- `--refocus` also switches to Finder and back while the first alert is open. That's the
  Phase 2 check that a refocused dialog isn't counted twice. It's off by default, since the
  Finder hop adds app switching that nudges the stuck score.
- Two runs within a few minutes give 3+ repeats, which is a stuck check. Stage 2 then
  usually stays quiet, because the alert says nothing is wrong.

### Memory stores (§5.7)

One SQLite file, separate tables: `onboarding_facts` + `integration_opt_ins` (user-stated,
editable in Settings → About You) and `correction_facts` (provenance-tagged, shown in
Settings → Corrections). Explicit feedback only. Rejections and corrections are both
correction facts, told apart by `provenance`: `user_rejection` or `user_correction`.

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
