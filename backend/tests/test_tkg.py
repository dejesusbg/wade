import pytest

from wade_backend import synthetic
from wade_backend.synthetic import CHROME, SAFARI, XCODE, Session
from wade_backend.tkg import GateConfig, Stage1, TemporalGraph, digest, extract


def run(events, **kw):
    fires = []
    stage1 = Stage1(on_fire=fires.append, **kw)
    decisions = [stage1.ingest(e) for e in events]
    return stage1, decisions, fires


# ---- scenario set --------------------------------------------------------------------------


@pytest.mark.parametrize("name", sorted(synthetic.SHOULD_FIRE))
def test_should_fire(name):
    _, decisions, fires = run(synthetic.SHOULD_FIRE[name]())
    assert fires, f"{name}: never fired; max score {max(d.score for d in decisions)}"


@pytest.mark.parametrize("name", sorted(synthetic.SHOULD_NOT_FIRE))
def test_should_not_fire(name):
    _, decisions, fires = run(synthetic.SHOULD_NOT_FIRE[name]())
    worst = max(decisions, key=lambda d: d.score)
    assert not fires, f"{name}: fired; worst score {worst.score} {worst.reasons}"


def test_margins_are_not_razor_thin():
    """Guard against tuning the scenarios to sit exactly on the threshold."""
    threshold = GateConfig().threshold
    for name, scenario in synthetic.SHOULD_FIRE.items():
        _, decisions, _ = run(scenario())
        assert max(d.score for d in decisions) >= threshold + 0.05, name
    for name, scenario in synthetic.SHOULD_NOT_FIRE.items():
        _, decisions, _ = run(scenario())
        assert max(d.score for d in decisions) <= threshold - 0.1, name


# ---- gate behaviour ------------------------------------------------------------------------


def test_fires_on_third_recurrence_not_before():
    s = Session().focus(XCODE, "App.swift").error("sig").wait(20).error("sig").wait(20)
    _, decisions, fires = run(s.events)
    assert not fires
    s.error("sig")
    _, decisions, fires = run(s.events)
    assert len(fires) == 1 and fires[0].decision.reasons[0] == "recurring_error"


def test_cooldown_fires_once_per_episode_then_again_later():
    s = Session().focus(XCODE, "App.swift")
    for _ in range(6):
        s.error("sig").wait(10)
    _, decisions, fires = run(s.events)
    assert len(fires) == 1
    assert any(d.suppressed_by_cooldown for d in decisions)

    s.wait(200)  # past the cooldown, a fresh burst of the same error
    for _ in range(3):
        s.error("sig").wait(10)
    _, _, fires = run(s.events)
    assert len(fires) == 2


def test_different_errors_do_not_count_as_recurrence():
    s = Session().focus(XCODE, "App.swift")
    for sig in ("a", "b", "c", "d"):
        s.error(sig).wait(10)
    _, _, fires = run(s.events)
    assert not fires


def test_pingpong_alone_does_not_fire():
    s = Session().focus(XCODE, "App.swift").pingpong(XCODE, SAFARI, 10, 5)
    _, decisions, fires = run(s.events)
    assert not fires
    assert "app_pingpong" in decisions[-1].reasons


# ---- graph ---------------------------------------------------------------------------------


def test_window_prunes_old_nodes_but_keeps_current_focus():
    g = TemporalGraph(window_s=600)
    s = Session().focus(XCODE, "App.swift").error("sig").wait(900).type(10, 2)
    for e in s.events:
        g.ingest(e)
    assert not g.errors()  # 900s old: gone
    assert g.current_focus().app_bundle_id == XCODE[0]  # began 900s ago, still current


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
    stage1, _, fires = run(synthetic.build_loop())
    text = fires[0].digest
    assert "Xcode↔Safari" in text
    assert "same error dialog in Xcode appeared" in text
    assert text.endswith(".")


def test_digest_mentions_idle_and_undos():
    s = (Session().focus(CHROME, "Docs").idle(60).wait(10).undo(3).type(10, 3))
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
    import asyncio
    import tempfile
    from pathlib import Path

    from wade_backend import protocol
    from wade_backend.server import BackendServer

    async def scenario():
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            fires = []
            stage1 = Stage1(on_fire=fires.append)
            server = BackendServer(Path(tmp) / "s.sock", stage1.ingest)
            await server.start()
            serve = asyncio.create_task(server.serve_forever())
            try:
                reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
                for e in synthetic.build_loop():
                    writer.write(protocol.encode(e))
                writer.write(protocol.encode({"type": "ping"}))  # pong ⇒ everything before it was handled
                await writer.drain()
                await asyncio.wait_for(reader.readline(), 2)
                writer.close()
            finally:
                serve.cancel()
                await server.close()
            return fires

    fires = asyncio.run(scenario())
    assert len(fires) == 1 and "Xcode↔Safari" in fires[0].digest


def test_replay_cli(tmp_path, capsys, monkeypatch):
    import json
    import sys

    from wade_backend import replay

    path = tmp_path / "session.jsonl"
    lines = [json.dumps(e) for e in synthetic.permission_hunt() + synthetic.focused_coding()]
    path.write_text("\n".join(lines + ["garbage"]) + "\n")
    monkeypatch.setattr(sys, "argv", ["wade-replay", str(path)])
    replay.main()
    out = capsys.readouterr()
    assert "GATE FIRED" in out.out and "1 gate fires" in out.out
    assert "skipped" in out.err
