"""Synthetic `tkg_event` sessions for testing Stage 1 (Phase 2) and, later, the eval harness
(Phase 7).

`Session` is a small builder that emits events shaped exactly like the Swift app's. `SCENARIOS`
is the constructed set: each scenario states which moment kinds it must produce and which it
must not. They are hand-written stories, not recorded behavior, so they check that the rules
do what they're designed to do. They don't show the rules are right about people.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

XCODE = ("com.apple.dt.Xcode", "Xcode")
SAFARI = ("com.apple.Safari", "Safari")
CHROME = ("com.google.Chrome", "Chrome")
TERMINAL = ("com.apple.Terminal", "Terminal")
SLACK = ("com.tinyspeck.slackmacgap", "Slack")
SETTINGS = ("com.apple.systempreferences", "System Settings")
MAIL = ("com.apple.mail", "Mail")
NOTES = ("com.apple.Notes", "Notes")
PAGES = ("com.apple.iWork.Pages", "Pages")
WORD = ("com.microsoft.Word", "Word")


class Session:
    def __init__(self, start: float = 1_800_000_000.0) -> None:
        self.t = start
        self.events: list[dict[str, Any]] = []
        self._app = ("", "")
        self._title = ""

    def _emit(self, event_type: str, metadata: dict[str, Any] | None = None, ts: float | None = None) -> None:
        self.events.append({
            "type": "tkg_event",
            "event_type": event_type,
            "timestamp": self.t if ts is None else ts,
            "app_bundle_id": self._app[0],
            "window_title": self._title,
            "metadata": metadata or {},
        })

    def wait(self, seconds: float) -> Session:
        self.t += seconds
        return self

    def focus(self, app: tuple[str, str], title: str = "") -> Session:
        self._app, self._title = app, title
        self._emit("focus_change", {"cause": "app_activated", "app_name": app[1]})
        return self

    def title(self, title: str) -> Session:
        self._title = title
        self._emit("focus_change", {"cause": "title_changed", "app_name": self._app[1]})
        return self

    def type(self, keys: int = 30, seconds: float = 10.0) -> Session:
        start = self.t
        self.t += seconds
        self._emit("keypress_burst", {"key_count": keys, "duration_s": seconds, "started_at": start})
        return self

    def undo(self, times: int = 1, every: float = 2.0) -> Session:
        for _ in range(times):
            self._emit("undo")
            self.t += every
        return self

    def error(self, signature: str, text: str = "") -> Session:
        self._emit("error_dialog", {"signature": signature, "role": "AXDialog", "text": text})
        return self

    def snapshot(self, url: str = "", excerpt: str = "") -> Session:
        """What the app sends after 4s of dwell on the current context."""
        self.wait(4)
        meta: dict[str, Any] = {"app_name": self._app[1]}
        if url:
            meta["url"] = url
        if excerpt:
            meta["excerpt"] = excerpt
        self._emit("content_snapshot", meta)
        return self

    def select(self, text: str) -> Session:
        self._emit("selection", {"text": text, "length": len(text)})
        return self

    def idle(self, seconds: float) -> Session:
        start = self.t
        self.t += seconds
        # Like the app: idle_start is stamped at the last input, idle_end at the first new input.
        self._emit("idle_start", ts=start)
        self._emit("idle_end", {"idle_seconds": round(seconds)})
        return self

    def pingpong(self, a: tuple[str, str], b: tuple[str, str], switches: int, every: float,
                 a_title: str = "", b_title: str = "") -> Session:
        for i in range(switches):
            self.wait(every)
            if i % 2 == 0:
                self.focus(b, b_title)
            else:
                self.focus(a, a_title)
        return self


@dataclass(frozen=True)
class Scenario:
    build: Callable[[], Session]
    expect: frozenset[str] = frozenset()  # moment kinds that must occur
    forbid: frozenset[str] = frozenset()  # moment kinds that must not occur


# ---- stuck -------------------------------------------------------------------------------


def build_loop() -> Session:
    """The brief's example: a build error recurring while flipping to the browser for answers."""
    s = Session().focus(XCODE, "Wade — ActivityObserver.swift").type(60, 20)
    for _ in range(3):
        s.wait(5).error("build-failed-7f3a")
        s.pingpong(XCODE, SAFARI, 2, 12, "Wade — ActivityObserver.swift", "AXObserver crash - Stack Overflow")
        s.type(15, 6)
    return s


def undo_storm_with_error() -> Session:
    """Editing, undoing, retrying, hitting the same export error twice."""
    s = Session().focus(PAGES, "Thesis draft").type(80, 30)
    s.wait(10).error("export-failed-11aa")
    s.undo(3).type(10, 5).undo(2)
    s.wait(20).error("export-failed-11aa")
    return s


def permission_hunt() -> Session:
    """Terminal ↔ System Settings, the same 'permission denied' error twice."""
    s = Session().focus(TERMINAL, "zsh").type(20, 5).error("permission-denied-0c1d")
    s.pingpong(TERMINAL, SETTINGS, 6, 10, "zsh", "Privacy & Security")
    s.type(12, 4).error("permission-denied-0c1d")
    return s


def stare_then_scramble() -> Session:
    """A long pause after an error, then the error again and a burst of switching."""
    s = Session().focus(XCODE, "Package.swift").error("resolve-failed-9e2b")
    s.idle(90)
    s.pingpong(XCODE, CHROME, 4, 8, "Package.swift", "SwiftPM dependency resolution failed")
    s.error("resolve-failed-9e2b")
    return s


# ---- routine: never stuck -------------------------------------------------------------------


def focused_coding() -> Session:
    """Ten minutes of steady editing, a couple of doc lookups, one undo."""
    s = Session().focus(XCODE, "Wade — Gate.swift")
    for i in range(20):
        s.type(40, 15).wait(15)
        if i in (6, 14):
            s.focus(SAFARI, "Swift docs").wait(20).focus(XCODE, "Wade — Gate.swift")
        if i == 10:
            s.undo()
    return s


def reading() -> Session:
    """Reading a long article: long pauses, occasional scrolling-as-idle-breaks."""
    s = Session().focus(SAFARI, "A long article")
    for _ in range(6):
        s.idle(70).wait(20)
    return s


def tab_hopping() -> Session:
    """Many tabs in one browser (title changes, same app), a quick Slack check."""
    s = Session().focus(CHROME, "Inbox")
    for i in range(15):
        s.wait(12).title(f"Tab {i}")
    s.focus(SLACK, "#general").type(20, 6).focus(CHROME, "Tab 14")
    return s


def copy_between_apps() -> Session:
    """Copying figures from a spreadsheet into a doc: regular, spaced-out ping-pong."""
    s = Session().focus(NOTES, "Meeting notes")
    for _ in range(4):
        s.wait(60).focus(SAFARI, "Dashboard").wait(40).focus(NOTES, "Meeting notes").type(25, 8)
    return s


def fast_copy_paste() -> Session:
    """Copying text piece by piece from a browser into a design tool: a switch every few seconds
    for two minutes. Shape taken from a real on-device session (Chrome ↔ Figma, 1–5s apart)."""
    s = Session().focus(CHROME, "notebook.ipynb").type(10, 3)
    s.pingpong(CHROME, ("com.figma.Desktop", "Figma"), 30, 3.5, "notebook.ipynb", "Portfolio")
    return s.type(20, 6)


def one_off_error() -> Session:
    """A single error dialog, dismissed, then back to normal work."""
    s = Session().focus(MAIL, "Inbox").type(30, 10).error("send-failed-2b7c")
    s.wait(10).type(20, 6).wait(60).type(40, 15)
    return s


def typo_fixes() -> Session:
    """Two undos while writing: ordinary."""
    s = Session().focus(PAGES, "Essay").type(100, 40).undo(2).type(80, 30)
    return s


def morning_startup() -> Session:
    """Opening a handful of apps once each: many distinct apps, no repetition."""
    s = Session()
    for app in (MAIL, SLACK, CHROME, NOTES, XCODE, TERMINAL):
        s.focus(app, "").wait(15)
    s.type(30, 10)
    return s


def errors_far_apart() -> Session:
    """The same error twice, eight minutes apart, with normal work between (decay)."""
    s = Session().focus(XCODE, "App.swift").error("build-failed-7f3a")
    for _ in range(16):
        s.type(30, 10).wait(20)
    s.error("build-failed-7f3a")
    return s




# ---- opportunities (from the UX demo) ------------------------------------------------------


def repo_page() -> Session:
    """'When you need to code fast': on a GitHub repo page with the Clone panel open."""
    s = Session().focus(CHROME, "dejesusbg/monet: A lightweight JavaScript library - Google Chrome")
    s.snapshot("https://github.com/dejesusbg/monet",
               "Code Local Codespaces Clone HTTPS SSH GitHub CLI https://github.com/dejesusbg/monet.git "
               "Clone using the web URL. Open with GitHub Desktop Download ZIP")
    return s.wait(20)


def cite_selection() -> Session:
    """'When you need to write fast': a paragraph selected in a document."""
    s = Session().focus(WORD, "Tesis — capítulo 2").type(120, 60)
    s.select("En cuanto a la accesibilidad, diversos estudios evidencian que, pese a la aplicación de "
             "mejoras visuales, persisten problemas como ausencia de textos alternativos.")
    return s.wait(6)


def reading_paper() -> Session:
    """'When you need to research fast': reading a paper's background section."""
    s = Session().focus(SAFARI, "Frontiers | AI and digital accessibility")
    s.snapshot("https://www.frontiersin.org/articles/10.3389/frai.2024.00001/full",
               "2 Background As artificial intelligence continues to permeate various aspects of our "
               "lives, it is important to investigate its impact on the digital accessibility of people.")
    return s.wait(30)


def flight_search() -> Session:
    """'When you need to analyze fast': a flight search in progress."""
    s = Session().focus(CHROME, "Google Flights - Find Cheap Flight Options")
    s.type(25, 8).snapshot("https://www.google.com/travel/flights", "Round trip 1 Economy Bogotá Los Angeles Search")
    return s.wait(20)


def compare_products() -> Session:
    """'When you need to compare fast': comparing laptops on a store page."""
    s = Session().focus(SAFARI, "Mac - Compare Models - Apple")
    s.snapshot("https://www.apple.com/mac/compare/", "MacBook Air MacBook Pro Compare Mac models")
    return s.wait(25)


# ---- non-moments ---------------------------------------------------------------------------


def quick_glances() -> Session:
    """Checking several pages briefly: no dwell, so no settled check."""
    s = Session()
    for i in range(6):
        s.focus(CHROME, f"Page {i}").snapshot(f"https://example.com/{i}", "Some content").wait(6)
    return s


def short_selection() -> Session:
    """Selecting a single word to replace it is editing, not a moment."""
    return Session().focus(PAGES, "Essay").type(40, 15).select("word").wait(10)


SCENARIOS: dict[str, Scenario] = {
    # stuck
    "build_loop": Scenario(build_loop, expect=frozenset({"stuck"})),
    "undo_storm_with_error": Scenario(undo_storm_with_error, expect=frozenset({"stuck"})),
    "permission_hunt": Scenario(permission_hunt, expect=frozenset({"stuck"})),
    "stare_then_scramble": Scenario(stare_then_scramble, expect=frozenset({"stuck"})),
    # routine
    "focused_coding": Scenario(focused_coding, forbid=frozenset({"stuck"})),
    "reading": Scenario(reading, forbid=frozenset({"stuck"})),
    "tab_hopping": Scenario(tab_hopping, forbid=frozenset({"stuck"})),
    "copy_between_apps": Scenario(copy_between_apps, forbid=frozenset({"stuck"})),
    "fast_copy_paste": Scenario(fast_copy_paste, forbid=frozenset({"stuck"})),
    "one_off_error": Scenario(one_off_error, forbid=frozenset({"stuck"})),
    "typo_fixes": Scenario(typo_fixes, forbid=frozenset({"stuck"})),
    "morning_startup": Scenario(morning_startup, forbid=frozenset({"stuck"})),
    "errors_far_apart": Scenario(errors_far_apart, forbid=frozenset({"stuck"})),
    # opportunities
    "repo_page": Scenario(repo_page, expect=frozenset({"settled"}), forbid=frozenset({"stuck"})),
    "cite_selection": Scenario(cite_selection, expect=frozenset({"selection"}), forbid=frozenset({"stuck"})),
    "reading_paper": Scenario(reading_paper, expect=frozenset({"settled"}), forbid=frozenset({"stuck"})),
    "flight_search": Scenario(flight_search, expect=frozenset({"settled"}), forbid=frozenset({"stuck"})),
    "compare_products": Scenario(compare_products, expect=frozenset({"settled"}), forbid=frozenset({"stuck"})),
    # non-moments
    "quick_glances": Scenario(quick_glances, forbid=frozenset({"settled", "stuck"})),
    "short_selection": Scenario(short_selection, forbid=frozenset({"selection", "stuck"})),
}

STUCK = [name for name, sc in SCENARIOS.items() if "stuck" in sc.expect]
ROUTINE = [name for name in ("focused_coding", "reading", "tab_hopping", "copy_between_apps", "fast_copy_paste",
                             "one_off_error", "typo_fixes", "morning_startup", "errors_far_apart")]
