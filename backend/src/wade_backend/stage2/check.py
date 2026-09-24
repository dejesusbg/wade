"""Stage 2 evaluation of one Stage 1 CheckRequest (CLAUDE.md §5.4).

  1. Build the prompt from the check's context (a) and digest (b).
  2. One forward pass (no generation); capture h_ℓ at the workspace layers, last few positions.
  3. Decompose each into its J-space: ≤k nonnegative J-lens vectors (concepts + weights).
  4. Average concept weights over layers × positions; score each anchor family and the null family.
  5. Fire when the best family clears `threshold` *and* beats the null family. The winning family
     names the mode; the top concepts are the explanation, read out rather than generated.

The threshold is a calibration constant, not a law: see `wade-stage2 eval` and Phase 7.
"""

from __future__ import annotations

import time
from collections import defaultdict
from dataclasses import dataclass, field

import mlx.core as mx

from ..tkg import CheckRequest
from . import anchors, prompt
from .jlens import DEFAULT_PATH, JLens
from .model import DEFAULT_REPO, LensModel


@dataclass(frozen=True)
class Stage2Config:
    threshold: float = 0.02  # min family weight (share of residual norm); calibrated by `eval`
    k: int = 16  # J-lens vectors per decomposition (paper: ≤25, 16 for verbal report)
    positions: int = 6  # last prompt positions read
    top_concepts: int = 8


@dataclass
class Stage2Result:
    fire: bool
    mode: str | None
    family_scores: dict[str, float]
    null_score: float
    concepts: list[tuple[str, float]]  # the J-space readout: explanation material
    output_word: str  # what the model would actually say next (for comparison only)
    latency_ms: float
    prompt_tokens: int
    breakdown: dict = field(default_factory=dict)


class Stage2:
    def __init__(self, lm: LensModel, jl: JLens, cfg: Stage2Config = Stage2Config()) -> None:
        self.lm, self.jl, self.cfg = lm, jl, cfg
        self._word_cache: dict[int, str] = {}
        self.split_anchors = anchors.check_single_tokens(lm.encode)

    @classmethod
    def load(cls, repo: str = DEFAULT_REPO, lens_path=DEFAULT_PATH, cfg: Stage2Config = Stage2Config()) -> Stage2:
        return cls(LensModel(repo), JLens.load(lens_path), cfg)

    def word(self, token_id: int) -> str:
        if token_id not in self._word_cache:
            self._word_cache[token_id] = anchors.normalize(self.lm.tokenizer.decode([token_id]))
        return self._word_cache[token_id]

    def evaluate(self, check: CheckRequest) -> Stage2Result:
        t0 = time.perf_counter()
        text = self.lm.chat_prompt(prompt.SYSTEM, prompt.user_message(check))
        ids = self.lm.encode(text)
        caps, hf = self.lm.forward(mx.array([ids]), self.jl.layers)
        output_id = int(mx.argmax(self.lm.head(hf[0, -1])))

        P = min(self.cfg.positions, len(ids) - 1)
        weights: dict[str, float] = defaultdict(float)
        per_layer: dict[int, list[tuple[str, float]]] = {}
        for layer in self.jl.layers:
            h = caps[layer][0, -P:]
            layer_w: dict[str, float] = defaultdict(float)
            for tokens, coefs in self.jl.decompose(self.lm, layer, h, k=self.cfg.k):
                for t, c in zip(tokens, coefs):
                    w = self.word(t)
                    if w:
                        layer_w[w] += c / P
            for w, c in layer_w.items():
                weights[w] += c / len(self.jl.layers)
            per_layer[layer] = sorted(layer_w.items(), key=lambda x: -x[1])[:5]

        family_scores = {fam: sum(weights.get(w, 0.0) for w in words) for fam, words in anchors.FAMILIES.items()}
        null_score = sum(weights.get(w, 0.0) for w in anchors.NULL_FAMILY)
        best = max(family_scores, key=family_scores.__getitem__)
        fire = family_scores[best] >= self.cfg.threshold and family_scores[best] > null_score

        concepts = sorted(weights.items(), key=lambda x: -x[1])[: self.cfg.top_concepts]
        return Stage2Result(
            fire=fire,
            mode=best if fire else None,
            family_scores={f: round(s, 4) for f, s in family_scores.items()},
            null_score=round(null_score, 4),
            concepts=[(w, round(c, 4)) for w, c in concepts],
            output_word=anchors.normalize(self.lm.tokenizer.decode([output_id])) or self.lm.tokenizer.decode([output_id]),
            latency_ms=(time.perf_counter() - t0) * 1000,
            prompt_tokens=len(ids),
            breakdown={"per_layer": per_layer},
        )
