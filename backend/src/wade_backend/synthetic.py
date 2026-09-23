"""Synthetic `tkg_event` sessions for testing Stage 1 (Phase 2) and, later, the eval harness
(Phase 7).

`Session` is a small builder that emits events shaped exactly like the Swift app's. The
scenario functions below are the constructed "should fire" / "should not fire" set. They are
hand-written stories, not recorded behavior, so they check that the rules do what they're
designed to do. They don't show the rules are right about people.
"""

from __future__ import annotations

from collections.abc import Callable
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

    def error(self, signature: str) -> Session:
        self._emit("error_dialog", {"signature": signature, "role": "AXDialog"})
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


Scenario = Callable[[], list[dict[str, Any]]]

# ---- should fire ---------------------------------------------------------------------------


def build_loop() -> list[dict[str, Any]]:
    """The brief's example: a build error recurring while flipping to the browser for answers."""
    s = Session().focus(XCODE, "Wade — ActivityObserver.swift").type(60, 20)
    for _ in range(3):
        s.wait(5).error("build-failed-7f3a")
        s.pingpong(XCODE, SAFARI, 2, 12, "Wade — ActivityObserver.swift", "AXObserver crash - Stack Overflow")
        s.type(15, 6)
    return s.events


def undo_storm_with_error() -> list[dict[str, Any]]:
    """Editing, undoing, retrying, hitting the same export error twice."""
    s = Session().focus(PAGES, "Thesis draft").type(80, 30)
    s.wait(10).error("export-failed-11aa")
    s.undo(3).type(10, 5).undo(2)
    s.wait(20).error("export-failed-11aa")
    return s.events


def permission_hunt() -> list[dict[str, Any]]:
    """Terminal ↔ System Settings, the same 'permission denied' error twice."""
    s = Session().focus(TERMINAL, "zsh").type(20, 5).error("permission-denied-0c1d")
    s.pingpong(TERMINAL, SETTINGS, 6, 10, "zsh", "Privacy & Security")
    s.type(12, 4).error("permission-denied-0c1d")
    return s.events


def stare_then_scramble() -> list[dict[str, Any]]:
    """A long pause after an error, then the error again and a burst of switching."""
    s = Session().focus(XCODE, "Package.swift").error("resolve-failed-9e2b")
    s.idle(90)
    s.pingpong(XCODE, CHROME, 4, 8, "Package.swift", "SwiftPM dependency resolution failed")
    s.error("resolve-failed-9e2b")
    return s.events


SHOULD_FIRE: dict[str, Scenario] = {
    "build_loop": build_loop,
    "undo_storm_with_error": undo_storm_with_error,
    "permission_hunt": permission_hunt,
    "stare_then_scramble": stare_then_scramble,
}

# ---- should not fire -----------------------------------------------------------------------


def focused_coding() -> list[dict[str, Any]]:
    """Ten minutes of steady editing, a couple of doc lookups, one undo."""
    s = Session().focus(XCODE, "Wade — Gate.swift")
    for i in range(20):
        s.type(40, 15).wait(15)
        if i in (6, 14):
            s.focus(SAFARI, "Swift docs").wait(20).focus(XCODE, "Wade — Gate.swift")
        if i == 10:
            s.undo()
    return s.events


def reading() -> list[dict[str, Any]]:
    """Reading a long article: long pauses, occasional scrolling-as-idle-breaks."""
    s = Session().focus(SAFARI, "A long article")
    for _ in range(6):
        s.idle(70).wait(20)
    return s.events


def tab_hopping() -> list[dict[str, Any]]:
    """Many tabs in one browser (title changes, same app), a quick Slack check."""
    s = Session().focus(CHROME, "Inbox")
    for i in range(15):
        s.wait(12).title(f"Tab {i}")
    s.focus(SLACK, "#general").type(20, 6).focus(CHROME, "Tab 14")
    return s.events


def copy_between_apps() -> list[dict[str, Any]]:
    """Copying figures from a spreadsheet into a doc: regular, spaced-out ping-pong."""
    s = Session().focus(NOTES, "Meeting notes")
    for _ in range(4):
        s.wait(60).focus(SAFARI, "Dashboard").wait(40).focus(NOTES, "Meeting notes").type(25, 8)
    return s.events


def one_off_error() -> list[dict[str, Any]]:
    """A single error dialog, dismissed, then back to normal work."""
    s = Session().focus(MAIL, "Inbox").type(30, 10).error("send-failed-2b7c")
    s.wait(10).type(20, 6).wait(60).type(40, 15)
    return s.events


def typo_fixes() -> list[dict[str, Any]]:
    """Two undos while writing: ordinary."""
    s = Session().focus(PAGES, "Essay").type(100, 40).undo(2).type(80, 30)
    return s.events


def morning_startup() -> list[dict[str, Any]]:
    """Opening a handful of apps once each: many distinct apps, no repetition."""
    s = Session()
    for app in (MAIL, SLACK, CHROME, NOTES, XCODE, TERMINAL):
        s.focus(app, "").wait(15)
    s.type(30, 10)
    return s.events


def errors_far_apart() -> list[dict[str, Any]]:
    """The same error twice, eight minutes apart, with normal work between (decay)."""
    s = Session().focus(XCODE, "App.swift").error("build-failed-7f3a")
    for _ in range(16):
        s.type(30, 10).wait(20)
    s.error("build-failed-7f3a")
    return s.events


SHOULD_NOT_FIRE: dict[str, Scenario] = {
    "focused_coding": focused_coding,
    "reading": reading,
    "tab_hopping": tab_hopping,
    "copy_between_apps": copy_between_apps,
    "one_off_error": one_off_error,
    "typo_fixes": typo_fixes,
    "morning_startup": morning_startup,
    "errors_far_apart": errors_far_apart,
}
