"""Anchor concept families (CLAUDE.md §5.4): one family per mode Wade can speak in, plus a
null family for "nothing worth saying".

Only *action or need* words, never topic words. "code" or "paper" would light up during
ordinary coding or reading (the Clippy failure); "clone", "cite", "retry" describe something
to offer. The family key doubles as the mode label shown to the user ("wade is coding…"),
following the UX demo's verbs; the stuck family is "fixing".

The J-lens resolves single tokens only (the paper's known limitation), so each word here must
be a single token for the model to express it directly; `check_single_tokens` reports any
that aren't.
"""

from __future__ import annotations

FAMILIES: dict[str, tuple[str, ...]] = {
    "fixing": ("error", "errors", "stuck", "fail", "failed", "failing", "failure", "retry",
               "blocked", "confused", "broken", "crash", "denied", "fix", "wrong", "problem",
               "bug", "debug", "issue", "troubleshoot"),
    "coding": ("clone", "fork", "install", "download", "deploy", "checkout"),
    "writing": ("cite", "citation", "summarize", "summary", "translate", "translation",
                "rephrase", "rewrite", "proofread", "quote"),
    "researching": ("save", "bookmark", "zotero", "reference", "references", "bibliography",
                    "annotate"),
    "sharing": ("share", "send", "forward", "post", "whatsapp", "tweet"),
    "comparing": ("compare", "comparison", "cheaper", "cheapest", "price", "prices", "versus",
                  "discount", "alternative", "alternatives"),
}

NULL_FAMILY: tuple[str, ...] = ("nothing", "none", "no", "fine", "continue", "unnecessary",
                                "routine", "normal", "wait", "quiet")

WORD_TO_FAMILY: dict[str, str] = {w: fam for fam, words in FAMILIES.items() for w in words}
NULL_WORDS = frozenset(NULL_FAMILY)


def normalize(token_text: str) -> str:
    """' Error,' → 'error'. Returns '' for tokens that aren't words."""
    word = token_text.strip().strip(".,;:!?\"'()[]{}").lower()
    return word if len(word) >= 2 and word.isalpha() else ""


def check_single_tokens(encode) -> list[str]:
    """Anchor words the tokenizer splits into several tokens (with a leading space, as in text)."""
    words = [w for ws in FAMILIES.values() for w in ws] + list(NULL_FAMILY)
    return [w for w in words if len(encode(" " + w)) != 1]
