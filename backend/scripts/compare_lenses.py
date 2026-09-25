"""Compare Stage 2 readouts on the synthetic scenarios: J = I (default), learned J, early layers
only, and a per-layer mix. Needs both lens files (`build --identity` and the overnight build).

    uv run python scripts/compare_lenses.py
"""
import statistics
from wade_backend import synthetic
from wade_backend.tkg import Stage1
from wade_backend.stage2.check import Stage2, Stage2Config
from wade_backend.stage2.jlens import JLens, identity
from wade_backend.stage2.model import LensModel
from pathlib import Path

W = Path.home() / "Library/Application Support/Wade"
lm = LensModel()
learned = JLens.load(W / "jlens-learned.npz")
ident = JLens.load(W / "jlens-qwen3-4b.npz")
mixed = JLens(learned.layers,
              {l: (learned.J[l] if l in (13, 18) else ident.J[l]) for l in learned.layers},
              {l: (learned.atom_norms[l] if l in (13, 18) else ident.atom_norms[l]) for l in learned.layers},
              learned.rms_ref, {"variant": "mix: learned J at 13,18; J=I at 23,27,32"})

checks = []
for name, sc in synthetic.SCENARIOS.items():
    s = sc.build(); cs = []
    Stage1(on_check=cs.append).replay(s.events, until=s.t)
    for c in cs:
        checks.append((name, c, sc.stage2 if c.kind != "audit" else None))

variants = {
    "J=I 23,27,32 (current)": (ident, (23, 27, 32)),
    "A learned, all layers": (learned, None),
    "B learned, 13,18": (learned, (13, 18)),
    "C mix, all layers": (mixed, None),
}
for label, (jl, layers) in variants.items():
    st = Stage2(lm, jl, Stage2Config(layers=layers))
    st.evaluate(checks[0][1])  # warm-up
    fire_ok = mode_ok = 0; lat = []; rows = []
    for name, c, exp in checks:
        r = st.evaluate(c); lat.append(r.latency_ms)
        fire_ok += (r.mode is None) == (exp is None); mode_ok += r.mode == exp
        rows.append(f"  {name:22} {c.kind:9} {exp or 'quiet':11} {r.mode or 'quiet':11} "
                    f"{', '.join(f'{w} {v:.3f}' for w, v in r.concepts[:4])}")
    print(f"\n=== {label}: fire/quiet {fire_ok}/{len(checks)}, mode {mode_ok}/{len(checks)}, "
          f"median {statistics.median(lat):.0f} ms")
    print("\n".join(rows))
