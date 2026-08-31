#!/usr/bin/env python3
"""Negative-path self-test for the source-only T19-03 inventory checker."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


SOURCE_ROOT = Path(__file__).resolve().parents[1]
FILES = [
    "Licenses/dependency-inventory.json",
    "Licenses/NOTICE.md",
    "Packages/Package.swift",
    "TeamD.xcodeproj/project.pbxproj",
    "Fixtures/asset-manifest.json",
    "Fixtures/MeasurementCorpus/corpus-manifest.json",
    "output/pdf/t11-01-50mm-marker.pdf",
    "scripts/lint_t19_03_inventory.py",
]


def copy_baseline(destination: Path) -> None:
    for child in destination.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
    for relative in FILES:
        source = SOURCE_ROOT / relative
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["python3", "scripts/lint_t19_03_inventory.py"], cwd=root, text=True, capture_output=True, check=False)


def expect_failure(root: Path, expected: str) -> None:
    result = run(root)
    assert result.returncode == 1, result.stdout + result.stderr
    assert expected in result.stderr, result.stderr


with tempfile.TemporaryDirectory(prefix="teamd-t19-03-") as temporary:
    root = Path(temporary)
    copy_baseline(root)
    assert run(root).returncode == 0

    package = root / "Packages/Package.swift"
    package.write_text(package.read_text(encoding="utf-8") + '\n// .package(url: "https://example.invalid", from: "1.0.0")\n', encoding="utf-8")
    expect_failure(root, "external SwiftPM package added")

    copy_baseline(root)
    project = root / "TeamD.xcodeproj/project.pbxproj"
    project.write_text(project.read_text(encoding="utf-8").replace("A00000000000000000000082 /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ();", "A00000000000000000000082 /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (FAKE /* asset */);", 1), encoding="utf-8")
    expect_failure(root, "resource build phase changed")

    copy_baseline(root)
    approved = root / "Fixtures/Approved"
    approved.mkdir(parents=True)
    (approved / "unreviewed.png").write_bytes(b"not-a-real-png")
    expect_failure(root, "approved fixture binary exists")

    copy_baseline(root)
    notice = root / "Licenses/NOTICE.md"
    notice.write_text(notice.read_text(encoding="utf-8").replace("LiveKit Swift", "LiveKit-Swift"), encoding="utf-8")
    expect_failure(root, "NOTICE missing required boundary")

print("T19-03 inventory checker self-test passed")
