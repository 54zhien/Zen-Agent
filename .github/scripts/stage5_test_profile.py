"""Temporary review-RED profile; completed slice gates use the full suite."""
import json
import os
from pathlib import Path


def test_scope(profile, branch):
    if not branch.startswith("codex/s5-") or profile is None:
        return "full"
    if profile == {"mode": "resize-diagnostic"} and branch == "codex/s5-10-divider-resize":
        return "resize-diagnostic"
    if profile != {"mode": "review-red"}:
        raise ValueError("Stage 5 profile accepts only the explicit review-red mode")
    return "review-red"


if __name__ == "__main__":
    path = Path(".github/stage5-test-profile.json")
    profile = json.loads(path.read_text()) if path.exists() else None
    print(test_scope(profile, os.environ.get("GITHUB_HEAD_REF") or os.environ["GITHUB_REF_NAME"]))
