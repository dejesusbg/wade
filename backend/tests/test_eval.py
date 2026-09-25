"""Phase 7 harness pieces that don't need the model: decision rules, metrics, the case set."""

import math

import pytest

from wade_backend.evalset import cases as evalcases
from wade_backend.evalset import harness
from wade_backend.stage2 import anchors, prompt
from wade_backend.stage2.rules import PHASE3, Baseline, Rule, decide

FAMS = {f: 0.0 for f in anchors.FAMILIES}


def fams(**kw):
    return FAMS | kw


# ---- rules --------------------------------------------------------------------------------


def test_beat_null_is_the_phase3_rule():
    assert decide(PHASE3, fams(coding=0.03), 0.02) == (True, "coding")
    assert decide(PHASE3, fams(coding=0.03), 0.04) == (False, None)  # "nothing" wins
    assert decide(PHASE3, fams(coding=0.004), 0.0) == (False, None)  # under the threshold


def test_margin_can_let_an_action_fire_below_null():
    r = Rule("margin", t=0.005, m=-0.01)
    assert decide(r, fams(writing=0.024), 0.029) == (True, "writing")  # the live selection case
    assert decide(r, fams(writing=0.015), 0.029) == (False, None)


def test_zscore_uses_each_familys_own_quiet_level():
    base = Baseline.fit([fams(fixing=0.02, coding=0.0), fams(fixing=0.04, coding=0.002)])
    r = Rule("zscore", t=0.0, k=2.0, baseline=base)
    # fixing is always high on quiet cases, so 0.05 isn't remarkable; coding at 0.02 is.
    fire, mode = decide(r, fams(fixing=0.05, coding=0.02), 0.03)
    assert fire and mode == "coding"
    assert decide(r, fams(fixing=0.035, coding=0.001), 0.03) == (False, None)


def test_zscore_floor_on_spread():
    base = Baseline.fit([fams(), fams()])  # all zeros: std 0
    assert base.z("coding", 0.004) == pytest.approx(0.004 / base.min_std)


def test_output_word_control():
    assert decide(Rule("output"), FAMS, 0.0, "Clone") == (True, "coding")
    assert decide(Rule("output"), FAMS, 0.0, "nothing") == (False, None)
    assert decide(Rule("output"), FAMS, 0.0, "the") == (False, None)


def test_rule_roundtrips_through_json():
    base = Baseline.fit([fams(coding=0.01), fams(coding=0.03)])
    r = Rule("zscore", t=0.002, k=2.5, baseline=base)
    back = Rule.from_json(r.to_json())
    assert back == r and back.baseline.mean == base.mean


# ---- metrics ------------------------------------------------------------------------------


def test_wilson_interval():
    lo, hi = harness.wilson(8, 10)
    assert 0.44 < lo < 0.5 and 0.94 < hi < 0.97
    assert harness.wilson(0, 0) == (0.0, 1.0)


def _case(id, label, mode=None):
    return evalcases.Case(id, evalcases.CAL, "f", label, mode, None)


def test_score_counts_and_excludes_either():
    cs = [_case("a", "fire", "coding"), _case("b", "fire", "writing"), _case("c", "quiet"),
          _case("d", "quiet"), _case("e", "either")]
    preds = {"a": (True, "coding"), "b": (True, "fixing"), "c": (True, "coding"), "d": (False, None),
             "e": (True, "sharing")}
    m = harness.score(cs, preds)
    assert (m.tp, m.fp, m.tn, m.fn) == (2, 1, 1, 0)
    assert m.mode_ok == 1 and m.either_fired == 1 and m.n == 4
    assert m.precision == pytest.approx(2 / 3) and m.recall == 1.0
    assert m.f_beta(0.5) == pytest.approx((1.25 * (2 / 3) * 1) / (0.25 * (2 / 3) + 1))


def test_no_fires_scores_zero_not_nan():
    m = harness.score([_case("a", "fire", "coding")], {"a": (False, None)})
    assert m.f_beta() == 0.0 and math.isnan(m.precision)


# ---- the case set -------------------------------------------------------------------------


def test_case_set_is_balanced_and_split_by_family():
    cal = evalcases.split(evalcases.CAL)
    test = evalcases.split(evalcases.TEST)
    assert len(cal) >= 35 and len(test) >= 35
    assert {c.family for c in cal}.isdisjoint({c.family for c in test}), "a family sits in both splits"
    for part in (cal, test):
        labels = [c.label for c in part]
        assert labels.count("fire") >= 15 and labels.count("quiet") >= 15
        assert {c.mode for c in part if c.mode} == set(anchors.FAMILIES), "every mode on both sides"


def test_cases_render_into_the_stage2_prompt():
    for c in evalcases.CASES:
        text = prompt.user_message(c.check, "v3")
        assert "Recent activity:" in text and "What's on screen:" in text
        assert len(c.check.context.get("excerpt", "")) <= 500 and len(c.check.context.get("selection", "")) <= 500


def test_prompt_variants_differ_only_in_the_question():
    c = evalcases.CASES[0].check
    v2, v3 = prompt.user_message(c, "v2"), prompt.user_message(c, "v3")
    assert v2.endswith('"nothing" if they are fine on their own.') and v3.endswith("Answer with one verb.")
    assert v2.rsplit("\n", 1)[0] == v3.rsplit("\n", 1)[0]


# ---- real-use join ------------------------------------------------------------------------


def test_verdict_outcomes_and_report():
    from wade_backend.evalset import verdicts as V

    assert V.outcome(["composed", "shown_auto", "closed_unseen"]) == "ignored"
    assert V.outcome(["composed", "shown_auto", "opened", "action_done"]) == "accepted"
    assert V.outcome(["composed", "opened", "accepted", "corrected"]) == "corrected"
    assert V.outcome(["composed", "shown_auto", "rejected"]) == "rejected"
    assert V.outcome(["composed"]) == "not shown"
    checks = [{"ts": 0, "kind": "selection", "stage2": {"fire": True, "mode": "writing", "latency_ms": 500},
               "suggestion_id": "s1"},
              {"ts": 1800, "kind": "settled", "stage2": {"fire": False, "mode": None, "latency_ms": 400}}]
    vs = [{"suggestion_id": "s1", "event": "composed", "mode": "writing"},
          {"suggestion_id": "s1", "event": "shown_auto"},
          {"suggestion_id": "s1", "event": "rejected"},
          {"suggestion_id": "sample-1", "event": "accepted", "sample": True}]
    text = V.report(checks, vs)
    assert "fired on 1 (50%)" in text and "rejected 1" in text and "welcome rate (accepted / judged): 0% of 1" in text
    assert "suggestions: 1 ·" in text  # the sample is left out by default


def test_explanation_puts_family_concepts_first():
    from wade_backend.__main__ import explanation_order

    assert explanation_order([("prompt", 0.024), ("explain", 0.018), ("fix", 0.014), ("念头", 0.012)]) == \
        ["explain", "fix", "prompt", "念头"]


def test_pid_alive():
    import os
    import subprocess

    from wade_backend.__main__ import pid_alive

    assert pid_alive(os.getpid())
    p = subprocess.Popen(["true"])
    p.wait()
    assert not pid_alive(p.pid)
