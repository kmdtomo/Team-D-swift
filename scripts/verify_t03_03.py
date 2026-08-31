#!/usr/bin/env python3
"""Static safety checks for the build-selected fixture/live boundary."""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "Config"
PROJECT = ROOT / "TeamD.xcodeproj/project.pbxproj"
APP = ROOT / "App/TeamDApp.swift"
SCHEME = ROOT / "TeamD.xcodeproj/xcshareddata/xcschemes/TeamD.xcscheme"
XCCONFIG_CREDENTIAL = re.compile(r"(?m)^\s*(?:[A-Z0-9_]*(?:API[_-]?KEY|SECRET|TOKEN)[A-Z0-9_]*)\s*[=:]\s*([^$\s#][^\s#]*)")
SWIFT_CREDENTIAL = re.compile(r"(?im)^\s*(?:let|var)\s+(?:[A-Z0-9_]*(?:API[_-]?KEY|SECRET|TOKEN)[A-Z0-9_]*)\s*=\s*[\"']([^\"']+)")
JSON_CREDENTIAL = re.compile(r"(?i)\"(?:api[_-]?key|secret|token)\"\s*:\s*\"([^\"]+)\"")
JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")
PRIVATE_KEY = re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----")
PRIVATE_ADDRESS = re.compile(r"(?i)(?:https?|wss?)://(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d+)?")
SAFE_SYNTHETIC = ("synthetic.not-a-secret", "eyJhbGciOiJIUzI1NiJ9.payload.signature", "-DO-NOT-LEAK", "example.invalid", "example.test")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"T03-03 verification failed: {message}")


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def findings(value: str) -> list[str]:
    """Find credential-shaped values, never merely descriptive documentation."""
    result: list[str] = []
    for match in (*XCCONFIG_CREDENTIAL.finditer(value), *SWIFT_CREDENTIAL.finditer(value), *JSON_CREDENTIAL.finditer(value)):
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


def scanned_file_content(path: Path) -> str:
    raw = path.read_bytes()
    if b"\0" not in raw:
        return raw.decode("utf-8", errors="replace")
    result = subprocess.run(["strings", "-a", str(path)], check=True, capture_output=True, text=True)
    return result.stdout


def tracked_paths() -> list[Path]:
    result = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True)
    return [ROOT / item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def check_tracked_repository() -> None:
    for path in tracked_paths():
        if not path.is_file():
            continue
        check_content(path.relative_to(ROOT), scanned_file_content(path))


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
        require(f"TEAM_D_MODE = {mode}" in value, f"{name} has explicit mode")
        check_content(CONFIG / name, value)


def check_project() -> None:
    project = text(PROJECT)
    for name in ("Debug-Fixture", "Debug-Live", "Release"):
        require(project.count(f'name = "{name}"') >= 2 or f"name = {name};" in project, f"{name} configuration")
    require(target_configuration_mapping(project) == {
        "Debug-Fixture": "Debug-Fixture.xcconfig",
        "Debug-Live": "Debug-Live.xcconfig",
        "Release": "Release.xcconfig",
    }, "TeamD target configuration-to-xcconfig mapping")
    require("buildConfigurations = (A000000000000000000000B1 /* Debug-Live */, A000000000000000000000B3 /* Debug-Fixture */, A000000000000000000000B2 /* Release */);" in project, "TeamD target has exactly three expected configurations")
    require(all_configuration_lists_are_exact(project), "project and every target have exactly Debug-Live, Debug-Fixture, Release")
    scheme = text(SCHEME)
    require('<TestAction buildConfiguration="Debug-Fixture"' in scheme and '<LaunchAction buildConfiguration="Debug-Fixture"' in scheme, "shared scheme launches/tests fixture")
    require('<ProfileAction buildConfiguration="Release"' in scheme and '<ArchiveAction buildConfiguration="Release"' in scheme, "shared scheme profiles/archives release")
    app = text(APP)
    require(has_exact_mode_guards(app), "app rejects unselected and multiply selected modes")
    require("private struct ModeBadge" in app and "ModeBadge(mode: mode)" in app, "root renders one mode badge for every route")
    capture_start = app[app.index("private struct CaptureStartView"):app.index("private struct ModeBadge")]
    require("mode-badge" not in capture_start, "capture start does not duplicate mode badge")
    require("live-startup-error" in app and "model.runtimeStartupState?.message" in app, "root can display typed live startup failures")


def has_exact_mode_guards(app: str) -> bool:
    return (
        "#if TEAM_D_FIXTURE && TEAM_D_LIVE" in app
        and "#elseif TEAM_D_FIXTURE" in app
        and "#elseif TEAM_D_LIVE" in app
        and "#error(" in app
    )


def target_configuration_mapping(project: str) -> dict[str, str]:
    references = {
        "A00000000000000000000014": "Debug-Fixture.xcconfig",
        "A00000000000000000000015": "Debug-Live.xcconfig",
        "A00000000000000000000016": "Release.xcconfig",
    }
    expected_references = {
        "A000000000000000000000B1": "A00000000000000000000015",
        "A000000000000000000000B2": "A00000000000000000000016",
        "A000000000000000000000B3": "A00000000000000000000014",
    }
    result: dict[str, str] = {}
    for identifier in ("A000000000000000000000B1", "A000000000000000000000B2", "A000000000000000000000B3"):
        match = re.search(rf'{identifier} /\* ([^*]+) \*/ = \{{isa = XCBuildConfiguration; baseConfigurationReference = ([A-Z0-9]+) /\* [^*]+ \*/; buildSettings = \{{(.*?)\}}; name = "?([^;"]+)"?; \}};', project)
        if not match:
            return {}
        comment_name, reference, build_settings, setting_name = match.groups()
        if comment_name != setting_name or reference != expected_references[identifier] or "GENERATE_INFOPLIST_FILE = NO;" not in build_settings or "INFOPLIST_FILE = App/Info.plist;" not in build_settings:
            return {}
        result[setting_name] = references[reference]
    return result


def all_configuration_lists_are_exact(project: str) -> bool:
    expected = {
        "A00000000000000000000070": ("A1", "A3", "A2"),
        "A00000000000000000000071": ("B1", "B3", "B2"),
        "A00000000000000000000072": ("C1", "C3", "C2"),
        "A00000000000000000000073": ("D1", "D3", "D2"),
    }
    for identifier, suffixes in expected.items():
        entries = ", ".join(f"A000000000000000000000{suffix} /* {name} */" for suffix, name in zip(suffixes, ("Debug-Live", "Debug-Fixture", "Release")))
        if f"{identifier} " not in project or f"buildConfigurations = ({entries});" not in project:
            return False
    return True


def check_product(product: Path, expected_mode: str | None = None) -> None:
    require(product.is_dir() and product.suffix == ".app", f"built product is not an app bundle: {product}")
    info_path = product / "Info.plist"
    require(info_path.is_file(), f"built product is missing Info.plist: {product}")
    info = plistlib.loads(info_path.read_bytes())
    require(info.get("TeamDMode") in {"fixture", "live"}, "built product has an explicit TeamDMode")
    if expected_mode:
        require(info.get("TeamDMode") == expected_mode, f"built product mode is {expected_mode}")
    require(info.get("TeamDBackendBaseURL") == "https://backend.example.invalid", "built product has only the public HTTPS backend URL")
    require(info.get("TeamDLiveKitURL") == "wss://livekit.example.invalid", "built product has only the public LiveKit WSS URL")
    for path in product.rglob("*"):
        if not path.is_file():
            continue
        check_content(path, scanned_file_content(path))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--product", type=Path, help="TeamD app bundle to scan after a build")
    parser.add_argument("--expected-mode", choices=("fixture", "live"), help="assert the bundle's build-selected mode")
    args = parser.parse_args()
    check_templates()
    check_project()
    check_tracked_repository()
    if args.product:
        check_product(args.product, args.expected_mode)
    print("T03-03 fixture/live configuration and secret-boundary verification passed.")


if __name__ == "__main__":
    main()
