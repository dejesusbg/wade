"""The Stage 2 prompt: (a) current screen/AX context + (b) the TKG digest (CLAUDE.md §5.4).

Design choice, stated plainly: the prompt ends with an open question about whether anything is
worth offering, answered "in one word". Stage 2 never lets the model answer; it reads the
J-space at the last prompt positions, i.e. what the model is *poised* to say. Asking for one
word keeps that poised content single-token, which is what the J-lens can resolve.
The prompt says staying quiet is usually right, so the null family has a fair chance.
"""

from __future__ import annotations

from ..tkg import CheckRequest

SYSTEM = (
    "You are Wade, a quiet assistant on the user's Mac. You see what they are doing and only "
    "speak up when there is something genuinely useful to offer: help with a problem they are "
    "stuck on, or a quick action on what is in front of them. Most of the time the right choice "
    "is to stay quiet."
)


def _field(label: str, value: str | None, quote: bool = False) -> str | None:
    if not value:
        return None
    return f"- {label}: \"{value}\"" if quote else f"- {label}: {value}"


def user_message(check: CheckRequest) -> str:
    ctx = check.context
    lines = [
        _field("App", ctx.get("app")),
        _field("Window", ctx.get("title")),
        _field("Address", ctx.get("url")),
        _field("On screen", ctx.get("excerpt"), quote=True),
        _field("Selected text", ctx.get("selection"), quote=True),
        _field("Error message", ctx.get("error_text"), quote=True),
    ]
    screen = "\n".join(l for l in lines if l) or "- (nothing readable)"
    return (
        f"What's on screen:\n{screen}\n\n"
        f"Recent activity: {check.digest}\n\n"
        "Is there something worth offering them right now? Answer in one word."
    )
