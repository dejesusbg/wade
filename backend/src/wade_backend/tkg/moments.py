"""Stage 1 as a moment detector (CLAUDE.md §5.3).

Wade speaks at *moments worth speaking*: when you're stuck, and also at opportunities (a repo
page you could clone, a paragraph you could cite, a flight search, a comparison). Stage 1
can't tell which moments are worth it, and it never interrupts. It only picks which moments
get a Stage 2 look, within a compute budget:

  stuck      the rule-based stuck scorer (gate.py) crossed its threshold
  selection  the user selected text and held it
  settled    the user settled on a context (snapshot received, dwell ≥ settle_s) not checked recently
  audit      periodic, when nothing else was checked for a while. `surface=False`: Stage 2's
             answer is only logged, to measure what the other kinds miss.

Budget: at most one check per `min_interval_s` and `max_per_hour` per rolling hour. `stuck`
bypasses both: it's rare, it has its own cooldown, and it's the most valuable.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import digest
from .features import Features, extract
from .gate import Gate, GateConfig, GateDecision
from .graph import FocusEvent, TemporalGraph


@dataclass(frozen=True)
class MomentConfig:
    settle_s: float = 15.0
    context_ttl_s: float = 600.0
    selection_hold_s: float = 2.0
    selection_max_age_s: float = 60.0
    min_selection_chars: int = 15
    audit_every_s: float = 300.0
    min_interval_s: float = 20.0
    max_per_hour: int = 60


@dataclass(frozen=True)
class CheckRequest:
    """What Stage 2 (Phase 3) receives: the moment, plus its two inputs from §5.4."""
    kind: str  # stuck | selection | settled | audit
    ts: float
    reasons: tuple[str, ...]
    digest: str  # (b) situational history, plain facts
    context: dict[str, str] = field(default_factory=dict)  # (a) current screen/AX context
    surface: bool = True  # False: never shown to the user, whatever Stage 2 says
    score: float | None = None  # stuck score, when kind == "stuck"


SETTLE_RANGE = (5.0, 60.0)  # seconds; the app's Settings offers the same range

# Pages that are a way *to* something, not the thing itself: a browser's own pages and search
# results. Checking them produced junk (a note of the new-tab page's search suggestions) and
# offers while the user was still searching (live run, 2026-09-25).
_INTERNAL_SCHEMES = ("chrome:", "about:", "edge:", "brave:", "arc:", "vivaldi:", "opera:",
                     "safari-resource:", "favorites:", "chrome-search:", "devtools:")
_SEARCH_PAGES = (
    ("google.", "/search"), ("bing.com", "/search"), ("duckduckgo.com", "/"), ("search.yahoo.com", "/search"),
    ("ecosia.org", "/search"), ("search.brave.com", "/search"), ("yandex.", "/search"), ("baidu.com", "/s"),
    ("perplexity.ai", "/search"), ("startpage.com", "/sp/search"),
)


def is_transit_page(url: str | None) -> bool:
    """A browser-internal page or a search results page: never a settled or selection moment."""
    if not url:
        return False
    low = url.lower()
    if low.startswith(_INTERNAL_SCHEMES):
        return True
    from urllib.parse import urlparse

    parsed = urlparse(low)
    host = parsed.netloc.removeprefix("www.")
    for domain, path in _SEARCH_PAGES:
        if (host.startswith(domain) or host.endswith("." + domain) or host == domain.rstrip(".")) \
                and parsed.path.startswith(path) and ("q=" in parsed.query or path != "/"):
            return True
    return False


def context_key(focus: FocusEvent) -> str:
    return f"{focus.app_bundle_id}|{focus.url or focus.window_title}"


class MomentDetector:
    def __init__(self, cfg: MomentConfig = MomentConfig(), gate_cfg: GateConfig = GateConfig()) -> None:
        self.cfg = cfg
        self.gate = Gate(gate_cfg)
        self.check_times: list[float] = []
        self.checked_contexts: dict[str, float] = {}
        self.checked_selection_ts: float | None = None
        self.audit_clock: float | None = None

    # Called after every event: the stuck scorer depends on what just happened.
    def on_event(self, g: TemporalGraph) -> tuple[GateDecision, CheckRequest | None]:
        f = extract(g)
        decision = self.gate.evaluate(f)
        if not decision.fired:
            return decision, None
        return decision, self._check(g, f, "stuck", decision.reasons, score=decision.score)

    # Called every second: dwell, held selections and audits depend on time passing.
    def on_tick(self, g: TemporalGraph) -> CheckRequest | None:
        now = g.now
        if self.audit_clock is None:
            self.audit_clock = now
        self.checked_contexts = {k: t for k, t in self.checked_contexts.items() if now - t < self.cfg.context_ttl_s}
        if self._over_budget(now):
            return None
        f = extract(g)

        focus = g.current_focus()
        transit = bool(focus) and is_transit_page(focus.url)

        selections = g.actions("selection")
        if selections and not transit:
            sel = selections[-1]
            age = now - sel.ts
            text = str(sel.metadata.get("text", ""))
            if (sel.ts != self.checked_selection_ts and len(text.strip()) >= self.cfg.min_selection_chars
                    and self.cfg.selection_hold_s <= age <= self.cfg.selection_max_age_s):
                self.checked_selection_ts = sel.ts
                return self._check(g, f, "selection", ("text_selected",))

        if focus and not transit and focus.snapshotted and now - focus.ts_start >= self.cfg.settle_s:
            key = context_key(focus)
            if key not in self.checked_contexts:
                self.checked_contexts[key] = now
                return self._check(g, f, "settled", ("context_settled",))

        quiet_since = max([self.audit_clock, *self.check_times[-1:]])
        active = any(now - n.ts <= self.cfg.audit_every_s for n in g.nodes)
        if now - quiet_since >= self.cfg.audit_every_s and active and not f.is_idle:
            self.audit_clock = now
            return self._check(g, f, "audit", ("periodic_audit",), surface=False)
        return None

    def set_settle(self, seconds: float) -> float:
        """The app's "settled after" setting, clamped to SETTLE_RANGE. Returns what applies."""
        from dataclasses import replace

        value = min(max(float(seconds), SETTLE_RANGE[0]), SETTLE_RANGE[1])
        self.cfg = replace(self.cfg, settle_s=value)
        return value

    def _over_budget(self, now: float) -> bool:
        self.check_times = [t for t in self.check_times if now - t < 3600]
        if self.check_times and now - self.check_times[-1] < self.cfg.min_interval_s:
            return True
        return len(self.check_times) >= self.cfg.max_per_hour

    def _check(self, g: TemporalGraph, f: Features, kind: str, reasons: tuple[str, ...],
               surface: bool = True, score: float | None = None) -> CheckRequest:
        self.check_times.append(g.now)
        return CheckRequest(kind, g.now, reasons, digest.render(g, f), build_context(g, kind), surface, score)


def build_context(g: TemporalGraph, kind: str = "settled") -> dict[str, str]:
    """Current screen context for Stage 2. Text stays local; it's never put in the digest.

    Selections and error text belong to the app in front. The exception is a *stuck* check:
    there the error is often in the app the user just left (reading Safari about an Xcode
    error), so the latest error from any app counts. Otherwise a probe's error dialog stayed
    attached to an unrelated shopping page (live run, 2026-09-25)."""
    ctx: dict[str, str] = {}
    focus = g.current_focus()
    if focus:
        ctx["app"] = g.app_name(focus.app_bundle_id)
        ctx["title"] = focus.window_title
        if focus.url:
            ctx["url"] = focus.url
        if focus.excerpt:
            ctx["excerpt"] = focus.excerpt
    here = focus.app_bundle_id if focus else None
    selections = [s for s in g.actions("selection") if g.now - s.ts <= 120 and s.app_context == here]
    if selections:
        ctx["selection"] = str(selections[-1].metadata.get("text", ""))
    errors = [e for e in g.errors() if g.now - e.ts <= 300 and e.text
              and (kind == "stuck" or e.app_bundle_id == here)]
    if errors:
        ctx["error_text"] = errors[-1].text
    return ctx
