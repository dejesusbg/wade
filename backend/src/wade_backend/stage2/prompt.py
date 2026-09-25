"""The Stage 2 prompt: (a) current screen/AX context + (b) the TKG digest (CLAUDE.md §5.4).

Design choice, stated plainly: the prompt lists what Wade can offer and asks for the single most
helpful action as one verb, or "nothing". Stage 2 never lets the model answer; it reads the
J-space at the last prompt positions, i.e. what the model is *poised* to say. A one-verb answer
keeps that poised content single-token, which is what the lens can resolve.

v1 of this prompt asked a yes/no question ("is there something worth offering?"): the J-space
then filled with answer-format tokens ("yes", "if", "none") and no action concepts, and a
repo page read as "no" because the model didn't know Wade could clone. Listing Wade's
affordances fixes that; saying staying quiet is usually right keeps the null family fair.
"""

from __future__ import annotations

from ..tkg import CheckRequest

SYSTEM = (
    "You are Wade, a quiet assistant on the user's Mac. You see what they are doing and only "
    "speak up when there is something genuinely useful to offer: help with a problem they are "
    "stuck on, or a quick action on what is in front of them. Most of the time the right choice "
    "is to stay quiet."
)


# What Wade can do (the UX demo's actions). Tells the model what "offering" can mean.
AFFORDANCES = (
    "Wade can: fix or explain an error, clone or download a repository, cite, summarize or "
    "translate text, save a paper, share a page, or compare options and prices."
)


def _field(label: str, value: str | None, quote: bool = False) -> str | None:
    if not value:
        return None
    return f"- {label}: \"{value}\"" if quote else f"- {label}: {value}"


# The question at the end of the message. "v2" (Phase 3) names "nothing" as an answer, which
# gives the null family a voice but also primes it on every check. "v3" drops that option and
# leaves "stay quiet" to the system prompt and the decision rule. Compared in Phase 7.
QUESTIONS = {
    "v2": "Which single action would help them most right now? Answer with one verb, "
          "or \"nothing\" if they are fine on their own.",
    "v3": "Which single action would help them most right now? Answer with one verb.",
}
DEFAULT_VARIANT = "v2"


def user_message(check: CheckRequest, variant: str = DEFAULT_VARIANT) -> str:
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
        f"{AFFORDANCES}\n"
        f"{QUESTIONS[variant]}"
    )
