"""Stage 2 pieces that don't need the real model. The model-level check is `wade-stage2 eval`."""

import numpy as np
import pytest

from wade_backend import protocol
from wade_backend.stage2 import anchors, prompt
from wade_backend.tkg import CheckRequest

mx = pytest.importorskip("mlx.core")

from wade_backend.stage2.jlens import JLens, _nnls  # noqa: E402


class _Norm:
    """Unit-gain RMSNorm, like the model's final norm."""

    def __init__(self, d: int) -> None:
        self.weight = mx.ones((d,))

    def __call__(self, x):
        return x / mx.sqrt(mx.mean(x * x, axis=-1, keepdims=True) + 1e-6) * self.weight


class _Inner:
    def __init__(self, d: int) -> None:
        self.norm = _Norm(d)


class FakeLM:
    """A 'model' whose unembedding is a small known matrix, so decompositions are checkable."""

    dtype = mx.float32

    def __init__(self, W: np.ndarray) -> None:
        self.W = mx.array(W.astype(np.float32))
        self.d_model = W.shape[1]
        self.inner = _Inner(W.shape[1])

    def head(self, x):
        return x @ self.W.T

    def unembedding_rows(self, ids):
        return self.W[ids]


def _toy_lens(W: np.ndarray) -> JLens:
    d = W.shape[1]
    return JLens(layers=[0], J={0: mx.eye(d)}, atom_norms={0: mx.array(np.linalg.norm(W, axis=1).astype(np.float32))},
                 rms_ref=1.0, meta={})


def test_decompose_recovers_planted_concepts():
    rng = np.random.default_rng(0)
    W = rng.normal(size=(40, 16))
    h = 2.0 * W[3] + 1.0 * W[17]
    jl = _toy_lens(W)
    [(tokens, weights)] = jl.decompose(FakeLM(W), 0, mx.array(h[None, :]), k=4)
    assert set(tokens[:2]) == {3, 17}
    assert weights[tokens.index(3)] > weights[tokens.index(17)]  # the bigger component weighs more


def test_decompose_is_nonnegative_and_stops_when_nothing_helps():
    W = np.eye(8)
    jl = _toy_lens(W)
    [(tokens, weights)] = jl.decompose(FakeLM(W), 0, mx.array([[0, 0, 3, 0, 0, -5, 0, 0]], dtype=mx.float32), k=8)
    assert tokens == [2]  # the negative direction is never used
    assert all(w > 0 for w in weights)


def test_nnls():
    A = np.array([[1.0, 0.0], [0.0, 1.0], [1.0, 1.0]])
    x = _nnls(A, A @ np.array([2.0, 0.5]))
    assert np.allclose(x, [2.0, 0.5], atol=1e-4)
    assert np.all(_nnls(A, np.array([-1.0, -1.0, -2.0])) >= 0)


def test_identity_jacobian_is_the_logit_lens():
    """With J = I, lens(h) must be exactly softmax(W_U · norm(h)), as the paper states."""
    rng = np.random.default_rng(1)
    W = rng.normal(size=(12, 6))
    lm, jl = FakeLM(W), _toy_lens(W)
    h = mx.array(rng.normal(size=(2, 6)).astype(np.float32))
    expected = mx.softmax(lm.head(lm.inner.norm(h)), axis=-1)
    assert np.abs(np.array(jl.lens(lm, 0, h)) - np.array(expected)).max() < 1e-4  # GPU matmul rounding


# ---- anchors & prompt ----------------------------------------------------------------------


def test_anchor_words_are_unambiguous():
    all_words = [w for ws in anchors.FAMILIES.values() for w in ws]
    assert len(all_words) == len(set(all_words)), "a word sits in two families"
    assert not set(all_words) & set(anchors.NULL_FAMILY)
    assert all(anchors.normalize(w) == w for w in all_words + list(anchors.NULL_FAMILY))


def test_normalize():
    assert anchors.normalize(" Error,") == "error"
    assert anchors.normalize("ing") == "ing"
    assert anchors.normalize(" 42") == "" and anchors.normalize("?") == "" and anchors.normalize(" a") == ""


def test_prompt_has_context_and_digest_and_skips_missing_fields():
    check = CheckRequest("settled", 0.0, ("context_settled",), "In Chrome (github.com) for 15s.",
                         {"app": "Chrome", "url": "https://github.com/a/b", "excerpt": "Clone HTTPS"})
    text = prompt.user_message(check)
    assert "- App: Chrome" in text and "https://github.com/a/b" in text and '"Clone HTTPS"' in text
    assert "Recent activity: In Chrome (github.com) for 15s." in text
    assert "Selected text" not in text and "Error message" not in text
    assert text.endswith("if they are fine on their own.") and "Wade can:" in text


def test_trigger_fired_carries_mode_and_kind():
    m = protocol.trigger_fired(suggestion_id="s", gate_score=0.0, jspace_concepts=["clone"],
                               tkg_digest="d", timestamp=1.0, mode="coding", kind="settled")
    assert m["mode"] == "coding" and m["kind"] == "settled" and m["type"] == "trigger_fired"
    assert "mode" not in protocol.trigger_fired(suggestion_id="s", gate_score=0.0, jspace_concepts=[],
                                                tkg_digest="d", timestamp=1.0)


def test_concepts_merge_word_pieces_and_translations():
    assert anchors.concept("summariz") == "summarize"
    assert anchors.concept("检查") == "check" and anchors.family_of("check") == "fixing"
    assert anchors.concept("ex") == "ex"  # too short to attribute
    assert anchors.concept("comp") == "comp"  # compare/comparison: shorter than a unique prefix? stays unmatched
    assert anchors.family_of(anchors.concept("nada")) == "null"
    assert anchors.normalize(" 总结") == "总结"
