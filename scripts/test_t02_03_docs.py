#!/usr/bin/env python3
"""Keep the T02-03 fixture baseline documentation, smoke script, and CI job aligned."""
from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
README = ROOT / "README.md"
DOC = ROOT / "docs/development/fixture-baseline.md"
SMOKE = ROOT / "scripts/docs_smoke_fixture.sh"
WORKFLOW = ROOT / ".github/workflows/t02-03-docs-smoke.yml"


def require_in_order(text: str, fragments: list[str], source: Path) -> None:
    cursor = -1
    for fragment in fragments:
        position = text.find(fragment, cursor + 1)
        if position < 0:
            raise AssertionError(f"{source}: missing {fragment!r}")
        cursor = position


def main() -> None:
    readme = README.read_text(encoding="utf-8")
    doc = DOC.read_text(encoding="utf-8")
    smoke = SMOKE.read_text(encoding="utf-8")
    workflow = WORKFLOW.read_text(encoding="utf-8")

    require_in_order(
        readme,
        [
            "camera-first native iOS client",
            "./scripts/docs_smoke_fixture.sh",
            "docs/development/fixture-baseline.md",
            "Fixture and live are distinct modes",
        ],
        README,
    )
    require_in_order(
        doc,
        [
            "git clone <repository-url> Team-D-swift",
            "open TeamD.xcworkspace",
            "./scripts/docs_smoke_fixture.sh",
            "## Troubleshooting",
            "## Timed clean-clone checklist",
        ],
        DOC,
    )
    for required in ("Xcode 26.2 (17C52)", "Debug-Fixture", "Docker", "LiveKit", "camera", "T17-03"):
        assert required in doc, f"{DOC}: missing {required!r}"

    require_in_order(
        smoke,
        [
            "xcodebuild -version",
            "select_existing_simulator()",
            "xcrun simctl bootstatus",
            "Selected fixture Simulator:",
            "swift build --package-path Packages",
            "xcodebuild test",
            "-configuration Debug-Fixture",
            "-only-testing:TeamDUITests/TeamDUITests/testColdLaunchEntersCameraFlowWithoutHomeOrTabs",
            "scripts/check_xcode_warnings.py",
        ],
        SMOKE,
    )
    for required in ("TEAM_D_SIMULATOR_UDID", "TEAM_D_SIMULATOR_NAME", "TEAM_D_SIMULATOR_RUNTIME", "simctl create"):
        assert required in smoke, f"{SMOKE}: missing {required!r}"
    assert '-destination "platform=iOS Simulator,id=$simulator_udid,arch=$host_architecture"' in smoke
    assert "ARCHS=\"$host_architecture\"" not in smoke
    for required in ("Fixture docs smoke elapsed seconds:", "Repository status unchanged before and after fixture docs smoke."):
        assert required in smoke, f"{SMOKE}: missing {required!r}"
    assert "Docker" not in smoke
    assert "LiveKit" not in smoke

    require_in_order(
        workflow,
        [
            "actions/checkout@v4",
            "python3 scripts/test_t02_03_docs.py",
            "./scripts/docs_smoke_fixture.sh",
        ],
        WORKFLOW,
    )
    assert "macos-26" in workflow
    assert "DEVELOPER_DIR: /Applications/Xcode_26.2.app/Contents/Developer" in workflow
    assert "permissions:\n  contents: read" in workflow
    assert "timeout-minutes: 60" in workflow
    print("T02-03 docs, fixture smoke script, and workflow are aligned.")


if __name__ == "__main__":
    main()
