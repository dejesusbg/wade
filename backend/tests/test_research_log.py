"""The research log records decisions, never screen text."""

import json
from types import SimpleNamespace

from wade_backend.research_log import ResearchLog, domain, entry
from wade_backend.tkg import CheckRequest

SECRET = "my bank balance is 1,234"


def _check():
    return CheckRequest("selection", 0.0, ("text_selected",), f"In Safari ('{SECRET}', bank.example.com) for 5s.",
                        {"app": "Safari", "title": SECRET, "url": "https://www.bank.example.com/acct/42",
                         "excerpt": SECRET, "selection": SECRET, "error_text": SECRET})


def _result():
    return SimpleNamespace(fire=True, mode="writing", family_scores={"writing": 0.03}, null_score=0.02,
                           concepts=[("summarize", 0.03)], output_word="summarize", latency_ms=412.3)


def test_entry_has_decision_and_no_screen_text():
    row = entry(_check(), _result(), "sid-1", "v2 layers 27,32 margin", now=1.0)
    text = json.dumps(row)
    assert SECRET not in text and "acct/42" not in text
    assert row["domain"] == "bank.example.com" and row["app"] == "Safari"
    assert row["has"] == ["error_text", "excerpt", "selection"]
    assert row["stage2"]["fire"] and row["stage2"]["mode"] == "writing" and row["suggestion_id"] == "sid-1"


def test_entry_without_stage2():
    row = entry(_check(), now=1.0)
    assert "stage2" not in row and "suggestion_id" not in row


def test_domain_only_for_web_pages():
    assert domain("https://www.github.com/a/b") == "github.com"
    assert domain("file:///Users/me/Private/notes.pdf") is None
    assert domain(None) is None


def test_log_appends_lines(tmp_path):
    log = ResearchLog(tmp_path / "eval" / "checks.jsonl")
    log.write(entry(_check(), now=1.0))
    log.write(entry(_check(), _result(), "s", now=2.0))
    log.close()
    lines = (tmp_path / "eval" / "checks.jsonl").read_text().splitlines()
    assert len(lines) == 2 and json.loads(lines[1])["stage2"]["mode"] == "writing"
