"""Temporary review-RED profile; completed slice gates use the full suite."""
import json
import os
from pathlib import Path


def test_scope(profile, branch):
    if not branch.startswith("codex/s5-") or profile is None:
        return "full"
    if profile == {"mode": "orientation-red"} and branch == "codex/s5-11-device-presentation":
        return "orientation-red"
    if profile == {"mode": "sidebar-red"} and branch == "codex/s5-12-sidebar":
        return "sidebar-red"
    if profile == {"mode": "search-red"} and branch == "codex/s5-13-search":
        return "search-red"
    if profile == {"mode": "files-red"} and branch == "codex/s5-14-files":
        return "files-red"
    if profile == {"mode": "resize-diagnostic"} and branch == "codex/s5-10-divider-resize":
        return "resize-diagnostic"
    if profile != {"mode": "review-red"}:
        raise ValueError("Stage 5 profile must match an explicit fixed RED mode and branch")
    return "review-red"


if __name__ == "__main__":
    path = Path(".github/stage5-test-profile.json")
    profile = json.loads(path.read_text()) if path.exists() else None
    print(test_scope(profile, os.environ.get("GITHUB_HEAD_REF") or os.environ["GITHUB_REF_NAME"]))
