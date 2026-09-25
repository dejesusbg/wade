"""Stage 2 evaluation of one Stage 1 CheckRequest (CLAUDE.md §5.4).

  1. Build the prompt from the check's context (a) and digest (b).
  2. One forward pass (no generation); capture h_ℓ at the workspace layers, last few positions.
  3. Decompose each into its J-space: ≤k nonnegative J-lens vectors (concepts + weights).
  4. Per layer, sum concept weights into each anchor family and the null family (`read`).
  5. Average over the configured layers and apply the decision rule (`rules.decide`). The
     winning family names the mode; the top concepts are the explanation, read out rather
     than generated.

`read` keeps every lens layer's scores separately, so Phase 7 can choose layers, rule and
thresholds offline from cached readouts (`wade-eval`). The rule in use is a calibrated
choice, loaded from `stage2-calibration.json` when present (see README, Phase 7).
"""

from __future__ import annotations

import json
import time
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import mlx.core as mx

from ..tkg import CheckRequest
from . import anchors, prompt
from .jlens import DEFAULT_PATH, JLens
from .model import DEFAULT_REPO, LensModel
from .rules import PHASE3, Rule, decide

CALIBRATION_PATH = DEFAULT_PATH.parent / "stage2-calibration.json"


@dataclass(frozen=True)
class Stage2Config:
    rule: Rule = PHASE3
    k: int = 16  # J-lens vectors per decomposition (paper: ≤25, 16 for verbal report)
    positions: int = 1  # last prompt positions read (1 = where the answer is poised)
    # Layers the decision uses. None: all lens layers. With J = I, only layers where the lens is
    # validated to track the model (top-5 agreement ≥ 20%: 23, 27, 32) carry signal.
    layers: tuple[int, ...] | None = (23, 27, 32)
    prompt: str = prompt.DEFAULT_VARIANT
    top_concepts: int = 8

    def to_json(self) -> dict:
        return {"rule": self.rule.to_json(), "layers": list(self.layers) if self.layers else None,
                "prompt": self.prompt, "positions": self.positions, "k": self.k}

    @classmethod
    def from_json(cls, d: dict) -> Stage2Config:
        return cls(rule=Rule.from_json(d["rule"]), layers=tuple(d["layers"]) if d.get("layers") else None,
                   prompt=d.get("prompt", prompt.DEFAULT_VARIANT), positions=int(d.get("positions", 1)),
                   k=int(d.get("k", 16)))

    @staticmethod
    def calibrated_lens(path: Path = CALIBRATION_PATH, default: Path = DEFAULT_PATH) -> Path:
        """The lens file the calibration was made with (J = I unless it says otherwise)."""
        if path.exists():
            name = json.loads(path.read_text()).get("lens_file")
            if name:
                return default.parent / name
        return default

    @classmethod
    def calibrated(cls, path: Path = CALIBRATION_PATH) -> Stage2Config:
        """The calibrated config if one was saved, else the Phase 3 default."""
        if path.exists():
            return cls.from_json(json.loads(path.read_text())["config"])
        return cls()


@dataclass
class Readout:
    """Everything a decision needs, per lens layer, from one forward pass."""
    layer_scores: dict[int, dict[str, float]]  # layer → family → score, plus "null"
    layer_concepts: dict[int, dict[str, float]]  # layer → concept → weight (top 40)
    output_word: str  # what the model would actually say next
    latency_ms: float
    prompt_tokens: int

    def scores(self, layers: tuple[int, ...] | None) -> tuple[dict[str, float], float]:
        """(family scores, null score) averaged over `layers` (None: all)."""
        use = [l for l in self.layer_scores if layers is None or l in layers]
        fams: dict[str, float] = defaultdict(float)
        for l in use:
            for f, v in self.layer_scores[l].items():
                fams[f] += v / len(use)
        null = fams.pop("null", 0.0)
        return {f: fams.get(f, 0.0) for f in anchors.FAMILIES}, null

    def concepts(self, layers: tuple[int, ...] | None, top: int = 8) -> list[tuple[str, float]]:
        use = [l for l in self.layer_concepts if layers is None or l in layers]
        w: dict[str, float] = defaultdict(float)
        for l in use:
            for c, v in self.layer_concepts[l].items():
                w[c] += v / len(use)
        return sorted(w.items(), key=lambda x: -x[1])[:top]

    def to_json(self) -> dict:
        return {"layer_scores": {str(l): s for l, s in self.layer_scores.items()},
                "layer_concepts": {str(l): c for l, c in self.layer_concepts.items()},
                "output_word": self.output_word, "latency_ms": self.latency_ms,
                "prompt_tokens": self.prompt_tokens}

    @classmethod
    def from_json(cls, d: dict) -> Readout:
        return cls({int(l): s for l, s in d["layer_scores"].items()},
                   {int(l): c for l, c in d["layer_concepts"].items()},
                   d["output_word"], d["latency_ms"], d["prompt_tokens"])


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
    def load(cls, repo: str = DEFAULT_REPO, lens_path=None, cfg: Stage2Config | None = None) -> Stage2:
        """Model + lens + decision rule. Defaults to the saved calibration (lens and rule together:
        a rule calibrated on one lens means nothing on another)."""
        if cfg is None and lens_path is None:
            cfg, lens_path = Stage2Config.calibrated(), Stage2Config.calibrated_lens()
        return cls(LensModel(repo), JLens.load(lens_path or DEFAULT_PATH), cfg or Stage2Config())

    def word(self, token_id: int) -> str:
        if token_id not in self._word_cache:
            self._word_cache[token_id] = anchors.normalize(self.lm.tokenizer.decode([token_id]))
        return self._word_cache[token_id]

    def read(self, check: CheckRequest, layers: tuple[int, ...] | None = ...) -> Readout:
        """One forward pass; J-space at each requested lens layer (default: the config's)."""
        t0 = time.perf_counter()
        if layers is ...:
            layers = self.cfg.layers
        text = self.lm.chat_prompt(prompt.SYSTEM, prompt.user_message(check, self.cfg.prompt))
        ids = self.lm.encode(text)
        caps, hf = self.lm.forward(mx.array([ids]), self.jl.layers)
        output_id = int(mx.argmax(self.lm.head(hf[0, -1])))

        P = min(self.cfg.positions, len(ids) - 1)
        layer_scores: dict[int, dict[str, float]] = {}
        layer_concepts: dict[int, dict[str, float]] = {}
        for layer in (l for l in self.jl.layers if layers is None or l in layers):
            h = caps[layer][0, -P:]
            w: dict[str, float] = defaultdict(float)  # by concept (word forms merged)
            for tokens, coefs in self.jl.decompose(self.lm, layer, h, k=self.cfg.k):
                for t, c in zip(tokens, coefs):
                    word = self.word(t)
                    if word:
                        w[anchors.concept(word)] += c / P
            scores = {f: 0.0 for f in anchors.FAMILIES} | {"null": 0.0}
            for concept, c in w.items():
                fam = anchors.family_of(concept)
                if fam:
                    scores[fam] += c
            layer_scores[layer] = {f: round(v, 6) for f, v in scores.items()}
            layer_concepts[layer] = {c: round(v, 6) for c, v in sorted(w.items(), key=lambda x: -x[1])[:40]}
        word = self.lm.tokenizer.decode([output_id])
        return Readout(layer_scores, layer_concepts, anchors.normalize(word) or word,
                       (time.perf_counter() - t0) * 1000, len(ids))

    def evaluate(self, check: CheckRequest) -> Stage2Result:
        r = self.read(check)
        fams, null = r.scores(self.cfg.layers)
        fire, mode = decide(self.cfg.rule, fams, null, r.output_word)
        return Stage2Result(
            fire=fire, mode=mode,
            family_scores={f: round(s, 4) for f, s in fams.items()},
            null_score=round(null, 4),
            concepts=[(w, round(c, 4)) for w, c in r.concepts(self.cfg.layers, self.cfg.top_concepts)],
            output_word=r.output_word, latency_ms=r.latency_ms, prompt_tokens=r.prompt_tokens,
            breakdown={"per_layer": {l: sorted(c.items(), key=lambda x: -x[1])[:5] for l, c in r.layer_concepts.items()}},
        )
