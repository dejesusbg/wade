"""The local model, run block by block so mid-layer residuals can be read and probed.

Layer convention: `h_ℓ` is the residual stream *after* transformer block ℓ (0-indexed).
`h_final` is the output of the model's final RMSNorm, i.e. what the unembedding reads.
"""

from __future__ import annotations

from collections.abc import Sequence

import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.base import create_attention_mask

DEFAULT_REPO = "mlx-community/Qwen3-4B-Instruct-2507-4bit"


class LensModel:
    def __init__(self, repo: str = DEFAULT_REPO) -> None:
        self.repo = repo
        self.model, self.tokenizer = load(repo)
        self.model.eval()
        self.inner = self.model.model
        self.n_layers = len(self.inner.layers)
        self.d_model = self.model.args.hidden_size
        self.tied = bool(getattr(self.model.args, "tie_word_embeddings", False))
        # Computation dtype of the quantized model (its scales' dtype).
        emb = self.inner.embed_tokens
        self.dtype = emb.scales.dtype if hasattr(emb, "scales") else emb.weight.dtype

    def mid_layers(self, count: int = 5, start: float = 0.38, end: float = 0.92) -> list[int]:
        """Evenly spaced layers inside the paper's workspace band (~38%–92% of depth)."""
        top = self.n_layers - 1
        return sorted({round(top * (start + (end - start) * i / (count - 1))) for i in range(count)})

    def head(self, x: mx.array) -> mx.array:
        """Unembedding W_U (tied to the input embedding for Qwen3-4B)."""
        if self.tied:
            return self.inner.embed_tokens.as_linear(x)
        return self.model.lm_head(x)

    def unembedding_rows(self, token_ids: mx.array) -> mx.array:
        """Dense rows of W_U for the given token ids, shape (n, d)."""
        layer = self.inner.embed_tokens if self.tied else self.model.lm_head
        if hasattr(layer, "scales"):
            return mx.dequantize(
                layer.weight[token_ids], layer.scales[token_ids],
                layer.biases[token_ids] if getattr(layer, "biases", None) is not None else None,
                group_size=layer.group_size, bits=layer.bits,
            )
        return layer.weight[token_ids]

    @property
    def vocab_size(self) -> int:
        layer = self.inner.embed_tokens if self.tied else self.model.lm_head
        return layer.weight.shape[0]

    def forward(
        self,
        tokens: mx.array,
        capture: Sequence[int] = (),
        deltas: dict[int, mx.array] | None = None,
    ) -> tuple[dict[int, mx.array], mx.array]:
        """Run the model on `tokens` (B, T).

        Returns ({ℓ: h_ℓ} for ℓ in `capture`, h_final). If `deltas` is given, `deltas[ℓ]` is
        added to h_ℓ before it flows on: a zero delta changes nothing numerically, but its
        gradient is exactly ∂(output)/∂h_ℓ, which is how the Jacobians are measured.
        """
        h = self.inner.embed_tokens(tokens)
        mask = create_attention_mask(h, None)
        captured: dict[int, mx.array] = {}
        for i, layer in enumerate(self.inner.layers):
            h = layer(h, mask, None)
            if deltas is not None and i in deltas:
                h = h + deltas[i]
            if i in capture:
                captured[i] = h
        return captured, self.inner.norm(h)

    def encode(self, text: str) -> list[int]:
        return self.tokenizer.encode(text)

    def chat_prompt(self, system: str, user: str) -> str:
        messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        return self.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
