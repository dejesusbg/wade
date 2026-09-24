"""`wade-stage2`: build and validate the J-lens, and evaluate Stage 2 on the synthetic scenarios.

    uv run wade-stage2 build [--prompts N] [--batch B]   # precompute J_ℓ (one-time, slow)
    uv run wade-stage2 validate                          # J-lens vs logit lens, held-out text
    uv run wade-stage2 eval [--threshold T]              # scenarios → Stage 2 → table
"""

from __future__ import annotations

import argparse
import statistics
import time
from dataclasses import replace

from .. import synthetic
from ..tkg import CheckRequest, Stage1
from . import corpus
from .jlens import DEFAULT_PATH, JLens, build, validate
from .model import DEFAULT_REPO, LensModel


def _checks_for(name: str) -> list[CheckRequest]:
    sc = synthetic.SCENARIOS[name]
    session = sc.build()
    checks: list[CheckRequest] = []
    Stage1(on_check=checks.append).replay(session.events, until=session.t)
    return checks


def cmd_build(args) -> None:
    lm = LensModel(args.repo)
    layers = lm.mid_layers(args.layers)
    print(f"{lm.repo}: {lm.n_layers} layers, d_model {lm.d_model}; J-lens layers {layers}")
    t0 = time.time()
    jl = build(lm, corpus.CALIBRATION[: args.prompts], layers, batch=args.batch)
    jl.save(args.out)
    print(f"saved {args.out} in {(time.time() - t0) / 60:.1f} min")
    _print_validation(validate(lm, jl, corpus.VALIDATION))


def cmd_validate(args) -> None:
    lm = LensModel(args.repo)
    _print_validation(validate(lm, JLens.load(args.lens), corpus.VALIDATION))


def _print_validation(v: dict) -> None:
    print(f"\ntop-5 agreement with the model's own next token ({v.pop('positions')} held-out positions):")
    print("layer   J-lens   logit lens")
    for layer, r in v.items():
        print(f"{layer:5}   {r['jlens']:6.1%}   {r['logit']:6.1%}")


def cmd_eval(args) -> None:
    from .check import Stage2, Stage2Config

    stage2 = Stage2.load(args.repo, args.lens, Stage2Config(threshold=args.threshold))
    if stage2.split_anchors:
        print(f"note: anchors that aren't single tokens (can't be read directly): {stage2.split_anchors}")
    stage2.evaluate(_checks_for("repo_page")[0])  # warm-up (compile, caches)

    rows, latencies, agree = [], [], 0
    for name, sc in synthetic.SCENARIOS.items():
        for check in _checks_for(name):
            r = stage2.evaluate(check)
            latencies.append(r.latency_ms)
            expected = sc.stage2 if check.kind != "audit" else None
            got = r.mode
            ok = got == expected
            agree += ok
            rows.append((name, check.kind, expected or "quiet", got or "quiet", ok, r))
    print(f"\n{'scenario':22} {'kind':9} {'expect':11} {'got':11}   concepts (J-space)                      | says")
    for name, kind, exp, got, ok, r in rows:
        concepts = ", ".join(f"{w} {c:.3f}" for w, c in r.concepts[:4])
        print(f"{name:22} {kind:9} {exp:11} {got:11} {'✓' if ok else '✗'} {concepts[:48]:48} | {r.output_word}")
        if args.verbose:
            best = max(r.family_scores, key=r.family_scores.get)
            print(f"{'':22} families: best {best} {r.family_scores[best]:.4f}, null {r.null_score:.4f}")
    lat = sorted(latencies)
    p95 = lat[max(0, int(round(0.95 * len(lat))) - 1)]
    print(f"\nagreement with expected mode: {agree}/{len(rows)}; latency median "
          f"{statistics.median(lat):.0f} ms, p95 {p95:.0f} ms, max {lat[-1]:.0f} ms "
          f"(threshold {args.threshold})")


def main() -> None:
    parser = argparse.ArgumentParser(prog="wade-stage2", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--lens", default=DEFAULT_PATH)
    sub = parser.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--prompts", type=int, default=len(corpus.CALIBRATION))
    b.add_argument("--layers", type=int, default=5)
    b.add_argument("--batch", type=int, default=32)
    b.add_argument("--out", default=DEFAULT_PATH)
    sub.add_parser("validate")
    e = sub.add_parser("eval")
    e.add_argument("--threshold", type=float, default=0.02)
    e.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    {"build": cmd_build, "validate": cmd_validate, "eval": cmd_eval}[args.cmd](args)


if __name__ == "__main__":
    main()
