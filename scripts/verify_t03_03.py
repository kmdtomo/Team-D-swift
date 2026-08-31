#!/usr/bin/env python3
"""Static safety checks for the build-selected fixture/live boundary."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "Config"
PROJECT = ROOT / "TeamD.xcodeproj/project.pbxproj"
APP = ROOT / "App/TeamDApp.swift"
CREDENTIAL_ASSIGNMENT = re.compile(r"(?m)^\s*(?:[A-Z0-9_]*(?:API[_-]?KEY|SECRET|TOKEN)[A-Z0-9_]*)\s*[=:]\s*([^$\s#][^\s#]*)")
JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")
PRIVATE_KEY = re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----")
PRIVATE_ADDRESS = re.compile(r"(?i)(?:https?|wss?)://(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d+)?")
SAFE_SYNTHETIC = ("synthetic.not-a-secret", "example.invalid", "example.test")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"T03-03 verification failed: {message}")


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def findings(value: str) -> list[str]:
    """Find credential-shaped values, never merely descriptive documentation."""
    result: list[str] = []
    for match in CREDENTIAL_ASSIGNMENT.finditer(value):
        candidate = match.group(1)
        if not any(marker in candidate for marker in SAFE_SYNTHETIC):
            result.append("credential assignment")
    if JWT.search(value):
        result.append("JWT-shaped token")
    if PRIVATE_KEY.search(value):
        result.append("private key")
    if PRIVATE_ADDRESS.search(value):
        result.append("private endpoint")
    return result


def check_content(path: Path, value: str) -> None:
    found = findings(value)
    require(not found, f"{path}: {', '.join(found)}")


def tracked_paths() -> list[Path]:
    result = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True)
    return [ROOT / item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def check_tracked_repository() -> None:
    for path in tracked_paths():
        if not path.is_file():
            continue
        value = path.read_bytes()
        if b"\0" in value:
            continue
        check_content(path.relative_to(ROOT), value.decode("utf-8", errors="replace"))


def check_templates() -> None:
    shared = text(CONFIG / "Shared.xcconfig")
    require("https:/$()/backend.example.invalid" in shared, "shared HTTPS base URL placeholder")
    require("wss:/$()/livekit.example.invalid" in shared, "shared LiveKit WSS placeholder")
    check_content(CONFIG / "Shared.xcconfig", shared)
    expected = {
        "Debug-Fixture.xcconfig": ("TEAM_D_FIXTURE", "fixture"),
        "Debug-Live.xcconfig": ("TEAM_D_LIVE", "live"),
        "Release.xcconfig": ("TEAM_D_LIVE", "live"),
    }
    for name, (flag, mode) in expected.items():
        value = text(CONFIG / name)
        require('#include "Shared.xcconfig"' in value, f"{name} includes shared config")
        require(f"SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) {flag}" in value, f"{name} has explicit mode flag")
        require(f"INFOPLIST_KEY_TeamDMode = {mode}" in value, f"{name} has explicit mode")
        check_content(CONFIG / name, value)


def check_project() -> None:
    project = text(PROJECT)
    for name in ("Debug-Fixture", "Debug-Live", "Release"):
        require(project.count(f'name = "{name}"') >= 2 or f"name = {name};" in project, f"{name} configuration")
    require("baseConfigurationReference = A00000000000000000000014" in project, "fixture config is wired")
    require("baseConfigurationReference = A00000000000000000000015" in project, "live config is wired")
    require("baseConfigurationReference = A00000000000000000000016" in project, "release config is wired")
    app = text(APP)
    require("#elseif TEAM_D_LIVE" in app and "#error(" in app, "app rejects an unselected mode")
    require("live-mode-badge" in app and "fixture-mode-badge" in app, "both startup mode badges")


def check_product(product: Path) -> None:
    require(product.is_dir() and product.suffix == ".app", f"built product is not an app bundle: {product}")
    for path in product.rglob("*"):
        if not path.is_file():
            continue
        result = subprocess.run(["strings", "-a", str(path)], check=True, capture_output=True, text=True)
        check_content(path, result.stdout)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--product", type=Path, help="TeamD executable to scan after a build")
    args = parser.parse_args()
    check_templates()
    check_project()
    check_tracked_repository()
    if args.product:
        check_product(args.product)
    print("T03-03 fixture/live configuration and secret-boundary verification passed.")


if __name__ == "__main__":
    main()
