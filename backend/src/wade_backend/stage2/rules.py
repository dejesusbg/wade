"""Stage 2 decision rules: from a J-space readout to fire / quiet and a mode (CLAUDE.md §5.4).

Pure functions over the numbers a readout holds, so Phase 7 can sweep and calibrate them
offline against cached readouts, and the backend applies the chosen one at run time.

Rules:
- ``beat-null`` (the Phase 3 rule): the best anchor family clears ``t`` *and* beats the null
  family ("nothing", "none", …).
- ``margin``: best family clears ``t`` and best − null ≥ ``m``. ``m`` may be negative: the prompt
  names "nothing" as an answer, so the null family starts ahead on every check.
- ``zscore``: each family measured against its own level on *quiet* calibration cases:
  z_f = (s_f − μ_f) / σ_f. Fire when the best z clears ``k`` (and the raw score clears ``t``).
  Asks "is this family unusually engaged here?" rather than "is it engaged at all?", which
  discounts concepts the task framing always lights up.
- ``output`` (a control, not a J-space rule): fire when the model's own next word belongs to
  an anchor family. It tells whether reading J-space adds anything over asking the model.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from . import anchors


@dataclass(frozen=True)
class Baseline:
    """Per-family mean and spread on quiet calibration cases (for ``zscore``)."""
    mean: dict[str, float]
    std: dict[str, float]
    min_std: float = 0.002  # a family that's always ~0 on quiet cases shouldn't give infinite z

    def z(self, family: str, score: float) -> float:
        return (score - self.mean.get(family, 0.0)) / max(self.std.get(family, 0.0), self.min_std)

    @classmethod
    def fit(cls, family_scores: list[dict[str, float]], min_std: float = 0.002) -> Baseline:
        fams = sorted({f for s in family_scores for f in s})
        mean, std = {}, {}
        for f in fams:
            xs = [s.get(f, 0.0) for s in family_scores]
            m = sum(xs) / len(xs) if xs else 0.0
            v = sum((x - m) ** 2 for x in xs) / (len(xs) - 1) if len(xs) > 1 else 0.0
            mean[f], std[f] = m, math.sqrt(v)
        return cls(mean, std, min_std)

    def to_json(self) -> dict:
        return {"mean": self.mean, "std": self.std, "min_std": self.min_std}

    @classmethod
    def from_json(cls, d: dict) -> Baseline:
        return cls(dict(d["mean"]), dict(d["std"]), float(d.get("min_std", 0.002)))


@dataclass(frozen=True)
class Rule:
    name: str  # beat-null | margin | zscore | output
    t: float = 0.005
    m: float = 0.0
    k: float = 2.0
    baseline: Baseline | None = field(default=None, compare=False)

    def label(self) -> str:
        return {"beat-null": f"beat-null t={self.t:g}",
                "margin": f"margin t={self.t:g} m={self.m:+g}",
                "zscore": f"zscore k={self.k:g} t={self.t:g}",
                "output": "output word (control)"}[self.name]

    def to_json(self) -> dict:
        d = {"name": self.name, "t": self.t, "m": self.m, "k": self.k}
        if self.baseline:
            d["baseline"] = self.baseline.to_json()
        return d

    @classmethod
    def from_json(cls, d: dict) -> Rule:
        b = d.get("baseline")
        return cls(d["name"], float(d.get("t", 0.005)), float(d.get("m", 0.0)), float(d.get("k", 2.0)),
                   Baseline.from_json(b) if b else None)


PHASE3 = Rule("beat-null", t=0.005)


def decide(rule: Rule, family_scores: dict[str, float], null_score: float,
           output_word: str = "") -> tuple[bool, str | None]:
    """(fire, mode). ``mode`` is the winning family when firing, else None."""
    if not family_scores:
        return False, None
    if rule.name == "output":
        fam = anchors.family_of(anchors.concept(anchors.normalize(output_word) or output_word.lower()))
        return (fam not in (None, "null")), (fam if fam not in (None, "null") else None)
    best = max(family_scores, key=family_scores.__getitem__)
    s = family_scores[best]
    if rule.name == "beat-null":
        fire = s >= rule.t and s > null_score
    elif rule.name == "margin":
        fire = s >= rule.t and s - null_score >= rule.m
    elif rule.name == "zscore":
        if rule.baseline is None:
            raise ValueError("zscore rule needs a baseline")
        zs = {f: rule.baseline.z(f, v) for f, v in family_scores.items()}
        best = max(zs, key=zs.__getitem__)
        fire = zs[best] >= rule.k and family_scores[best] >= rule.t
    else:
        raise ValueError(f"unknown rule {rule.name}")
    return fire, (best if fire else None)
