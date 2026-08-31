#!/usr/bin/env python3
"""Negative-path self-test for the T19-01 workflow contract linter."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


SOURCE_ROOT = Path(__file__).resolve().parents[1]
FILES = (
    ".github/workflows/ios-ci.yml",
    "scripts/ci_fixture.sh",
    "scripts/ci_source_gates.sh",
    "scripts/ci_live_smoke.sh",
    "scripts/lint_t19_01_ci.py",
    "docs/development/ci-merge-gates.md",
)


def reset(destination: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for relative in FILES:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SOURCE_ROOT / relative, target)


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", "scripts/lint_t19_01_ci.py"],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )


def expect_failure(root: Path, phrase: str) -> None:
    result = run(root)
    assert result.returncode == 1, result.stdout + result.stderr
    assert phrase in result.stderr, result.stderr


with tempfile.TemporaryDirectory(prefix="teamd-t19-01-ci-lint-") as temporary:
    root = Path(temporary) / "repo"
    reset(root)
    assert run(root).returncode == 0

    workflow = root / ".github/workflows/ios-ci.yml"
    workflow.write_text(workflow.read_text(encoding="utf-8").replace("actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683", "actions/checkout@v4", 1), encoding="utf-8")
    expect_failure(root, "checkout action pin drift")

    reset(root)
    workflow = root / ".github/workflows/ios-ci.yml"
    workflow.write_text(workflow.read_text(encoding="utf-8").replace("  pull_request:\n", "  pull_request_target:\n", 1), encoding="utf-8")
    expect_failure(root, "pull_request_target is forbidden")

    reset(root)
    workflow = root / ".github/workflows/ios-ci.yml"
    workflow.write_text(workflow.read_text(encoding="utf-8").replace("environment: teamd-ios-live-smoke", "environment: unprotected-live"), encoding="utf-8")
    expect_failure(root, "protected environment missing")

    reset(root)
    fixture = root / "scripts/ci_fixture.sh"
    fixture.write_text(fixture.read_text(encoding="utf-8").replace("-disableAutomaticPackageResolution", "-allowAutomaticPackageResolution", 1), encoding="utf-8")
    expect_failure(root, "fixture CI missing -disableAutomaticPackageResolution")

print("T19-01 CI lint negative-path self-test passed.")
