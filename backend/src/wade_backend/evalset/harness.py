"""Phase 7 evaluation harness (CLAUDE.md §9): Stage 2 precision on labeled moments, with
calibration on one half of the set and scoring on the other.

Two steps, so the model runs as little as possible:

1. ``collect``: one forward pass per case for a (lens, prompt) pair, reading *every* lens layer.
   Readouts are cached as JSON lines. This is the only step that uses the GPU.
2. ``sweep`` / ``report``: offline. For every layer subset and decision rule, fit parameters
   on the calibration split, then score the held-out split *once* with those parameters.

The selection objective is F0.5 on fire/quiet (precision weighs twice recall): a wrong
interruption costs more trust than a missed one (the Clippy lesson, §1). Held-out numbers are
never used to choose anything.
"""

from __future__ import annotations

import json
import math
from collections.abc import Iterable
from dataclasses import dataclass
from itertools import product
from pathlib import Path

from ..stage2.rules import Baseline, Rule, decide
from .cases import CAL, CASES, EITHER, FIRE, QUIET, TEST, Case

EVAL_DIR = Path.home() / "Library/Application Support/Wade/eval"

# Layer subsets considered (lens layers are 13, 18, 23, 27, 32 for Qwen3-4B).
LAYER_SETS: dict[str, tuple[int, ...] | None] = {
    "all": None, "23,27,32": (23, 27, 32), "27,32": (27, 32), "32": (32,),
    "13,18": (13, 18), "13,18,23": (13, 18, 23),
}
T_GRID = (0.0, 0.002, 0.005, 0.01, 0.02)
M_GRID = (-0.1, -0.08, -0.06, -0.05, -0.04, -0.03, -0.02, -0.015, -0.01, -0.005, 0.0, 0.005, 0.01)
K_GRID = (1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0)


# ---- metrics ----------------------------------------------------------------------------


def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    """95% Wilson interval for a proportion k/n (sensible at small n)."""
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


@dataclass
class Metrics:
    tp: int = 0
    fp: int = 0
    tn: int = 0
    fn: int = 0
    mode_ok: int = 0  # true fires with the expected mode
    either_fired: int = 0
    either: int = 0

    @property
    def n(self) -> int:
        return self.tp + self.fp + self.tn + self.fn

    @property
    def precision(self) -> float:
        return self.tp / (self.tp + self.fp) if self.tp + self.fp else float("nan")

    @property
    def recall(self) -> float:
        return self.tp / (self.tp + self.fn) if self.tp + self.fn else float("nan")

    @property
    def mode_accuracy(self) -> float:
        return self.mode_ok / self.tp if self.tp else float("nan")

    @property
    def accuracy(self) -> float:
        return (self.tp + self.tn) / self.n if self.n else float("nan")

    def f_beta(self, beta: float = 0.5) -> float:
        p, r = self.precision, self.recall
        if not (p > 0 and r > 0):
            return 0.0
        b2 = beta * beta
        return (1 + b2) * p * r / (b2 * p + r)

    def summary(self) -> str:
        def pct(x: float) -> str:
            return "  n/a" if x != x else f"{x:5.0%}"
        plo, phi = wilson(self.tp, self.tp + self.fp)
        rlo, rhi = wilson(self.tp, self.tp + self.fn)
        return (f"precision {pct(self.precision)} [{plo:.0%}–{phi:.0%}]  recall {pct(self.recall)} "
                f"[{rlo:.0%}–{rhi:.0%}]  mode {pct(self.mode_accuracy)}  "
                f"(tp {self.tp} fp {self.fp} fn {self.fn} tn {self.tn}; either fired {self.either_fired}/{self.either})")


def score(cases: Iterable[Case], predictions: dict[str, tuple[bool, str | None]]) -> Metrics:
    m = Metrics()
    for c in cases:
        fire, mode = predictions[c.id]
        if c.label == EITHER:
            m.either += 1
            m.either_fired += fire
        elif c.label == FIRE:
            if fire:
                m.tp += 1
                m.mode_ok += mode == c.mode
            else:
                m.fn += 1
        elif c.label == QUIET:
            if fire:
                m.fp += 1
            else:
                m.tn += 1
    return m


# ---- readouts -----------------------------------------------------------------------------


def all_cases() -> list[Case]:
    """The 80 hand-written cases plus the 14 Stage 1 pipeline scenarios (calibration: they were
    already seen while designing Phase 3, so they must not count as held-out)."""
    from .. import synthetic
    from ..tkg import Stage1

    extra: list[Case] = []
    for name, sc in synthetic.SCENARIOS.items():
        session = sc.build()
        checks = []
        Stage1(on_check=checks.append).replay(session.events, until=session.t)
        for i, check in enumerate(checks):
            expected = sc.stage2 if check.kind != "audit" else None
            label = FIRE if expected else QUIET
            extra.append(Case(f"pipeline:{name}:{i}", CAL, "pipeline", label, expected, check))
    return CASES + extra


def readout_path(lens: str, prompt: str, root: Path = EVAL_DIR) -> Path:
    return root / "readouts" / f"{lens}-{prompt}.jsonl"


def save_readouts(path: Path, rows: dict[str, dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for cid, r in rows.items():
            f.write(json.dumps({"case": cid, **r}, ensure_ascii=False) + "\n")


def load_readouts(path: Path):
    from ..stage2.check import Readout

    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        d = json.loads(line)
        out[d.pop("case")] = Readout.from_json(d)
    return out


def mix_readouts(learned: dict, ident: dict, early: tuple[int, ...] = (13, 18)) -> dict:
    """Learned J at the early layers, J = I at the later ones, from two cached runs."""
    from ..stage2.check import Readout

    out = {}
    for cid in learned.keys() & ident.keys():
        a, b = learned[cid], ident[cid]
        pick = lambda l: a if l in early else b  # noqa: E731
        layers = sorted(a.layer_scores)
        out[cid] = Readout({l: pick(l).layer_scores[l] for l in layers},
                           {l: pick(l).layer_concepts[l] for l in layers},
                           b.output_word, a.latency_ms, a.prompt_tokens)
    return out


# ---- sweep --------------------------------------------------------------------------------


@dataclass
class Candidate:
    lens: str
    prompt: str
    layers: str
    rule: Rule
    cal: Metrics
    test: Metrics

    def key(self) -> tuple:
        # F0.5 first; then higher precision; then mode accuracy; then simpler rule.
        simple = {"beat-null": 0, "margin": 1, "zscore": 2, "output": 3}[self.rule.name]
        prec = self.cal.precision if self.cal.precision == self.cal.precision else 0.0
        mode = self.cal.mode_accuracy if self.cal.mode_accuracy == self.cal.mode_accuracy else 0.0
        return (round(self.cal.f_beta(), 4), round(prec, 4), round(mode, 4), -simple)


def predictions(readouts: dict, cases: list[Case], layers: tuple[int, ...] | None, rule: Rule):
    out = {}
    for c in cases:
        fams, null = readouts[c.id].scores(layers)
        out[c.id] = decide(rule, fams, null, readouts[c.id].output_word)
    return out


def rules_for(readouts: dict, cal: list[Case], layers: tuple[int, ...] | None) -> list[Rule]:
    rules = [Rule("beat-null", t=t) for t in T_GRID]
    rules += [Rule("margin", t=t, m=m) for t, m in product(T_GRID, M_GRID)]
    quiet = [readouts[c.id].scores(layers)[0] for c in cal if c.label == QUIET]
    base = Baseline.fit(quiet)
    rules += [Rule("zscore", t=t, k=k, baseline=base) for t, k in product(T_GRID, K_GRID)]
    rules.append(Rule("output"))
    return rules


def sweep(readouts: dict, lens: str, prompt: str, cases: list[Case]) -> list[Candidate]:
    cal = [c for c in cases if c.split == CAL and c.id in readouts]
    test = [c for c in cases if c.split == TEST and c.id in readouts]
    out = []
    available = set(next(iter(readouts.values())).layer_scores)
    for lname, layers in LAYER_SETS.items():
        if layers is not None and not set(layers) <= available:
            continue
        for rule in rules_for(readouts, cal, layers):
            out.append(Candidate(lens, prompt, lname, rule,
                                 score(cal, predictions(readouts, cal, layers, rule)),
                                 score(test, predictions(readouts, test, layers, rule))))
    return out


def best(cands: list[Candidate], **where) -> Candidate:
    pool = [c for c in cands if all(getattr(c, k) == v if k != "rule_name" else c.rule.name == v
                                    for k, v in where.items())]
    return max(pool, key=Candidate.key)


# ---- leave-one-family-out cross-validation (calibration half only) --------------------------


def _grid(name: str, readouts: dict, train: list[Case], layers) -> list[Rule]:
    if name == "beat-null":
        return [Rule("beat-null", t=t) for t in T_GRID]
    if name == "margin":
        return [Rule("margin", t=t, m=m) for t, m in product(T_GRID, M_GRID)]
    if name == "zscore":
        base = Baseline.fit([readouts[c.id].scores(layers)[0] for c in train if c.label == QUIET])
        return [Rule("zscore", t=t, k=k, baseline=base) for t, k in product(T_GRID, K_GRID)]
    return [Rule("output")]


def fit(readouts: dict, train: list[Case], layers, name: str) -> Rule:
    """Best parameters of one rule type on `train` (same objective as the sweep)."""
    def key(rule):
        m = score(train, predictions(readouts, train, layers, rule))
        prec = m.precision if m.precision == m.precision else 0.0
        return (round(m.f_beta(), 4), round(prec, 4))
    return max(_grid(name, readouts, train, layers), key=key)


@dataclass
class CVResult:
    lens: str
    prompt: str
    layers: str
    rule_name: str
    cv: Metrics  # out-of-family predictions pooled over folds
    final: Rule  # refit on the whole calibration half
    test: Metrics  # the final rule on held-out (reported, never used to choose)


def cross_validate(readouts: dict, lens: str, prompt: str, cases: list[Case],
                   rule_names=("beat-null", "margin", "zscore")) -> list[CVResult]:
    cal = [c for c in cases if c.split == CAL and c.id in readouts]
    test = [c for c in cases if c.split == TEST and c.id in readouts]
    families = sorted({c.family for c in cal})
    available = set(next(iter(readouts.values())).layer_scores)
    out = []
    for lname, layers in LAYER_SETS.items():
        if layers is not None and not set(layers) <= available:
            continue
        for name in rule_names:
            pooled: dict[str, tuple[bool, str | None]] = {}
            for fam in families:
                train = [c for c in cal if c.family != fam]
                held = [c for c in cal if c.family == fam]
                rule = fit(readouts, train, layers, name)
                pooled |= predictions(readouts, held, layers, rule)
            final = fit(readouts, cal, layers, name)
            out.append(CVResult(lens, prompt, lname, name, score(cal, pooled), final,
                                score(test, predictions(readouts, test, layers, final))))
    return out
