"""`wade-eval`: the Phase 7 evaluation harness.

    uv run wade-eval collect --lens identity --prompt v2   # model pass over all cases (GPU, ~1 min)
    uv run wade-eval report                                # calibrate on one half, score the other
    uv run wade-eval report --save                         # also write stage2-calibration.json
    uv run wade-eval cases                                 # list the labeled cases
    uv run wade-eval verdicts                              # real use: checks ⋈ your verdicts

Lenses: ``identity`` (J = I, the logit lens), ``learned`` (the 120-prompt corpus-averaged J),
``mix`` (learned at 13/18, J = I later). Readouts are cached under
~/Library/Application Support/Wade/eval/readouts/.
"""

from __future__ import annotations

import argparse
import json
import statistics
import time
from collections import Counter, defaultdict

from . import harness
from .cases import CAL, TEST

LENS_FILES = {"identity": "jlens-qwen3-4b.npz", "learned": "jlens-learned.npz"}


def _load_lens(name: str):
    from ..stage2.jlens import DEFAULT_PATH, JLens

    root = DEFAULT_PATH.parent
    if name in LENS_FILES:
        return JLens.load(root / LENS_FILES[name])
    if name == "mix":
        learned, ident = JLens.load(root / LENS_FILES["learned"]), JLens.load(root / LENS_FILES["identity"])
        pick = lambda l: learned if l in (13, 18) else ident  # noqa: E731
        return JLens(learned.layers, {l: pick(l).J[l] for l in learned.layers},
                     {l: pick(l).atom_norms[l] for l in learned.layers}, learned.rms_ref,
                     {"variant": "mix: learned J at 13,18; J=I at 23,27,32"})
    raise SystemExit(f"unknown lens {name}")


def cmd_collect(args) -> None:
    from ..stage2.check import Stage2, Stage2Config
    from ..stage2.model import LensModel

    cases = harness.all_cases()
    stage2 = Stage2(LensModel(), _load_lens(args.lens), Stage2Config(layers=None, prompt=args.prompt))
    stage2.read(cases[0].check, layers=None)  # warm-up (compile, caches)
    rows, lat = {}, []
    t0 = time.time()
    for i, c in enumerate(cases):
        r = stage2.read(c.check, layers=None)
        rows[c.id] = r.to_json()
        lat.append(r.latency_ms)
        if args.pause:
            time.sleep(args.pause)  # heat: optional breather between checks
        if (i + 1) % 20 == 0:
            print(f"  {i + 1}/{len(cases)}")
    path = harness.readout_path(args.lens, args.prompt)
    harness.save_readouts(path, rows)
    print(f"{len(rows)} readouts → {path} in {time.time() - t0:.0f}s; per check (all 5 layers) "
          f"median {statistics.median(lat):.0f} ms, max {max(lat):.0f} ms")


def cmd_timing(args) -> None:
    """Latency of the deployed configuration: only its layers are decomposed."""
    from ..stage2.check import CALIBRATION_PATH, Stage2, Stage2Config
    from ..stage2.model import LensModel

    cfg = Stage2Config.calibrated()
    saved = json.loads(CALIBRATION_PATH.read_text()) if CALIBRATION_PATH.exists() else {}
    lens = args.lens or saved.get("lens", "identity")
    stage2 = Stage2(LensModel(), _load_lens(lens), cfg)
    cases = harness.all_cases()
    stage2.evaluate(cases[0].check)
    lat = sorted(stage2.evaluate(c.check).latency_ms for c in cases)
    p95 = lat[max(0, int(round(0.95 * len(lat))) - 1)]
    print(f"{lens}, layers {cfg.layers}, prompt {cfg.prompt}, rule {cfg.rule.label()}: "
          f"median {statistics.median(lat):.0f} ms, p95 {p95:.0f} ms, max {lat[-1]:.0f} ms over {len(lat)} checks")


def _row(c: harness.Candidate) -> str:
    return (f"{c.lens:8} {c.prompt:3} {c.layers:9} {c.rule.label():26} | cal F0.5 {c.cal.f_beta():.2f} "
            f"P {c.cal.precision:.0%} R {c.cal.recall:.0%} | held-out F0.5 {c.test.f_beta():.2f} "
            f"P {c.test.precision:.0%} R {c.test.recall:.0%} mode {c.test.mode_accuracy:.0%}")


def cmd_report(args) -> None:
    from ..stage2.check import CALIBRATION_PATH, Stage2Config
    from ..stage2.rules import PHASE3

    cases = harness.all_cases()
    by_id = {c.id: c for c in cases}
    everything: list[harness.Candidate] = []
    readouts_by = {}
    for path in sorted((harness.EVAL_DIR / "readouts").glob("*.jsonl")):
        lens, prompt = path.stem.rsplit("-", 1)
        readouts = harness.load_readouts(path)
        readouts_by[(lens, prompt)] = readouts
        everything += harness.sweep(readouts, lens, prompt, cases)
    # "mix" needs no model pass: layers are read independently, so learned J at 13/18 and
    # J = I at 23/27/32 combine from the two cached runs of the same prompt.
    for prompt in sorted({p for _, p in readouts_by}):
        if ("identity", prompt) in readouts_by and ("learned", prompt) in readouts_by:
            mix = harness.mix_readouts(readouts_by[("learned", prompt)], readouts_by[("identity", prompt)])
            readouts_by[("mix", prompt)] = mix
            everything += harness.sweep(mix, "mix", prompt, cases)
    if not everything:
        raise SystemExit("no readouts yet: run `wade-eval collect` first")

    n_cal = sum(c.split == CAL for c in cases)
    n_test = sum(c.split == TEST for c in cases)
    print(f"cases: {n_cal} calibration (80-case set + pipeline scenarios), {n_test} held-out; "
          f"{len(everything)} configurations swept, chosen on calibration F0.5 only\n")

    print("Phase 3 rule as shipped (J = I, v2, layers 23/27/32, beat-null t=0.005):")
    if ("identity", "v2") in readouts_by:
        r = readouts_by[("identity", "v2")]
        cal = [c for c in cases if c.split == CAL]
        test = [c for c in cases if c.split == TEST]
        print("  calibration ", harness.score(cal, harness.predictions(r, cal, (23, 27, 32), PHASE3)).summary())
        print("  held-out    ", harness.score(test, harness.predictions(r, test, (23, 27, 32), PHASE3)).summary())

    print("\nBest per lens × prompt (J-space rules), chosen on calibration:")
    for lens, prompt in sorted(readouts_by):
        pool = [c for c in everything if c.lens == lens and c.prompt == prompt and c.rule.name != "output"]
        print("  " + _row(max(pool, key=harness.Candidate.key)))

    print("\nBest per rule type (all lenses/prompts), chosen on calibration:")
    for name in ("beat-null", "margin", "zscore", "output"):
        pool = [c for c in everything if c.rule.name == name]
        if pool:
            print("  " + _row(max(pool, key=harness.Candidate.key)))

    top = max((c for c in everything if c.rule.name != "output"), key=harness.Candidate.key)
    print(f"\nBest in-sample (pre-stated procedure): {_row(top)}")
    print("  held-out    ", top.test.summary())

    # Robustness: leave-one-calibration-family-out CV. Chooses the configuration whose
    # parameters transfer to a family they weren't fitted on. Calibration half only.
    cv: list[harness.CVResult] = []
    for (lens, prompt), readouts in sorted(readouts_by.items()):
        if lens == "mix":
            continue  # identical to identity at 23-32 and learned at 13/18; covered by those
        cv += harness.cross_validate(readouts, lens, prompt, cases)

    def cv_key(r):
        prec = r.cv.precision if r.cv.precision == r.cv.precision else 0.0
        simple = {"beat-null": 0, "margin": 1, "zscore": 2}[r.rule_name]
        return (round(r.cv.f_beta(), 4), round(prec, 4), -simple)

    print("\nLeave-one-family-out CV on calibration (top 8 by CV F0.5):")
    for r in sorted(cv, key=cv_key, reverse=True)[:8]:
        print(f"  {r.lens:8} {r.prompt:3} {r.layers:9} {r.rule_name:9} | CV F0.5 {r.cv.f_beta():.2f} P {r.cv.precision:.0%} "
              f"R {r.cv.recall:.0%} | refit {r.final.label():26} | held-out F0.5 {r.test.f_beta():.2f} "
              f"P {r.test.precision:.0%} R {r.test.recall:.0%} mode {r.test.mode_accuracy:.0%}")
    best_cv = max(cv, key=cv_key)
    winner = next(c for c in everything if c.lens == best_cv.lens and c.prompt == best_cv.prompt
                  and c.layers == best_cv.layers and c.rule == best_cv.final)
    print(f"\nChosen (robust, by CV on calibration): {_row(winner)}")
    print("  held-out    ", winner.test.summary())

    # Per-family breakdown of the winner on held-out, and which cases it gets wrong.
    r = readouts_by[(winner.lens, winner.prompt)]
    layers = harness.LAYER_SETS[winner.layers]
    test = [c for c in cases if c.split == TEST]
    preds = harness.predictions(r, test, layers, winner.rule)
    fam = defaultdict(Counter)
    print("\n  held-out cases:")
    for c in test:
        fire, mode = preds[c.id]
        ok = (c.label == "either") or ((c.label == "fire") == fire and (not fire or mode == c.mode))
        fam[c.family]["ok" if ok else "wrong"] += 1
        concepts = ", ".join(f"{w} {v:.3f}" for w, v in r[c.id].concepts(layers, 4))
        mark = "·" if c.label == "either" else ("✓" if ok else "✗")
        print(f"   {mark} {c.id:28} {c.label:6} {c.mode or '':11} → {'FIRE ' + mode if fire else 'quiet':16} | {concepts}")
    print("\n  by family: " + ", ".join(f"{f} {v['ok']}/{v['ok'] + v['wrong']}" for f, v in fam.items()))

    if args.save:
        cfg = Stage2Config(rule=winner.rule, layers=layers, prompt=winner.prompt)
        CALIBRATION_PATH.write_text(json.dumps({
            "config": cfg.to_json(), "lens": winner.lens, "lens_file": LENS_FILES[winner.lens],
            "chosen_by": "leave-one-family-out CV F0.5 on the calibration half (criterion added after the first held-out look)",
            "calibration": {"f0.5": winner.cal.f_beta(), "precision": winner.cal.precision, "recall": winner.cal.recall},
            "held_out": {"f0.5": winner.test.f_beta(), "precision": winner.test.precision,
                         "recall": winner.test.recall, "mode_accuracy": winner.test.mode_accuracy},
            "saved": time.strftime("%Y-%m-%d %H:%M"),
        }, indent=2))
        print(f"\nsaved → {CALIBRATION_PATH}")
    _ = by_id


def cmd_verdicts(args) -> None:
    """Join the backend's check log with the app's verdict log (both opt-in, no screen text)."""
    from . import verdicts

    root = harness.EVAL_DIR
    print(verdicts.report(verdicts.load(root / "checks.jsonl"), verdicts.load(root / "verdicts.jsonl"),
                          include_samples=args.samples))


def cmd_cases(args) -> None:
    for c in harness.all_cases():
        if c.family == "pipeline" and not args.all:
            continue
        print(f"{c.split:11} {c.family:18} {c.label:6} {c.mode or '':11} {c.check.kind:9} {c.id}")


def main() -> None:
    p = argparse.ArgumentParser(prog="wade-eval", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--lens", default="identity", choices=["identity", "learned", "mix"])
    c.add_argument("--prompt", default="v2", choices=["v2", "v3"])
    c.add_argument("--pause", type=float, default=0.0, help="seconds between checks (heat)")
    r = sub.add_parser("report")
    r.add_argument("--save", action="store_true", help="write the chosen config to stage2-calibration.json")
    t = sub.add_parser("timing")
    t.add_argument("--lens", default=None, choices=["identity", "learned", "mix"], help="default: the calibrated lens")
    v = sub.add_parser("verdicts")
    v.add_argument("--samples", action="store_true", help="include made-up sample suggestions")
    k = sub.add_parser("cases")
    k.add_argument("--all", action="store_true")
    args = p.parse_args()
    {"collect": cmd_collect, "report": cmd_report, "timing": cmd_timing, "cases": cmd_cases,
     "verdicts": cmd_verdicts}[args.cmd](args)


if __name__ == "__main__":
    main()
