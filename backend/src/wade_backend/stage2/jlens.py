"""The Jacobian lens (Gurnee, Sofroniew, Pearce et al., "Verbalizable Representations Form a
Global Workspace in Language Models", Transformer Circuits, July 2026).

Definitions implemented here, per the paper:

  J_ℓ        = E_{prompt, t, t′≥t} [ ∂h_final,t′ / ∂h_ℓ,t ]           (d × d per layer)
  lens(h_ℓ)  = softmax(W_U · norm(J_ℓ h_ℓ))
  J-lens vector for token v = row v of W_U·diag(g)·J_ℓ  (a direction in layer-ℓ residual space)

h_final is the last block's output *before* the final RMSNorm, and `norm` is the model's own
final RMSNorm (with its gain g). This is the only reading under which J = I gives exactly the
logit lens, as the paper states. (Differentiating the post-norm residual instead makes J
annihilate h's own direction, because RMSNorm is scale-invariant; we measured that version losing
to the logit lens at every layer.) J-lens vectors fold in g, the effective direction the lens
scores for each token.
  J-space    = sparse nonnegative combination of ≤k J-lens vectors reconstructing h_ℓ

What is exact and what is approximated (CLAUDE.md §7 requires saying so):

  * The t′≥t average is computed exactly: one backward pass with the same cotangent at every
    output position yields Σ_{t′≥t} ∂h_final,t′/∂h_ℓ,t at every source position t at once, and
    all captured layers come out of the same pass.
  * APPROXIMATION: the corpus. The paper averages over 1,000 pretraining-like prompts; we use a
    small hand-assembled corpus (`corpus.py`, a few dozen short prompts). The paper reports its
    results are robust to the number of averaging contexts; `validate()` measures how well
    ours works (J-lens vs logit lens top-k agreement), so the approximation is checked, not assumed.
  * Source position 0 is excluded (attention-sink token with outlier activations).
  * Pairs (t, t′) are weighted uniformly within a prompt; prompts are weighted equally.
  * The J-space decomposition uses nonnegative orthogonal matching pursuit (exact NNLS on the
    selected atoms), the exact-least-squares counterpart of the paper's gradient pursuit.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

import mlx.core as mx
import numpy as np

from .model import LensModel

DEFAULT_PATH = Path.home() / "Library" / "Application Support" / "Wade" / "jlens-qwen3-4b.npz"


@dataclass
class JLens:
    layers: list[int]
    J: dict[int, mx.array]  # (d, d) float32: maps h_ℓ → h_final space
    atom_norms: dict[int, mx.array]  # (vocab,) ‖row v of W_U·J_ℓ‖
    rms_ref: float  # typical RMS of real (pre-norm) h_final vectors; informational
    meta: dict

    # ---- persistence ------------------------------------------------------------------

    def save(self, path: Path | str = DEFAULT_PATH) -> None:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        arrays = {"layers": np.array(self.layers), "rms_ref": np.array(self.rms_ref)}
        for l in self.layers:
            arrays[f"J_{l}"] = np.array(self.J[l].astype(mx.float16))
            arrays[f"norms_{l}"] = np.array(self.atom_norms[l])
        arrays["meta"] = np.array(repr(self.meta))
        np.savez(path, **arrays)

    @classmethod
    def load(cls, path: Path | str = DEFAULT_PATH) -> JLens:
        data = np.load(Path(path))
        layers = [int(l) for l in data["layers"]]
        return cls(
            layers=layers,
            J={l: mx.array(data[f"J_{l}"]).astype(mx.float32) for l in layers},
            atom_norms={l: mx.array(data[f"norms_{l}"]) for l in layers},
            rms_ref=float(data["rms_ref"]),
            meta=eval(str(data["meta"])),  # our own repr of a plain dict
        )

    # ---- readout ----------------------------------------------------------------------

    def project(self, lm: LensModel, layer: int, h: mx.array) -> mx.array:
        """norm(J_ℓ h): J_ℓ into the pre-norm final residual, then the model's final RMSNorm."""
        v = h.astype(mx.float32) @ self.J[layer].T
        return lm.inner.norm(v.astype(lm.dtype))

    def lens(self, lm: LensModel, layer: int, h: mx.array) -> mx.array:
        """Token distribution the model is poised to verbalize from h_ℓ. Returns (..., vocab)."""
        return mx.softmax(lm.head(self.project(lm, layer, h)).astype(mx.float32), axis=-1)

    def decompose(self, lm: LensModel, layer: int, h: mx.array, k: int = 16) -> list[tuple[list[int], list[float]]]:
        """J-space of each row of h (n, d): up to k (token_id, coefficient) pairs whose J-lens
        vectors, combined nonnegatively, best reconstruct h. Coefficients are scaled by the atom
        norm and divided by ‖h‖, so they read as each concept's share of the residual."""
        J = self.J[layer]
        norms = self.atom_norms[layer]
        target = np.array(h.astype(mx.float32))
        n = target.shape[0]
        residual = target.copy()
        chosen: list[list[int]] = [[] for _ in range(n)]
        coefs: list[np.ndarray] = [np.zeros(0) for _ in range(n)]
        atoms: list[np.ndarray] = [np.zeros((0, target.shape[1])) for _ in range(n)]
        active = np.ones(n, dtype=bool)
        for _ in range(k):
            if not active.any():
                break
            # Correlation of each residual with every normalized J-lens vector: W_U g⊙(J r) / ‖atom‖.
            corr = lm.head(((mx.array(residual) @ J.T) * _gain(lm)).astype(lm.dtype)).astype(mx.float32) / norms
            corr = np.array(corr)
            for i in range(n):
                if not active[i]:
                    continue
                if chosen[i]:
                    corr[i, chosen[i]] = -np.inf
                v = int(np.argmax(corr[i]))
                if corr[i, v] <= 0:
                    active[i] = False
                    continue
                chosen[i].append(v)
                atom = self._atoms(lm, layer, [v])[0]
                atoms[i] = np.vstack([atoms[i], atom])
                coefs[i] = _nnls(atoms[i].T, target[i])
                residual[i] = target[i] - atoms[i].T @ coefs[i]
        out = []
        for i in range(n):
            hn = float(np.linalg.norm(target[i])) or 1.0
            weights = [float(c * np.linalg.norm(a)) / hn for c, a in zip(coefs[i], atoms[i])]
            keep = [(t, w) for t, w in zip(chosen[i], weights) if w > 0]
            out.append(([t for t, _ in keep], [w for _, w in keep]))
        return out

    def _atoms(self, lm: LensModel, layer: int, token_ids: list[int]) -> np.ndarray:
        """J-lens vectors (rows of W_U·diag(g)·J_ℓ) for the given tokens, shape (n, d)."""
        rows = lm.unembedding_rows(mx.array(token_ids)).astype(mx.float32) * _gain(lm)
        return np.array(rows @ self.J[layer])


def _gain(lm: LensModel) -> mx.array:
    """The final RMSNorm's learned gain g (ones if the model has none)."""
    weight = getattr(lm.inner.norm, "weight", None)
    return mx.ones((lm.d_model,)) if weight is None else weight.astype(mx.float32)


def _nnls(A: np.ndarray, b: np.ndarray, iters: int = 200) -> np.ndarray:
    """Nonnegative least squares min‖Ax − b‖, x ≥ 0, for a handful of columns (projected
    gradient on the normal equations; small m makes this cheap and stable)."""
    AtA = A.T @ A
    Atb = A.T @ b
    x = np.maximum(np.linalg.lstsq(A, b, rcond=None)[0], 0)
    step = 1.0 / (np.linalg.eigvalsh(AtA).max() + 1e-9)
    for _ in range(iters):
        x = np.maximum(x - step * (AtA @ x - Atb), 0)
    return x


# ---- precompute ---------------------------------------------------------------------------


def build(
    lm: LensModel,
    prompts: Sequence[str],
    layers: Sequence[int] | None = None,
    batch: int = 32,
    max_tokens: int = 48,
    progress: Callable[[str], None] = print,
    checkpoint: Path | None = None,
    cooldown_s: float = 0.0,
    long_cooldown_s: float = 0.0,
    long_every: int = 0,
) -> JLens:
    """Estimate J_ℓ for the given layers from `prompts` (see module docstring).

    `checkpoint`: saved after every prompt and resumed from if present (same layers), so a long
    build survives interruption. `cooldown_s`: pause after each prompt to limit sustained heat;
    every `long_every` prompts the pause is `long_cooldown_s` instead (Pomodoro-style)."""
    layers = list(layers or lm.mid_layers())
    d = lm.d_model
    acc = {l: np.zeros((d, d), dtype=np.float64) for l in layers}
    rms_samples: list[float] = []
    used = 0
    done = 0
    if checkpoint and checkpoint.exists():
        ck = np.load(checkpoint)
        if [int(x) for x in ck["layers"]] == layers:
            acc = {l: ck[f"acc_{l}"].astype(np.float64) for l in layers}
            rms_samples = list(ck["rms"])
            used, done = int(ck["used"]), int(ck["done"])
            progress(f"resuming from checkpoint: {done} prompts done")
    t0 = time.time()
    fresh = 0

    for p_idx, prompt in enumerate(prompts):
        if p_idx < done:
            continue
        ids = lm.encode(prompt)[:max_tokens]
        T = len(ids)
        if T < 4:
            continue
        tokens = mx.array([ids])
        pairs = sum(T - t for t in range(1, T))  # (t, t′≥t) pairs, excluding source t=0

        caps, _ = lm.forward(tokens, [lm.n_layers - 1])  # last block output = pre-norm h_final
        hf32 = caps[lm.n_layers - 1].astype(mx.float32)
        rms_samples.append(float(mx.mean(mx.sqrt(mx.mean(hf32 * hf32, axis=-1)))))

        # Blocks below the first probed layer need no gradient: run them once, not per batch row.
        h_first, mask = lm.prefix(tokens, layers[0])
        mx.eval(h_first)

        for start in range(0, d, batch):
            B = min(batch, d - start)
            h_b = mx.repeat(h_first, B, axis=0)
            zeros = [mx.zeros((B, T, d), dtype=lm.dtype) for _ in layers]

            def f(*deltas: mx.array) -> mx.array:
                return lm.suffix(h_b, mask, layers[0], dict(zip(layers, deltas)), prenorm=True)

            # Cotangent: output dimension (start+b) at every position, for batch row b.
            onehot = (mx.arange(d)[None, :] == (start + mx.arange(B))[:, None]).astype(lm.dtype)
            cot = mx.broadcast_to(onehot[:, None, :], (B, T, d))
            _, grads = mx.vjp(f, zeros, [cot])
            for l, g in zip(layers, grads):
                g = g.astype(mx.float32)[:, 1:, :]  # drop source t=0
                # Σ_t Σ_{t′≥t} ∂h_final,t′[i]/∂h_ℓ,t  →  mean over pairs
                rows = np.array(mx.sum(g, axis=1)) / pairs
                acc[l][start:start + B, :] += rows
            mx.clear_cache()

        used += 1
        fresh += 1
        if checkpoint:
            checkpoint.parent.mkdir(parents=True, exist_ok=True)
            tmp = checkpoint.with_suffix(".tmp.npz")
            np.savez(tmp, layers=np.array(layers), used=used, done=p_idx + 1, rms=np.array(rms_samples),
                     **{f"acc_{l}": acc[l].astype(np.float32) for l in layers})
            tmp.replace(checkpoint)
        elapsed = time.time() - t0
        progress(f"J: prompt {p_idx + 1}/{len(prompts)} ({T} tokens), {elapsed / fresh:.0f}s/prompt, "
                 f"eta {elapsed / fresh * (len(prompts) - p_idx - 1) / 60:.0f} min")
        long = long_every and (p_idx + 1) % long_every == 0
        pause = long_cooldown_s if long else cooldown_s
        if pause and p_idx + 1 < len(prompts):
            time.sleep(pause)

    J = {l: mx.array((acc[l] / used).astype(np.float32)) for l in layers}
    rms_ref = float(np.mean(rms_samples))

    progress("atom norms …")
    atom_norms = {l: _atom_norms(lm, J[l]) for l in layers}
    return JLens(layers, J, atom_norms, rms_ref,
                 meta={"repo": lm.repo, "prompts": used, "max_tokens": max_tokens,
                       "variant": "full t'>=t average, pre-norm target, source t>=1, small corpus"})


def _atom_norms(lm: LensModel, J: mx.array, chunk: int = 8192) -> mx.array:
    norms = []
    for start in range(0, lm.vocab_size, chunk):
        ids = mx.arange(start, min(start + chunk, lm.vocab_size))
        rows = (lm.unembedding_rows(ids).astype(mx.float32) * _gain(lm)) @ J
        norms.append(mx.sqrt(mx.sum(rows * rows, axis=-1)))
        mx.eval(norms[-1])
    return mx.concatenate(norms)


def identity(lm: LensModel, layers: Sequence[int] | None = None) -> JLens:
    """J_ℓ = I for every layer: the logit lens, which the paper names as the J-lens's simpler
    special case ("less accurate in early layers"). Used when a learned J isn't good enough;
    see README "Stage 2: what the lens is, honestly"."""
    layers = list(layers or lm.mid_layers())
    eye = mx.eye(lm.d_model)
    norms = _atom_norms(lm, eye)
    return JLens(layers, {l: eye for l in layers}, {l: norms for l in layers}, 0.0,
                 meta={"repo": lm.repo, "variant": "identity (logit lens, J = I)"})


# ---- validation ---------------------------------------------------------------------------


def validate(lm: LensModel, jl: JLens, prompts: Sequence[str], k: int = 5, max_tokens: int = 64) -> dict:
    """The paper's top-k agreement: how often the model's actual top-1 next token is among the
    lens's top-k at each layer, for the J-lens vs the logit lens (J = identity). If our small-
    corpus J is worth anything it should clearly beat the logit lens in the middle layers."""
    hits = {l: {"jlens": 0, "logit": 0} for l in jl.layers}
    total = 0
    for prompt in prompts:
        ids = lm.encode(prompt)[:max_tokens]
        caps, hf = lm.forward(mx.array([ids]), jl.layers)
        actual = mx.argmax(lm.head(hf)[0, 1:], axis=-1)  # skip the sink position
        n = actual.shape[0]
        total += n
        for l in jl.layers:
            h = caps[l][0, 1:]
            j_top = mx.argpartition(-lm.head(jl.project(lm, l, h)), k, axis=-1)[:, :k]
            logit_top = mx.argpartition(-lm.head(lm.inner.norm(h)), k, axis=-1)[:, :k]
            hits[l]["jlens"] += int(mx.sum(mx.any(j_top == actual[:, None], axis=-1)))
            hits[l]["logit"] += int(mx.sum(mx.any(logit_top == actual[:, None], axis=-1)))
    return {l: {m: v / total for m, v in hits[l].items()} for l in jl.layers} | {"positions": total}
