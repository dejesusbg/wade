"""The Phase 7 evaluation set: hand-written Stage 2 inputs with labels (CLAUDE.md §9, Phase 7).

Each case is what Stage 1 would hand Stage 2: a moment kind, the screen context (§5.4 input a)
and the digest (input b, in the template's own wording). Cases are written directly as check
requests rather than as event sessions, so the set can cover many situations cheaply. The 14
pipeline scenarios in `wade_backend.synthetic` stay as a separate end-to-end set.

**Labels were written before any model run on this set**, from one rule: *fire* only when
there is a specific action the user would plausibly welcome right now (a fix for a problem
they keep hitting, or a quick action on what's in front of them). *quiet* when they're doing
fine on their own. *either* when reasonable people would disagree; those count in no score and
are reported separately.

**Split by situation family, not at random.** Calibration families and held-out families use
different apps, sites and phrasings (e.g. build errors in Xcode for calibration; spreadsheet,
printer and VPN errors held out). A decision rule tuned on the calibration half and scored on
the held-out half is being tested on situations it has never seen: the probe-generalization
risk of §8. The `live` family mirrors the kinds of pages from the first live run (2026-09-25):
search results, a forum thread, an encyclopedia article, a dashboard, a terminal. Those pages
are rewritten generically, not copied from the user's screen.

All text below is written for this file (short, paraphrased snippets of the kind of text such
pages show). None of it comes from the user's screen.
"""

from __future__ import annotations

from dataclasses import dataclass

from ..tkg import CheckRequest

CAL, TEST = "calibration", "held-out"
FIRE, QUIET, EITHER = "fire", "quiet", "either"


@dataclass(frozen=True)
class Case:
    id: str
    split: str  # CAL | TEST
    family: str  # situation family (the split unit)
    label: str  # FIRE | QUIET | EITHER
    mode: str | None  # expected mode when label == FIRE
    check: CheckRequest
    note: str = ""


def _case(id: str, split: str, family: str, label: str, mode: str | None, kind: str, *,
          app: str, digest: str, title: str = "", url: str = "", excerpt: str = "",
          selection: str = "", error: str = "", note: str = "") -> Case:
    context = {k: v for k, v in {
        "app": app, "title": title, "url": url, "excerpt": excerpt,
        "selection": selection, "error_text": error,
    }.items() if v}
    reasons = {"stuck": ("error_recurring",), "selection": ("text_selected",),
               "settled": ("context_settled",)}.get(kind, ("audit",))
    check = CheckRequest(kind=kind, ts=0.0, reasons=reasons, digest=digest, context=context,
                         surface=True, score=0.7 if kind == "stuck" else None)
    assert label in (FIRE, QUIET, EITHER) and (mode is not None) == (label == FIRE), id
    return Case(id, split, family, label, mode, check, note)


C = _case
CASES: list[Case] = [
    # ─────────────────────────── calibration ───────────────────────────
    # dev-stuck: build/test/permission errors in developer tools
    C("xcode_build_loop", CAL, "dev-stuck", FIRE, "fixing", "stuck", app="Xcode",
      title="Wade — Build Failed", error="Build Failed: Command SwiftCompile failed with a nonzero exit code",
      excerpt="error: cannot find 'ExecutionEngine' in scope · Wade/WadeApp.swift:42",
      digest="In Xcode ('Wade — Build Failed') for 20s; switched Xcode↔Safari 6x in the last 3min; the same error dialog in Xcode appeared 3x, last just now; 3 typing bursts in the last 2min."),
    C("terminal_permission", CAL, "dev-stuck", FIRE, "fixing", "stuck", app="Terminal",
      title="ricardo — zsh", error="Permission denied (publickey).",
      excerpt="$ git push origin main\ngit@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
      digest="In Terminal ('ricardo — zsh') for 35s; switched Terminal↔Google Chrome 5x in the last 3min; the same error dialog in Terminal appeared 3x, last 12s ago."),
    C("npm_install_fail", CAL, "dev-stuck", FIRE, "fixing", "stuck", app="Terminal",
      title="web — npm install", error="npm ERR! code ERESOLVE unable to resolve dependency tree",
      excerpt="npm ERR! code ERESOLVE\nnpm ERR! ERESOLVE unable to resolve dependency tree\nnpm ERR! peer react@\"^18\" from react-dom@18.3.1",
      digest="In Terminal ('web — npm install') for 50s; the same error dialog in Terminal appeared 2x, last 20s ago; was idle 1min until 30s ago; 2 typing bursts in the last 2min."),
    C("pytest_same_failure", CAL, "dev-stuck", FIRE, "fixing", "stuck", app="Terminal",
      title="backend — pytest", error="FAILED tests/test_tkg.py::test_budget - AssertionError",
      excerpt="FAILED tests/test_tkg.py::test_budget - AssertionError: assert 61 <= 60\n1 failed, 56 passed in 0.92s",
      digest="In Terminal ('backend — pytest') for 15s; switched Terminal↔Visual Studio Code 7x in the last 3min; the same error dialog in Terminal appeared 4x, last just now; 4 typing bursts in the last 2min."),
    C("xcode_signing", CAL, "dev-stuck", FIRE, "fixing", "stuck", app="Xcode",
      title="Wade — Signing & Capabilities", error="Signing for \"Wade\" requires a development team.",
      excerpt="Signing for \"Wade\" requires a development team. Select a development team in the Signing & Capabilities editor.",
      digest="In Xcode ('Wade — Signing & Capabilities') for 40s; the same error dialog in Xcode appeared 3x, last 8s ago; 3 undos in the last 2min."),
    C("docker_port_in_use", CAL, "dev-stuck", FIRE, "fixing", "stuck", app="Terminal",
      title="api — docker compose up", error="Bind for 0.0.0.0:5432 failed: port is already allocated",
      excerpt="Error response from daemon: driver failed programming external connectivity: Bind for 0.0.0.0:5432 failed: port is already allocated",
      digest="In Terminal ('api — docker compose up') for 25s; the same error dialog in Terminal appeared 3x, last just now; 2 typing bursts in the last 2min."),

    # dev-routine: ordinary programming that goes fine
    C("vscode_editing", CAL, "dev-routine", QUIET, None, "settled", app="Visual Studio Code",
      title="moments.py — wade", excerpt="def tick(self, now: float) -> list[CheckRequest]:\n    \"\"\"Time-based moments: settled, selection, audit.\"\"\"\n    out = []\n    if self._budget_ok(now):",
      digest="In Visual Studio Code ('moments.py — wade') for 4min; 6 typing bursts in the last 2min."),
    C("tests_passing", CAL, "dev-routine", QUIET, None, "settled", app="Terminal",
      title="backend — pytest", excerpt="57 passed in 0.91s",
      digest="In Terminal ('backend — pytest') for 18s; switched Terminal↔Visual Studio Code 3x in the last 3min; 3 typing bursts in the last 2min."),
    C("reading_swift_docs", CAL, "dev-routine", QUIET, None, "settled", app="Safari",
      title="NSPopover | Apple Developer Documentation", url="https://developer.apple.com/documentation/appkit/nspopover",
      excerpt="NSPopover. A means to display additional content related to existing content on the screen. Overview: The popover is positioned relative to a view on screen, and its behavior determines when it closes.",
      digest="In Safari ('NSPopover | Apple Developer Documentation', developer.apple.com) for 1min; switched Safari↔Xcode 3x in the last 3min."),
    C("xcode_writing_code", CAL, "dev-routine", QUIET, None, "settled", app="Xcode",
      title="StatusItemController.swift", excerpt="private func scheduleAutoClose() {\n    autoCloseTask = Task { [weak self] in\n        try? await Task.sleep(for: Self.autoCloseAfter)",
      digest="In Xcode ('StatusItemController.swift') for 6min; 8 typing bursts in the last 2min."),
    C("git_log_browsing", CAL, "dev-routine", QUIET, None, "settled", app="Terminal",
      title="wade — git log", excerpt="d3c4672 Phase 6: seen only on user interaction\na26c043 Phase 6: menu-bar popover\nda20c0e Phase 5 done (real-trigger item open)",
      digest="In Terminal ('wade — git log') for 20s; 1 typing bursts in the last 2min."),
    C("one_off_warning", CAL, "dev-routine", QUIET, None, "stuck", app="Xcode",
      title="Wade", error="Warning: variable 'x' was never used",
      excerpt="warning: initialization of variable 'x' was never used; consider replacing with assignment to '_'",
      digest="In Xcode ('Wade') for 3min; an error dialog appeared in Xcode 40s ago; 5 typing bursts in the last 2min.",
      note="single warning, work continues"),

    # github-cal: repository pages
    C("repo_clone_panel", CAL, "github", FIRE, "coding", "settled", app="Google Chrome",
      title="dejesusbg/monet: A lightweight JavaScript library", url="https://github.com/dejesusbg/monet",
      excerpt="Code · Local · Codespaces · Clone · HTTPS · SSH · GitHub CLI · https://github.com/dejesusbg/monet.git · Clone using the web URL. · Download ZIP",
      digest="In Google Chrome ('dejesusbg/monet: A lightweight JavaScript library…', github.com) for 16s."),
    C("repo_release_page", CAL, "github", FIRE, "coding", "settled", app="Google Chrome",
      title="Release v0.32.2 · ml-explore/mlx", url="https://github.com/ml-explore/mlx/releases/tag/v0.32.2",
      excerpt="v0.32.2 Latest · What's Changed · Preserve subnormal float values when casting to bool · Assets 4 · Source code (zip) · Source code (tar.gz)",
      digest="In Google Chrome ('Release v0.32.2 · ml-explore/mlx', github.com) for 20s."),
    C("repo_readme_only", CAL, "github", EITHER, None, "settled", app="Google Chrome",
      title="meodai/color-names: Large list of handpicked color names", url="https://github.com/meodai/color-names",
      excerpt="Color Names. Large list of handpicked color names. Features: 30,000+ names, API, JSON, CSV. Usage: fetch the list from the API or install the npm package.",
      digest="In Google Chrome ('meodai/color-names: Large list of handpicked color names…', github.com) for 18s.",
      note="a README without the Clone panel: maybe clone, maybe just reading"),
    C("github_issue_reading", CAL, "github", QUIET, None, "settled", app="Google Chrome",
      title="Popover closes too early · Issue #212 · someone/app", url="https://github.com/someone/app/issues/212",
      excerpt="Popover closes too early #212. Open. When the app is inactive the popover disappears after a click elsewhere. 4 comments. Labels: bug.",
      digest="In Google Chrome ('Popover closes too early · Issue #212 · someone/app', github.com) for 45s."),
    C("pr_review_in_progress", CAL, "github", QUIET, None, "settled", app="Google Chrome",
      title="Add retry to uploader by teammate · Pull Request #88", url="https://github.com/team/uploader/pull/88/files",
      excerpt="Files changed 3 · uploader.py · + for attempt in range(3): · + time.sleep(2 ** attempt) · Add a comment · Review changes",
      digest="In Google Chrome ('Add retry to uploader · Pull Request #88', github.com) for 3min; 3 typing bursts in the last 2min."),

    # writing-cal: text selected in documents
    C("pages_paragraph_selected", CAL, "writing-docs", FIRE, "writing", "selection", app="Pages",
      title="Thesis draft — Chapter 2", selection="Proactive assistants that interrupt on shallow heuristics erode user trust quickly; after a few wrong interruptions users disable them entirely, as the Clippy case showed.",
      digest="In Pages ('Thesis draft — Chapter 2') for 5min; 4 typing bursts in the last 2min."),
    C("pdf_quote_selected", CAL, "writing-docs", FIRE, "writing", "selection", app="Preview",
      title="gurnee2026_workspace.pdf", url="file:///Users/me/Papers/gurnee2026_workspace.pdf",
      selection="Verbalizable representations form a small, capacity-limited subset of the residual stream that behaves like a global workspace.",
      digest="In Preview ('gurnee2026_workspace.pdf', gurnee2026_workspace.pdf) for 3min; switched Preview↔Pages 4x in the last 3min."),
    C("word_typing_essay", CAL, "writing-docs", QUIET, None, "settled", app="Microsoft Word",
      title="Essay — Ethics of AI.docx", excerpt="In this essay I argue that transparency is necessary but not sufficient for trust. First, consider the case of recommender systems, where users",
      digest="In Microsoft Word ('Essay — Ethics of AI.docx') for 7min; 9 typing bursts in the last 2min."),
    C("pages_rereading", CAL, "writing-docs", QUIET, None, "settled", app="Pages",
      title="Thesis draft — Chapter 1", excerpt="Chapter 1. Introduction. Assistants today are reactive: the user must ask. This thesis explores when an assistant should speak first.",
      digest="In Pages ('Thesis draft — Chapter 1') for 2min; was idle 45s until 20s ago."),

    # explain-cal: dense text selected
    C("regex_selected", CAL, "explain", FIRE, "explaining", "selection", app="Visual Studio Code",
      title="validate.ts — web", selection="^(?=.*[A-Z])(?=.*\\d)(?=.*[^\\w\\s]).{12,}$",
      digest="In Visual Studio Code ('validate.ts — web') for 2min; was idle 40s until 5s ago."),
    C("legal_clause_selected", CAL, "explain", FIRE, "explaining", "selection", app="Safari",
      title="Terms of Service", url="https://example-cloud.com/terms",
      selection="Licensee shall indemnify and hold harmless Licensor from any claims arising out of Licensee's use of the Service, notwithstanding any limitation of liability herein.",
      digest="In Safari ('Terms of Service', example-cloud.com) for 2min; was idle 50s until 10s ago."),

    # research-cal: papers and scholarly pages
    C("arxiv_abstract", CAL, "research", FIRE, "researching", "settled", app="Safari",
      title="[2607.01234] Verbalizable Representations Form a Global Workspace", url="https://arxiv.org/abs/2607.01234",
      excerpt="Abstract: We introduce the Jacobian lens, a per-layer linear map that identifies which internal representations a model is poised to verbalize. Cite as: arXiv:2607.01234 · Download PDF",
      digest="In Safari ('[2607.01234] Verbalizable Representations Form a Global Workspace', arxiv.org) for 40s."),
    C("scholar_results", CAL, "research", FIRE, "researching", "settled", app="Google Chrome",
      title="proactive assistant interruption - Google Scholar", url="https://scholar.google.com/scholar?q=proactive+assistant+interruption",
      excerpt="Attention-sensitive alerting · E Horvitz · Cited by 612 · Save · Cite · Principles of mixed-initiative user interfaces · Cited by 3120 · Save · Cite",
      digest="In Google Chrome ('proactive assistant interruption - Google Scholar', scholar.google.com) for 50s; switched Google Chrome↔Pages 3x in the last 3min."),
    C("news_reading", CAL, "research", QUIET, None, "settled", app="Safari",
      title="Storm season forecast for the Caribbean", url="https://news.example.com/weather/caribbean-storms",
      excerpt="Forecasters expect an above-average storm season for the Caribbean this year, with warmer sea temperatures and weaker wind shear.",
      digest="In Safari ('Storm season forecast for the Caribbean', news.example.com) for 1min."),
    C("wiki_reading_topic", CAL, "research", QUIET, None, "settled", app="Safari",
      title="Global workspace theory - Wikipedia", url="https://en.wikipedia.org/wiki/Global_workspace_theory",
      excerpt="Global workspace theory (GWT) is a framework for thinking about consciousness proposed by Bernard Baars. It suggests that there is a global workspace in the brain.",
      digest="In Safari ('Global workspace theory - Wikipedia', en.wikipedia.org) for 2min."),

    # shopping-cal: comparisons and purchases
    C("flight_results", CAL, "shopping", FIRE, "comparing", "settled", app="Google Chrome",
      title="Flights from BAQ to MDE", url="https://www.google.com/travel/flights",
      excerpt="Barranquilla → Medellín · Fri, Oct 10 · Best · Cheapest · Avianca 7:05 AM $312,000 · LATAM 9:40 AM $289,000 · Wingo 1:15 PM $198,000 · Dates: prices are lower on Oct 12",
      digest="In Google Chrome ('Flights from BAQ to MDE', google.com) for 1min; 2 typing bursts in the last 2min."),
    C("laptops_side_by_side", CAL, "shopping", FIRE, "comparing", "settled", app="Safari",
      title="Compare MacBook models", url="https://www.apple.com/mac/compare/",
      excerpt="MacBook Air 13-inch M5 · 16GB · 256GB · from $1,099 · MacBook Pro 14-inch M5 · 16GB · 512GB · from $1,599 · Battery up to 18 hours · up to 24 hours",
      digest="In Safari ('Compare MacBook models', apple.com) for 1min."),
    C("checkout_page", CAL, "shopping", QUIET, None, "settled", app="Safari",
      title="Checkout — Bag", url="https://store.example.com/checkout",
      excerpt="Shipping address · Payment · Order summary: 1 item · Subtotal $1,099 · Place order",
      digest="In Safari ('Checkout — Bag', store.example.com) for 30s; 3 typing bursts in the last 2min.",
      note="already decided and paying"),
    C("single_product_page", CAL, "shopping", EITHER, None, "settled", app="Safari",
      title="Wireless Earbuds Pro 2", url="https://store.example.com/earbuds-pro-2",
      excerpt="Wireless Earbuds Pro 2 · $249 · Active noise cancellation · 6h battery · Add to Bag",
      digest="In Safari ('Wireless Earbuds Pro 2', store.example.com) for 40s."),

    # share-cal
    C("trip_plan_for_friend", CAL, "share", FIRE, "sharing", "settled", app="Google Chrome",
      title="Trip plan for Ana - Google Docs", url="https://docs.google.com/document/d/abc/edit",
      excerpt="Trip plan for Ana. Day 1: arrive Santa Marta, check in 3pm. Day 2: Tayrona park, leave 7am. Day 3: Minca. Share",
      digest="In Google Chrome ('Trip plan for Ana - Google Docs', docs.google.com) for 3min; switched Google Chrome↔Messages 3x in the last 3min."),

    # routine-cal: everyday non-work
    C("slack_chatting", CAL, "routine", QUIET, None, "settled", app="Slack",
      title="#general - Team", excerpt="Maria: lunch at 1? · Juan: sure · Maria: the usual place",
      digest="In Slack ('#general - Team') for 40s; 3 typing bursts in the last 2min."),
    C("mail_reading", CAL, "routine", QUIET, None, "settled", app="Mail",
      title="Inbox — 3 unread", excerpt="Your library books are due Friday · Weekly newsletter: what's new in design · Receipt for your order",
      digest="In Mail ('Inbox — 3 unread') for 1min."),
    C("music_app", CAL, "routine", QUIET, None, "settled", app="Spotify",
      title="Spotify Premium", excerpt="Now playing · Playlist: Focus · Track 4 of 32",
      digest="In Spotify ('Spotify Premium') for 20s."),
    C("youtube_watching", CAL, "routine", QUIET, None, "settled", app="Google Chrome",
      title="How transformers work - YouTube", url="https://www.youtube.com/watch?v=abc",
      excerpt="How transformers work · 1.2M views · Subscribe · Up next",
      digest="In Google Chrome ('How transformers work - YouTube', youtube.com) for 6min; currently idle."),
    C("calendar_glance", CAL, "routine", QUIET, None, "settled", app="Calendar",
      title="Calendar", excerpt="Thursday · 10:00 Class: Software Engineering · 14:00 Meeting with advisor",
      digest="In Calendar ('Calendar') for 16s."),
    C("finder_browsing", CAL, "routine", QUIET, None, "settled", app="Finder",
      title="Downloads", excerpt="Downloads · 42 items · Wade.pdf · invoice.pdf · IMG_2031.jpg",
      digest="In Finder ('Downloads') for 20s; 4 app switches across 3 apps recently."),
    C("settings_wifi", CAL, "routine", QUIET, None, "settled", app="System Settings",
      title="Wi-Fi", excerpt="Wi-Fi · On · Home-5G · Connected · Known networks",
      digest="In System Settings ('Wi-Fi') for 15s."),
    C("notes_list", CAL, "routine", QUIET, None, "settled", app="Notes",
      title="Groceries", excerpt="Groceries: eggs, rice, plantain, coffee, lime",
      digest="In Notes ('Groceries') for 30s; 2 typing bursts in the last 2min."),
    C("audit_while_typing", CAL, "routine", QUIET, None, "audit", app="Pages",
      title="Thesis draft — Chapter 3", excerpt="Chapter 3. Method. We recorded participants' sessions and",
      digest="In Pages ('Thesis draft — Chapter 3') for 9min; 7 typing bursts in the last 2min."),

    # ─────────────────────────── held-out ───────────────────────────
    # other-stuck: errors outside developer tools
    C("excel_ref_error", TEST, "other-stuck", FIRE, "fixing", "stuck", app="Microsoft Excel",
      title="Budget 2026.xlsx", error="There's a problem with this formula.",
      excerpt="=VLOOKUP(B2,Rates!A:C,4,FALSE) · #REF! · #REF! · #REF!",
      digest="In Microsoft Excel ('Budget 2026.xlsx') for 2min; the same error dialog in Microsoft Excel appeared 3x, last just now; 4 undos in the last 2min."),
    C("printer_offline", TEST, "other-stuck", FIRE, "fixing", "stuck", app="Preview",
      title="Boarding pass.pdf", error="The printer \"HP LaserJet\" is not connected.",
      excerpt="Print · HP LaserJet · Printer Offline · Resume",
      digest="In Preview ('Boarding pass.pdf') for 1min; switched Preview↔System Settings 4x in the last 3min; the same error dialog in Preview appeared 3x, last 5s ago."),
    C("vpn_fails", TEST, "other-stuck", FIRE, "fixing", "stuck", app="GlobalProtect",
      title="GlobalProtect", error="Connection failed: gateway unreachable",
      excerpt="Status: Not connected · Connection failed: gateway unreachable · Retry",
      digest="In GlobalProtect ('GlobalProtect') for 30s; the same error dialog in GlobalProtect appeared 4x, last just now; switched GlobalProtect↔Safari 3x in the last 3min."),
    C("zoom_mic_denied", TEST, "other-stuck", FIRE, "fixing", "stuck", app="zoom.us",
      title="Zoom Meeting", error="Zoom can't access your microphone.",
      excerpt="Zoom can't access your microphone. Allow access in System Settings > Privacy & Security > Microphone.",
      digest="In zoom.us ('Zoom Meeting') for 45s; switched zoom.us↔System Settings 3x in the last 3min; the same error dialog in zoom.us appeared 2x, last 10s ago."),
    C("figma_export_fails", TEST, "other-stuck", FIRE, "fixing", "stuck", app="Figma",
      title="Logo — Figma", error="Export failed: the selection is too large to export.",
      excerpt="Export · PNG · 4x · Export failed: the selection is too large to export.",
      digest="In Figma ('Logo — Figma') for 1min; the same error dialog in Figma appeared 3x, last just now; 3 undos in the last 2min."),
    C("git_merge_conflict", TEST, "other-stuck", FIRE, "fixing", "stuck", app="iTerm2",
      title="site — git merge", error="CONFLICT (content): Merge conflict in index.html",
      excerpt="Auto-merging index.html\nCONFLICT (content): Merge conflict in index.html\nAutomatic merge failed; fix conflicts and then commit the result.",
      digest="In iTerm2 ('site — git merge') for 40s; the same error dialog in iTerm2 appeared 2x, last 15s ago; switched iTerm2↔Sublime Text 5x in the last 3min."),
    C("canvas_upload_fails", TEST, "other-stuck", FIRE, "fixing", "stuck", app="Safari",
      title="Assignment 3 - Submit", url="https://campus.example.edu/courses/12/assignments/3",
      error="Upload failed. The file exceeds the maximum size of 50 MB.",
      excerpt="Submit Assignment · File Upload · report_final.pdf · Upload failed. The file exceeds the maximum size of 50 MB.",
      digest="In Safari ('Assignment 3 - Submit', campus.example.edu) for 1min; the same error dialog in Safari appeared 3x, last just now; switched Safari↔Finder 4x in the last 3min."),

    # other-opportunity: the same kinds of offers, on unseen sites and apps
    C("gitlab_clone", TEST, "other-opportunity", FIRE, "coding", "settled", app="Firefox",
      title="group / parser · GitLab", url="https://gitlab.com/group/parser",
      excerpt="parser · Clone · Clone with SSH git@gitlab.com:group/parser.git · Clone with HTTPS https://gitlab.com/group/parser.git · Open in your IDE",
      digest="In Firefox ('group / parser · GitLab', gitlab.com) for 18s."),
    C("npm_package_page", TEST, "other-opportunity", FIRE, "coding", "settled", app="Google Chrome",
      title="rampensau - npm", url="https://www.npmjs.com/package/rampensau",
      excerpt="rampensau · 2.3.0 · Public · Install: npm i rampensau · Weekly Downloads 12,431 · Repository github.com/meodai/rampensau",
      digest="In Google Chrome ('rampensau - npm', npmjs.com) for 20s."),
    C("hf_model_page", TEST, "other-opportunity", FIRE, "coding", "settled", app="Safari",
      title="mlx-community/Qwen3-4B-Instruct-2507-4bit · Hugging Face", url="https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit",
      excerpt="Use this model · Files and versions · pip install mlx-lm · from mlx_lm import load, generate · model, tokenizer = load(\"mlx-community/Qwen3-4B-Instruct-2507-4bit\")",
      digest="In Safari ('mlx-community/Qwen3-4B-Instruct-2507-4bit · Hugging Face', huggingface.co) for 25s; switched Safari↔Terminal 3x in the last 3min."),
    C("spanish_paragraph_selected", TEST, "other-opportunity", FIRE, "writing", "selection", app="Safari",
      title="La inteligencia artificial en la educación", url="https://revista.example.co/ia-educacion",
      selection="La inteligencia artificial puede personalizar el aprendizaje, pero también plantea riesgos de privacidad que las universidades aún no han resuelto.",
      digest="In Safari ('La inteligencia artificial en la educación', revista.example.co) for 2min; switched Safari↔Pages 3x in the last 3min."),
    C("kindle_quote_selected", TEST, "other-opportunity", FIRE, "writing", "selection", app="Kindle",
      title="Thinking, Fast and Slow", selection="Nothing in life is as important as you think it is, while you are thinking about it.",
      digest="In Kindle ('Thinking, Fast and Slow') for 4min; switched Kindle↔Pages 3x in the last 3min."),
    C("pubmed_article", TEST, "other-opportunity", FIRE, "researching", "settled", app="Google Chrome",
      title="Deep learning for skin lesion classification - PubMed", url="https://pubmed.ncbi.nlm.nih.gov/12345678/",
      excerpt="Deep learning for skin lesion classification: a systematic review. Abstract. Background: Convolutional networks... Cite · Collections · Full text links",
      digest="In Google Chrome ('Deep learning for skin lesion classification - PubMed', pubmed.ncbi.nlm.nih.gov) for 45s; switched Google Chrome↔Word 3x in the last 3min."),
    C("ssrn_paper", TEST, "other-opportunity", FIRE, "researching", "settled", app="Safari",
      title="Algorithmic Nudges and Consumer Welfare :: SSRN", url="https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4567890",
      excerpt="Algorithmic Nudges and Consumer Welfare. 42 Pages. Posted: 3 Mar 2026. Download This Paper · Open PDF in Browser · Add Paper to My Library",
      digest="In Safari ('Algorithmic Nudges and Consumer Welfare :: SSRN', papers.ssrn.com) for 35s."),
    C("hotel_results", TEST, "other-opportunity", FIRE, "comparing", "settled", app="Safari",
      title="Cartagena hotels — Oct 10–13", url="https://www.booking.com/searchresults.html",
      excerpt="Cartagena · 3 nights · Hotel Casa San Agustín $412 · Hotel Caribe $185 · Movich $160 · Sort by: lowest price · Free cancellation",
      digest="In Safari ('Cartagena hotels — Oct 10–13', booking.com) for 1min; 3 typing bursts in the last 2min."),
    C("two_phones_tabs", TEST, "other-opportunity", FIRE, "comparing", "settled", app="Google Chrome",
      title="Pixel 10 vs Galaxy S26 - specs", url="https://www.gsmarena.com/compare.php3",
      excerpt="Compare · Pixel 10 · Galaxy S26 · Display 6.3\" · 6.2\" · Battery 4700 mAh · 4000 mAh · Price about $799 · about $849",
      digest="In Google Chrome ('Pixel 10 vs Galaxy S26 - specs', gsmarena.com) for 1min."),
    C("medical_jargon_selected", TEST, "other-opportunity", FIRE, "explaining", "selection", app="Preview",
      title="discharge_summary.pdf", selection="Patient presents with paroxysmal supraventricular tachycardia, managed with vagal maneuvers and adenosine.",
      digest="In Preview ('discharge_summary.pdf', discharge_summary.pdf) for 2min; was idle 1min until 5s ago."),
    C("tax_form_selected", TEST, "other-opportunity", FIRE, "explaining", "selection", app="Safari",
      title="Declaración de renta — DIAN", url="https://www.dian.gov.co/renta",
      selection="Las rentas exentas no podrán exceder el 40% del ingreso bruto menos los ingresos no constitutivos de renta.",
      digest="In Safari ('Declaración de renta — DIAN', dian.gov.co) for 3min; was idle 1min until 10s ago."),
    C("event_page_share", TEST, "other-opportunity", FIRE, "sharing", "settled", app="Safari",
      title="Carnaval de Barranquilla 2027 — Tickets", url="https://tickets.example.co/carnaval-2027",
      excerpt="Carnaval de Barranquilla 2027 · Batalla de Flores · Feb 13 · Palco tickets from $180,000 · Share this event",
      digest="In Safari ('Carnaval de Barranquilla 2027 — Tickets', tickets.example.co) for 40s; switched Safari↔WhatsApp 3x in the last 3min."),

    # live: the kinds of pages from the first live run, rewritten generically
    C("search_results_song", TEST, "live", QUIET, None, "settled", app="Google Chrome",
      title="song meaning about grief - Google Search", url="https://www.google.com/search?q=song+meaning+grief",
      excerpt="About 1,240,000 results · What is the song about? · The lyrics describe missing someone after a loss · People also ask · Videos",
      digest="In Google Chrome ('song meaning about grief - Google Search', google.com) for 15s; 1 typing bursts in the last 2min."),
    C("forum_thread", TEST, "live", QUIET, None, "settled", app="Google Chrome",
      title="What does this song mean to YOU? : r/music", url="https://www.reddit.com/r/music/comments/abc",
      excerpt="What does this song mean to YOU? · 214 comments · For me it's about my grandmother · Same, I cried the first time I heard it",
      digest="In Google Chrome ('What does this song mean to YOU? : r/music', reddit.com) for 16s; 1 typing bursts in the last 2min."),
    C("encyclopedia_bio", TEST, "live", QUIET, None, "settled", app="Google Chrome",
      title="Singer - Wikipedia", url="https://en.wikipedia.org/wiki/Singer_(musician)",
      excerpt="An American singer-songwriter. Her music has been described as indie rock and art pop. Early life: born in 1990, she moved often as a child.",
      digest="In Google Chrome ('Singer - Wikipedia', en.wikipedia.org) for 24s; switched Google Chrome↔Terminal 7x in the last 3min; 2 typing bursts in the last 2min."),
    C("github_dashboard", TEST, "live", QUIET, None, "settled", app="Google Chrome",
      title="GitHub Dashboard", url="https://github.com/",
      excerpt="Home · Top repositories · Recent activity · Explore repositories · Following · For you",
      digest="In Google Chrome ('GitHub Dashboard', github.com) for 15s; switched Google Chrome↔Terminal 9x in the last 3min."),
    C("terminal_chat_session", TEST, "live", QUIET, None, "settled", app="Terminal",
      title="wade — claude", excerpt="The backend is up, Stage 2 is loaded, and Wade is connected to it. Your turn: open a web page",
      digest="In Terminal ('wade — claude') for 15s; switched Terminal↔Google Chrome 10x in the last 3min; 2 typing bursts in the last 2min."),
    C("search_snippet_selected", TEST, "live", EITHER, None, "selection", app="Google Chrome",
      title="song meaning about grief - Google Search", url="https://www.google.com/search?q=song+meaning+grief",
      selection="The lyrics describe missing someone after a loss and wishing for one more chance to see them.",
      digest="In Google Chrome ('song meaning about grief - Google Search', google.com) for 6s; 4 app switches across 3 apps recently; 1 typing bursts in the last 2min.",
      note="selected while reading; could be to copy, to save, or nothing"),
    C("bio_paragraph_selected", TEST, "live", EITHER, None, "selection", app="Google Chrome",
      title="Singer - Wikipedia", url="https://en.wikipedia.org/wiki/Singer_(musician)",
      selection="Her music has been described as indie rock and art pop, and her lyrics often explore identity and belonging.",
      digest="In Google Chrome ('Singer - Wikipedia', en.wikipedia.org) for 4s; switched Google Chrome↔Terminal 7x in the last 3min; 2 typing bursts in the last 2min."),
    C("repo_readme_live", TEST, "live", EITHER, None, "settled", app="Google Chrome",
      title="meodai/rampensau: Color palette generation function", url="https://github.com/meodai/rampensau",
      excerpt="RampenSau. Color palette generation function using hue cycling and easing. Install: npm install rampensau. Usage: import { generateHSL } from 'rampensau'",
      digest="In Google Chrome ('meodai/rampensau: Color palette generation function…', github.com) for 35s; switched Google Chrome↔Terminal 8x in the last 3min; 2 typing bursts in the last 2min."),

    # other-routine: everyday use in apps the calibration half never shows
    C("email_reply_typing", TEST, "other-routine", QUIET, None, "settled", app="Microsoft Outlook",
      title="RE: Project meeting", excerpt="Hi Laura, Thursday works for me. I'll bring the draft and the survey results. Best,",
      digest="In Microsoft Outlook ('RE: Project meeting') for 2min; 5 typing bursts in the last 2min."),
    C("notion_editing", TEST, "other-routine", QUIET, None, "settled", app="Notion",
      title="Sprint board", excerpt="To do · In progress · Done · Write onboarding copy · Fix icon states · Review PR",
      digest="In Notion ('Sprint board') for 3min; 4 typing bursts in the last 2min."),
    C("figma_designing", TEST, "other-routine", QUIET, None, "settled", app="Figma",
      title="Wade UI — Figma", excerpt="Frame 12 · Popover · Auto layout · Fill #FFFFFF · Corner radius 12",
      digest="In Figma ('Wade UI — Figma') for 8min; 3 undos in the last 2min.",
      note="undos while designing are ordinary"),
    C("excel_data_entry", TEST, "other-routine", QUIET, None, "settled", app="Microsoft Excel",
      title="Grades.xlsx", excerpt="Student · Exam 1 · Exam 2 · Project · 4.2 · 3.8 · 4.5",
      digest="In Microsoft Excel ('Grades.xlsx') for 6min; 8 typing bursts in the last 2min."),
    C("whatsapp_chat", TEST, "other-routine", QUIET, None, "settled", app="WhatsApp",
      title="Mamá", excerpt="Mamá: ¿vienes el domingo? · Yo: sí, llego al mediodía",
      digest="In WhatsApp ('Mamá') for 30s; 2 typing bursts in the last 2min."),
    C("netflix_watching", TEST, "other-routine", QUIET, None, "settled", app="Safari",
      title="Netflix", url="https://www.netflix.com/watch/123",
      excerpt="Episode 4 · Skip Intro · Next Episode",
      digest="In Safari ('Netflix', netflix.com) for 20min; currently idle."),
    C("duolingo_lesson", TEST, "other-routine", QUIET, None, "settled", app="Safari",
      title="Duolingo", url="https://www.duolingo.com/lesson",
      excerpt="Translate this sentence · Je voudrais un café · Check",
      digest="In Safari ('Duolingo', duolingo.com) for 4min; 6 typing bursts in the last 2min.",
      note="an exercise: helping would spoil it"),
    C("instagram_scroll", TEST, "other-routine", QUIET, None, "settled", app="Google Chrome",
      title="Instagram", url="https://www.instagram.com/",
      excerpt="Home · Reels · liked by friend and 1,203 others · View all 45 comments",
      digest="In Google Chrome ('Instagram', instagram.com) for 3min."),
    C("maps_directions", TEST, "other-routine", QUIET, None, "settled", app="Maps",
      title="Directions to Universidad del Magdalena", excerpt="22 min · 9.4 km · via Troncal del Caribe · Start",
      digest="In Maps ('Directions to Universidad del Magdalena') for 20s."),
    C("audit_reading_book", TEST, "other-routine", QUIET, None, "audit", app="Kindle",
      title="Thinking, Fast and Slow", excerpt="Chapter 7. A Machine for Jumping to Conclusions.",
      digest="In Kindle ('Thinking, Fast and Slow') for 12min; currently idle."),
    C("zoom_in_meeting", TEST, "other-routine", QUIET, None, "settled", app="zoom.us",
      title="Zoom Meeting", excerpt="Mute · Stop Video · Participants 6 · Share Screen · Recording",
      digest="In zoom.us ('Zoom Meeting') for 25min."),
    C("one_off_dialog_other", TEST, "other-routine", QUIET, None, "stuck", app="Microsoft Word",
      title="Essay.docx", error="Word found unreadable content in Essay.docx. Do you want to recover the contents?",
      excerpt="Word found unreadable content in Essay.docx. Do you want to recover the contents of this document? Yes · No",
      digest="In Microsoft Word ('Essay.docx') for 20s; an error dialog appeared in Microsoft Word just now.",
      note="one dialog with its own clear choice; EITHER-ish, labeled quiet because it self-resolves"),
]

BY_ID = {c.id: c for c in CASES}
assert len(BY_ID) == len(CASES), "duplicate case ids"


def split(name: str) -> list[Case]:
    return [c for c in CASES if c.split == name]
