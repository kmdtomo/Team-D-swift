#!/usr/bin/env python3
"""Source-only contract lint for the T19-01 workflow, scripts, and merge-gate docs."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ios-ci.yml"
FIXTURE = ROOT / "scripts/ci_fixture.sh"
SOURCE = ROOT / "scripts/ci_source_gates.sh"
LIVE = ROOT / "scripts/ci_live_smoke.sh"
DOC = ROOT / "docs/development/ci-merge-gates.md"
CHECKOUT_SHA = "11bd71901bbe5b1630ceea73d27597364c9af683"
UPLOAD_SHA = "ea165f8d65b6e75b540449e92b4886f43607fa02"
REQUIRED_CHECKS = ("T19-01 Source gates", "T19-01 Fixture suite")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> None:
    workflow = read(WORKFLOW)
    fixture = read(FIXTURE)
    source = read(SOURCE)
    live = read(LIVE)
    doc = read(DOC)

    require(workflow.startswith("name: TeamD iOS CI\n"), "stable workflow name")
    require("pull_request_target" not in workflow, "pull_request_target is forbidden")
    for trigger in ("pull_request:", "push:", "workflow_dispatch:"):
        require(trigger in workflow, f"missing workflow trigger {trigger}")
    require("permissions:\n  contents: read" in workflow, "workflow must have read-only contents permission")
    require(workflow.count("runs-on: macos-26") == 3, "all jobs must use macos-26")
    require(workflow.count("/Applications/Xcode_26.2.app/Contents/Developer") == 2, "source/fixture Xcode pin drift")
    require("com.apple.CoreSimulator.SimRuntime.iOS-26-2" in workflow and "iPhone 17 Pro" in workflow, "Simulator pin drift")
    require("actions/cache" not in workflow and "cache:" not in workflow, "shared/restored cache is forbidden")

    actions = re.findall(r"uses:\s*([^\s#]+)", workflow)
    require(actions.count(f"actions/checkout@{CHECKOUT_SHA}") == 3, "checkout action pin drift")
    require(actions.count(f"actions/upload-artifact@{UPLOAD_SHA}") == 2, "upload action pin drift")
    require(all(re.fullmatch(r"[^@]+@[0-9a-f]{40}", action) for action in actions), "every action must use a full commit SHA")
    for check in (*REQUIRED_CHECKS, "T19-01 Protected live smoke"):
        require(f"name: {check}" in workflow, f"missing stable check name {check}")
    require("retention-days: 7" in workflow and "retention-days: 14" in workflow, "artifact retention drift")
    require("if: github.event_name == 'workflow_dispatch' && inputs.run_live_smoke" in workflow, "live smoke dispatch guard drift")
    require("environment: teamd-ios-live-smoke" in workflow, "live smoke protected environment missing")
    require(workflow.count("secrets.") == 1, "only the protected live job may reference one CI credential")
    require(workflow.index("protected-live-smoke:") < workflow.index("secrets."), "secret reference escaped the protected live job")

    fixture_fragments = (
        "Xcode 26.2 (17C52)",
        "swift package",
        "resolve",
        "swift build",
        "swift test",
        "xcodebuild build-for-testing",
        "xcodebuild test-without-building",
        "Debug-Fixture",
        "-disableAutomaticPackageResolution",
        "-clonedSourcePackagesDirPath",
        "-derivedDataPath",
        "check_xcode_warnings.py",
        "verify_t03_03.py --product",
        "ci_secret_scan.py --path",
    )
    for fragment in fixture_fragments:
        require(fragment in fixture, f"fixture CI missing {fragment}")
    require("simctl create" in fixture and "simctl delete" in fixture, "fixture CI must use a disposable Simulator")

    source_commands = (
        "lint_t01_02.py",
        "lint_t03_02.py",
        "verify_t03_03.py",
        "lint_corpus.py",
        "lint_t19_03_inventory.py",
        "test_t19_01_failure_gates.py",
        "ci_secret_scan.py --tracked",
        "git diff --check",
    )
    for command in source_commands:
        require(command in source, f"source gate missing {command}")
    require("set -x" not in live and "response body is suppressed" in live, "live smoke must suppress secret-bearing output")
    require("workflow_dispatch" in live and "TEAM_D_ALLOW_PROTECTED_LIVE_SMOKE" in live, "live script must fail closed outside dispatch")

    for check in REQUIRED_CHECKS:
        require(f"`{check}`" in doc, f"branch-protection docs missing exact check {check}")
    for phrase in (
        "Xcode 26.2 (17C52)",
        "macos-26",
        "iOS 26.2",
        "iPhone 17 Pro",
        "Debug-Fixture",
        "no shared cache",
        "teamd-ios-live-smoke",
        "pending repository-administrator gate",
        "7 days",
        "14 days",
    ):
        require(phrase in doc, f"merge-gate docs missing {phrase}")
    print("T19-01 CI workflow and merge-gate documentation lint passed.")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as error:
        print(f"T19-01 CI lint failed: {error}", file=sys.stderr)
        raise SystemExit(1)
