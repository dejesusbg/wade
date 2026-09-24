"""Anchor concept families (CLAUDE.md §5.4): one family per mode Wade can speak in, plus a
null family for "nothing worth saying".

Only *action or need* words, never topic words. "code" or "paper" would light up during
ordinary coding or reading (the Clippy failure); "clone", "cite", "retry" describe something
to offer. The family key doubles as the mode label shown to the user ("wade is coding…"),
following the UX demo's verbs; the stuck family is "fixing".

Families are *concepts*, not English strings. The lens reads single tokens, and in practice a
concept shows up as an English word, a word piece ("summariz"), or a token in another language
the model thinks in (Qwen: 检查 "check", 总结 "summarize"). `concept()` maps all of those to
the family's canonical word. Measured on the first Stage 2 eval, where those forms carried
most of the signal.
"""

from __future__ import annotations

FAMILIES: dict[str, tuple[str, ...]] = {
    "fixing": ("error", "errors", "stuck", "fail", "failed", "failing", "failure", "retry",
               "blocked", "confused", "broken", "crash", "denied", "fix", "wrong", "problem",
               "bug", "debug", "issue", "troubleshoot", "check", "try", "grant", "help", "solve"),
    "explaining": ("explain", "clarify", "define", "definition"),
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

# Other-language forms the model uses for the same concepts (canonical English word on the right).
TRANSLATIONS: dict[str, str] = {
    "错误": "error", "修复": "fix", "检查": "check", "尝试": "try", "失败": "fail", "问题": "problem",
    "解决": "solve", "帮助": "help", "解释": "explain", "克隆": "clone", "下载": "download",
    "安装": "install", "引用": "cite", "总结": "summarize", "摘要": "summary", "翻译": "translate",
    "保存": "save", "收藏": "bookmark", "分享": "share", "发送": "send", "比较": "compare",
    "对比": "compare", "价格": "price", "便宜": "cheaper", "无": "none", "没有": "nothing",
    "无需": "unnecessary",
    # Spanish (the app's second UI language)
    "arreglar": "fix", "revisar": "check", "explicar": "explain", "clonar": "clone",
    "descargar": "download", "citar": "cite", "resumir": "summarize", "traducir": "translate",
    "guardar": "save", "compartir": "share", "comparar": "compare", "nada": "nothing",
}

WORD_TO_FAMILY: dict[str, str] = {w: fam for fam, words in FAMILIES.items() for w in words}
NULL_WORDS = frozenset(NULL_FAMILY)
_ALL = tuple(WORD_TO_FAMILY) + NULL_FAMILY
MIN_PIECE = 4  # shorter pieces ("ex", "re", "sum") are too ambiguous to attribute


def normalize(token_text: str) -> str:
    """' Error,' → 'error', ' 检查' → '检查'. Returns '' for tokens that aren't words."""
    word = token_text.strip().strip(".,;:!?\"'()[]{}").lower()
    if len(word) >= 2 and word.isalpha():
        return word
    return word if word in TRANSLATIONS else ""


def concept(word: str) -> str:
    """Canonical anchor word for a token's word form, or the word itself if it isn't one.
    'summariz' → 'summarize', '检查' → 'check', 'rationale' → 'rationale'."""
    if word in WORD_TO_FAMILY or word in NULL_WORDS:
        return word
    if word in TRANSLATIONS:
        return TRANSLATIONS[word]
    if len(word) >= MIN_PIECE:
        matches = {a for a in _ALL if a.startswith(word)}
        if len(matches) == 1:
            return matches.pop()
    return word


def family_of(concept_word: str) -> str | None:
    """'fixing', 'null', or None."""
    if concept_word in NULL_WORDS:
        return "null"
    return WORD_TO_FAMILY.get(concept_word)


def check_single_tokens(encode) -> list[str]:
    """Anchor words the tokenizer splits into several tokens (with a leading space, as in text)."""
    words = [w for ws in FAMILIES.values() for w in ws] + list(NULL_FAMILY)
    return [w for w in words if len(encode(" " + w)) != 1]
