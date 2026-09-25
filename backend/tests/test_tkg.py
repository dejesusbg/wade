import asyncio
import json
import sys
import tempfile
from pathlib import Path

import pytest

from wade_backend import protocol, synthetic
from wade_backend.server import BackendServer
from wade_backend.synthetic import CHROME, SAFARI, XCODE, Session
from wade_backend.tkg import GateConfig, MomentConfig, Stage1, TemporalGraph, digest, extract


def run(session: Session, **kw):
    checks = []
    stage1 = Stage1(on_check=checks.append, **kw)
    decisions = stage1.replay(session.events, until=session.t)
    return stage1, decisions, checks


def kinds(checks):
    return [c.kind for c in checks]


# ---- scenario set --------------------------------------------------------------------------


@pytest.mark.parametrize("name", sorted(synthetic.SCENARIOS))
def test_scenario(name):
    sc = synthetic.SCENARIOS[name]
    _, decisions, checks = run(sc.build())
    got = set(kinds(checks))
    worst = max(decisions, key=lambda d: d.score)
    assert sc.expect <= got, f"{name}: missing {sc.expect - got}; got {kinds(checks)}"
    assert not (sc.forbid & got), f"{name}: got forbidden {sc.forbid & got}; stuck peak {worst.score} {worst.reasons}"


def test_stuck_margins_are_not_razor_thin():
    """Guard against tuning the scenarios to sit exactly on the threshold."""
    threshold = GateConfig().threshold
    for name in synthetic.STUCK:
        _, decisions, _ = run(synthetic.SCENARIOS[name].build())
        assert max(d.score for d in decisions) >= threshold + 0.05, name
    for name in synthetic.ROUTINE:
        _, decisions, _ = run(synthetic.SCENARIOS[name].build())
        assert max(d.score for d in decisions) <= threshold - 0.1, name


# ---- stuck rules ---------------------------------------------------------------------------


def test_stuck_on_third_recurrence_not_before():
    s = Session().focus(XCODE, "App.swift").error("sig").wait(20).error("sig").wait(20)
    _, _, checks = run(s)
    assert "stuck" not in kinds(checks)
    s.error("sig")
    _, _, checks = run(s)
    stuck = [c for c in checks if c.kind == "stuck"]
    assert len(stuck) == 1 and stuck[0].reasons[0] == "recurring_error"


def test_stuck_cooldown_once_per_episode_then_again_later():
    s = Session().focus(XCODE, "App.swift")
    for _ in range(6):
        s.error("sig").wait(10)
    _, decisions, checks = run(s)
    assert kinds(checks).count("stuck") == 1
    assert any(d.suppressed_by_cooldown for d in decisions)

    s.wait(200)  # past the cooldown, a fresh burst of the same error
    for _ in range(3):
        s.error("sig").wait(10)
    _, _, checks = run(s)
    assert kinds(checks).count("stuck") == 2


def test_different_errors_do_not_count_as_recurrence():
    s = Session().focus(XCODE, "App.swift")
    for sig in ("a", "b", "c", "d"):
        s.error(sig).wait(10)
    _, _, checks = run(s)
    assert "stuck" not in kinds(checks)


def test_pingpong_alone_is_not_stuck():
    s = Session().focus(XCODE, "App.swift").pingpong(XCODE, SAFARI, 10, 5)
    _, decisions, checks = run(s)
    assert "stuck" not in kinds(checks)
    assert "app_pingpong" in decisions[-1].reasons


# ---- other moments -------------------------------------------------------------------------


def test_settled_waits_for_dwell_and_checks_each_context_once():
    s = Session().focus(CHROME, "Repo").snapshot("https://github.com/a/b", "Clone")
    s.wait(5)  # 9s in: not settled yet
    _, _, checks = run(s)
    assert "settled" not in kinds(checks)

    s.wait(10).focus(SAFARI, "Docs").snapshot("https://docs.example.com", "API").wait(20)
    s.focus(CHROME, "Repo").snapshot("https://github.com/a/b", "Clone").wait(30)  # revisit
    _, _, checks = run(s)
    settled = [c for c in checks if c.kind == "settled"]
    assert [c.context["url"] for c in settled] == ["https://github.com/a/b", "https://docs.example.com"]


def test_revisit_after_ttl_is_checked_again():
    s = Session().focus(CHROME, "Repo").snapshot("https://github.com/a/b").wait(20)
    s.focus(SAFARI, "Docs").snapshot("https://docs.example.com").wait(700)
    s.focus(CHROME, "Repo").snapshot("https://github.com/a/b").wait(20)
    _, _, checks = run(s)
    urls = [c.context["url"] for c in checks if c.kind == "settled"]
    assert urls.count("https://github.com/a/b") == 2


def test_selection_is_checked_once_after_being_held():
    text = "A paragraph long enough to be worth citing or summarizing."
    s = Session().focus(CHROME, "Article").select(text).wait(1)
    _, _, checks = run(s)
    assert "selection" not in kinds(checks)  # not held long enough yet
    s.wait(30)
    _, _, checks = run(s)
    sel = [c for c in checks if c.kind == "selection"]
    assert len(sel) == 1 and sel[0].context["selection"] == text


def test_audit_runs_when_quiet_and_is_never_surfaced():
    s = Session().focus(XCODE, "App.swift")
    for _ in range(24):  # 12 minutes of steady typing: nothing else to check
        s.type(20, 10).wait(20)
    _, _, checks = run(s)
    audits = [c for c in checks if c.kind == "audit"]
    assert len(audits) == 2
    assert all(not c.surface for c in audits)
    assert all(c.surface for c in checks if c.kind != "audit")


def test_no_audit_while_idle():
    s = Session().focus(SAFARI, "Article").type(10, 5)
    s.idle(900)
    _, _, checks = run(s)
    assert "audit" not in kinds(checks)


def test_budget_caps_checks_under_heavy_churn():
    s = Session()
    for i in range(240):  # an hour of a new page every 15s
        s.focus(CHROME, f"Page {i}").snapshot(f"https://example.com/{i}", "text").wait(11)
    _, _, checks = run(s)
    times = [c.ts for c in checks]
    assert all(b - a >= MomentConfig().min_interval_s for a, b in zip(times, times[1:]))
    assert len(checks) <= MomentConfig().max_per_hour


def test_stuck_bypasses_the_budget():
    s = Session().focus(CHROME, "Repo").snapshot("https://github.com/a/b").wait(12)  # settled at 16s
    s.error("sig").wait(1).error("sig").wait(1).error("sig")  # stuck right after
    _, _, checks = run(s)
    assert kinds(checks)[:2] == ["settled", "stuck"]


def test_context_carries_screen_content_and_digest_does_not():
    s = Session().focus(CHROME, "Repo").snapshot("https://github.com/dejesusbg/monet", "Clone HTTPS SSH secret-ish")
    s.error("sig", "Permission denied: /usr/local").wait(20)
    _, _, checks = run(s)
    c = next(c for c in checks if c.kind == "settled")
    assert c.context["excerpt"].startswith("Clone") and c.context["error_text"].startswith("Permission")
    assert "github.com" in c.digest
    assert "secret-ish" not in c.digest and "/dejesusbg/monet" not in c.digest


def test_other_apps_error_and_selection_dont_leak_into_a_settled_context():
    """Live run 2026-09-25: a test app's error dialog rode along on an unrelated shopping page."""
    s = Session().focus(XCODE, "Build").error("sig", "Build Failed: something").select("a paragraph selected in Xcode here")
    s.wait(3).focus(CHROME, "Compare phones").snapshot("https://apple.com/compare", "iPhone vs iPhone").wait(20)
    _, _, checks = run(s)
    c = next(c for c in checks if c.kind == "settled" and c.context.get("app") == "Chrome")
    assert "error_text" not in c.context and "selection" not in c.context


def test_stuck_context_keeps_the_error_from_the_app_just_left():
    from wade_backend.tkg.moments import build_context

    s = Session().focus(XCODE, "Build").error("sig", "Build Failed: cannot find X").wait(2).focus(SAFARI, "search")
    stage1 = Stage1()
    stage1.replay(s.events, until=s.t)
    g = stage1.graph
    assert build_context(g, "stuck")["error_text"].startswith("Build Failed")
    assert "error_text" not in build_context(g, "settled")


def test_stage1_never_sends_trigger_fired():
    """Stage 1 can't reach the user: nothing it does produces a message to the app."""
    async def scenario():
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            checks = []
            stage1 = Stage1(on_check=checks.append)
            server = BackendServer(Path(tmp) / "s.sock", stage1.ingest)
            await server.start()
            serve = asyncio.create_task(server.serve_forever())
            try:
                reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
                for sc in synthetic.SCENARIOS.values():
                    s = sc.build()
                    for e in s.events:
                        writer.write(protocol.encode(e))
                        await writer.drain()
                        stage1.tick(e["timestamp"])
                    stage1.tick(s.t)
                writer.write(protocol.encode({"type": "ping"}))
                await writer.drain()
                replies = [protocol.decode(await asyncio.wait_for(reader.readline(), 2))]
                writer.close()
            finally:
                serve.cancel()
                await server.close()
            return checks, replies

    checks, replies = asyncio.run(scenario())
    assert checks  # the scenarios did produce moments…
    assert [r["type"] for r in replies] == ["pong"]  # …and the only thing the app ever got was the pong
    source = Path(__file__).parents[1] / "src" / "wade_backend" / "tkg"
    for path in source.glob("*.py"):
        text = path.read_text()
        assert "trigger_fired" not in text and "from ..server" not in text and "from .. import server" not in text, path


# ---- graph ---------------------------------------------------------------------------------


def test_window_prunes_old_nodes_but_keeps_current_focus():
    g = TemporalGraph(window_s=600)
    s = Session().focus(XCODE, "App.swift").error("sig").wait(900).type(10, 2)
    for e in s.events:
        g.ingest(e)
    assert not g.errors()
    assert g.current_focus().app_bundle_id == XCODE[0]


def test_decay_halves_per_half_life():
    g = TemporalGraph(half_life_s=120)
    s = Session().focus(XCODE).error("sig").wait(120).type(5, 0)
    for e in s.events:
        g.ingest(e)
    assert g.weight(g.errors()[0]) == pytest.approx(0.5)


def test_edges():
    g = TemporalGraph()
    s = (Session().focus(XCODE, "a").error("x").wait(5).focus(SAFARI, "b").wait(5)
         .focus(XCODE, "a").error("x").wait(5).title("c"))
    for e in s.events:
        g.ingest(e)
    assert list(g.switch_edges()) == [(XCODE[0], SAFARI[0]), (SAFARI[0], XCODE[0])]
    assert len(g.repeat_edges()) == 1
    assert g.errors()[1].recurrence_count == 2
    assert len(list(g.next_edges())) == len(g.nodes) - 1


def test_snapshot_attaches_to_current_focus_and_stale_ones_are_dropped():
    g = TemporalGraph()
    s = Session().focus(CHROME, "A").snapshot("https://a.example", "aaa")
    stale = dict(s.events[-1], window_title="Some other tab", metadata={"url": "https://b.example"})
    for e in s.events + [stale]:
        g.ingest(e)
    focus = g.current_focus()
    assert (focus.url, focus.excerpt, focus.snapshotted) == ("https://a.example", "aaa", True)
    assert len(g.nodes) == 1  # snapshots aren't nodes


def test_duplicate_focus_is_ignored_and_out_of_order_is_sorted():
    g = TemporalGraph()
    s = Session().focus(XCODE, "a").focus(XCODE, "a")
    for e in s.events:
        g.ingest(e)
    assert len(g.focus_events()) == 1
    late = dict(s.events[0], event_type="undo", timestamp=s.t - 5, metadata={})
    g.ingest(late)
    assert [n.ts for n in g.nodes] == sorted(n.ts for n in g.nodes)


# ---- digest --------------------------------------------------------------------------------


def test_digest_for_build_loop_reads_like_the_brief():
    _, _, checks = run(synthetic.build_loop())
    text = next(c for c in checks if c.kind == "stuck").digest
    assert "Xcode↔Safari" in text
    assert "same error dialog in Xcode appeared" in text
    assert text.endswith(".")


def test_digest_mentions_idle_and_undos():
    s = Session().focus(CHROME, "Docs").idle(60).wait(10).undo(3).type(10, 3)
    g = TemporalGraph()
    for e in s.events:
        g.ingest(e)
    text = digest.render(g, extract(g))
    assert "was idle 1min" in text and "3 undos" in text


def test_digest_when_nothing_happened():
    g = TemporalGraph()
    assert digest.render(g, extract(g)) == "No notable activity."


# ---- wiring --------------------------------------------------------------------------------


def test_socket_to_stage1_end_to_end():
    async def scenario():
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            checks = []
            stage1 = Stage1(on_check=checks.append)
            server = BackendServer(Path(tmp) / "s.sock", stage1.ingest)
            await server.start()
            serve = asyncio.create_task(server.serve_forever())
            try:
                reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
                for e in synthetic.build_loop().events:
                    writer.write(protocol.encode(e))
                writer.write(protocol.encode({"type": "ping"}))  # pong ⇒ everything before it was handled
                await writer.drain()
                await asyncio.wait_for(reader.readline(), 2)
                writer.close()
            finally:
                serve.cancel()
                await server.close()
            return checks

    checks = asyncio.run(scenario())
    assert kinds(checks) == ["stuck"] and "Xcode↔Safari" in checks[0].digest


def test_replay_cli(tmp_path, capsys, monkeypatch):
    from wade_backend import replay

    path = tmp_path / "session.jsonl"
    s = synthetic.permission_hunt()
    s.wait(30).focus(CHROME, "Repo").snapshot("https://github.com/a/b", "Clone").wait(20)
    s.type(5, 2)  # replay time only advances as far as the last recorded event
    path.write_text("\n".join([json.dumps(e) for e in s.events] + ["garbage"]) + "\n")
    monkeypatch.setattr(sys, "argv", ["wade-replay", str(path)])
    replay.main()
    out = capsys.readouterr()
    assert "CHECK stuck" in out.out and "CHECK settled" in out.out
    assert "skipped" in out.err
