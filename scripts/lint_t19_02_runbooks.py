#!/usr/bin/env python3
"""Source-only consistency and safety validation for the T19-02 runbooks."""
from __future__ import annotations

import argparse
import json
import plistlib
import re
from pathlib import Path
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parent.parent
RUNBOOKS = {
    "README.md": [
        "# T19-02 runbook index",
        "## Current implementation truth",
        "## Runbook order",
        "## Evidence boundary",
        "## Documentation validation",
    ],
    "fixture.md": [
        "# Deterministic fixture runbook",
        "## Scope and separation",
        "## Xcode-only path",
        "## One-hour evidence path",
        "## Expected result",
        "## Fixture troubleshooting",
    ],
    "live.md": [
        "# Shared live runbook",
        "## Current blocker",
        "## Public app configuration",
        "## Preflight",
        "## Timeouts and retry policy",
        "## Live execution",
        "## Evidence to record",
    ],
    "device-and-demo.md": [
        "# Physical iPhone and demo runbook",
        "## Automatic signing",
        "## Physical-device flow",
        "## Demo preflight",
        "## Capture-to-save checklist",
        "## Evidence boundary",
    ],
    "optional-local-backend.md": [
        "# Optional local backend and rembg",
        "## Optional boundary",
        "## Export the read-only source",
        "## Optional FastAPI",
        "## Optional Agent",
        "## Optional rembg",
        "## Stop and clean up",
    ],
    "troubleshooting-and-privacy.md": [
        "# Troubleshooting, privacy, and failure isolation",
        "## Failure isolation order",
        "## Timeout and retry matrix",
        "## Session data and privacy",
        "## Logs and evidence",
        "## Escalation",
    ],
}

MARKDOWN_LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
REPO_REFERENCE = re.compile(
    r"(?:\./)?((?:scripts|Config|Contracts|App)/[A-Za-z0-9_.+/-]+)"
)
APP_SETTING = re.compile(r"\bTEAM_D_[A-Z0-9_]+\b")
SECRET_ASSIGNMENT = re.compile(
    r"(?im)^\s*(?:export\s+)?(?:LIVEKIT_API_KEY|LIVEKIT_API_SECRET|"
    r"OPENAI_API_KEY|REMBG_INTERNAL_URL|VITE_LIVEKIT_BROWSER_TOKEN|"
    r"AUTH_TOKEN|API_KEY|API_SECRET)\s*="
)
SECRET_TO_APP_ASSIGNMENT = re.compile(
    r"(?im)^\s*(?:export\s+)?TEAM_D_(?:BACKEND_BASE_URL|LIVEKIT_URL|MODE)\s*="
    r"[^\n]*(?:API_KEY|API_SECRET|AUTH_TOKEN|ACCESS_TOKEN|LIVEKIT_TOKEN|SECRET)"
)
JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")


def _read(path: Path, errors: list[str]) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        errors.append(f"{path}: cannot read UTF-8 text: {error}")
        return ""


def _xcconfig_keys(path: Path, errors: list[str]) -> set[str]:
    text = _read(path, errors)
    return {
        match.group(1)
        for line in text.splitlines()
        if (match := re.match(r"^\s*(TEAM_D_[A-Z0-9_]+)\s*=", line))
    }


def _check_required_sections(
    documents: dict[str, str], errors: list[str]
) -> None:
    for name, headings in RUNBOOKS.items():
        text = documents.get(name, "")
        cursor = -1
        for heading in headings:
            position = text.find(heading, cursor + 1)
            if position < 0:
                errors.append(f"docs/runbooks/{name}: missing or out-of-order {heading!r}")
                break
            cursor = position


def _check_links(root: Path, documents: dict[str, str], errors: list[str]) -> None:
    runbook_dir = root / "docs/runbooks"
    for name, text in documents.items():
        source = runbook_dir / name
        for raw_target in MARKDOWN_LINK.findall(text):
            target = raw_target.strip().split(maxsplit=1)[0].strip("<>")
            parsed = urlparse(target)
            if parsed.scheme in {"http", "https", "mailto"} or target.startswith("#"):
                continue
            path_text = unquote(parsed.path)
            resolved = (source.parent / path_text).resolve()
            try:
                resolved.relative_to(root.resolve())
            except ValueError:
                errors.append(f"{source}: link escapes repository: {target}")
                continue
            if not resolved.exists():
                errors.append(f"{source}: missing link target: {target}")


def _check_references(root: Path, combined: str, errors: list[str]) -> None:
    for reference in sorted(set(REPO_REFERENCE.findall(combined))):
        if not (root / reference).exists():
            errors.append(f"runbooks reference missing repository path: {reference}")


def _check_configuration(
    root: Path, documents: dict[str, str], combined: str, errors: list[str]
) -> None:
    expected = _xcconfig_keys(root / "Config/Shared.xcconfig", errors)
    expected |= _xcconfig_keys(root / "Config/Debug-Fixture.xcconfig", errors)
    expected |= _xcconfig_keys(root / "Config/Debug-Live.xcconfig", errors)
    expected |= _xcconfig_keys(root / "Config/Release.xcconfig", errors)
    if expected != {
        "TEAM_D_BACKEND_BASE_URL",
        "TEAM_D_LIVEKIT_URL",
        "TEAM_D_MODE",
    }:
        errors.append(f"current app configuration key set drifted: {sorted(expected)}")
    documented = set(APP_SETTING.findall(combined))
    if documented != expected:
        errors.append(
            "runbook app configuration keys differ from current xcconfig keys: "
            f"documented={sorted(documented)} expected={sorted(expected)}"
        )

    try:
        with (root / "App/Info.plist").open("rb") as stream:
            plist = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        errors.append(f"App/Info.plist: cannot parse: {error}")
        return
    for key in ("TeamDBackendBaseURL", "TeamDLiveKitURL", "TeamDMode"):
        if key not in plist:
            errors.append(f"App/Info.plist: missing current configuration key {key}")
        if key not in documents.get("live.md", ""):
            errors.append(f"docs/runbooks/live.md: missing Info.plist key {key}")

    shared = _read(root / "Config/Shared.xcconfig", errors)
    for placeholder in ("backend.example.invalid", "livekit.example.invalid"):
        if placeholder not in shared:
            errors.append(f"Config/Shared.xcconfig: missing expected placeholder {placeholder}")
        if placeholder not in combined:
            errors.append(f"runbooks do not disclose current placeholder {placeholder}")


def _check_contract(root: Path, documents: dict[str, str], errors: list[str]) -> None:
    availability_path = root / "Contracts/HTTP/v1/availability.json"
    openapi_path = root / "Contracts/HTTP/v1/openapi.json"
    try:
        availability = json.loads(availability_path.read_text(encoding="utf-8"))
        openapi = json.loads(openapi_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        errors.append(f"HTTP contract cannot be parsed: {error}")
        return

    live = documents.get("live.md", "")
    for surface, record in availability.get("surfaces", {}).items():
        marker = record.get("path", surface)
        state = "available" if record.get("available") is True else "unavailable"
        row = re.compile(
            rf"(?m)^\|[^\n]*`(?:GET |POST )?{re.escape(str(marker))}`[^\n]*\|\s*{state}\s*\|"
        )
        if not row.search(live):
            errors.append(
                f"docs/runbooks/live.md: missing {surface} availability row ({state})"
            )

    timeout_doc = documents.get("troubleshooting-and-privacy.md", "")
    for path, path_item in openapi.get("paths", {}).items():
        operations = [value for value in path_item.values() if isinstance(value, dict)]
        if len(operations) != 1:
            errors.append(f"{openapi_path}: expected one operation for {path}")
            continue
        timeout = operations[0].get("x-team-d-timeout-seconds")
        marker = re.compile(
            rf"(?m)^\|[^\n]*`(?:GET |POST )?{re.escape(path)}`[^\n]*\|\s*{timeout}\s+s\s*\|"
        )
        if not marker.search(timeout_doc):
            errors.append(
                f"docs/runbooks/troubleshooting-and-privacy.md: "
                f"missing {path} timeout {timeout} s"
            )


def _check_safety_and_boundaries(
    documents: dict[str, str], combined: str, errors: list[str]
) -> None:
    if SECRET_ASSIGNMENT.search(combined):
        errors.append("runbooks contain a prohibited credential/token assignment")
    if SECRET_TO_APP_ASSIGNMENT.search(combined):
        errors.append("runbooks assign a credential/token to an app build setting")
    if JWT.search(combined):
        errors.append("runbooks contain a JWT-like value")
    private_key_header = "-----BEGIN PRIVATE " + "KEY-----"
    if private_key_header in combined:
        errors.append("runbooks contain private-key material")

    index = documents.get("README.md", "")
    fixture = documents.get("fixture.md", "")
    live = documents.get("live.md", "")
    local = documents.get("optional-local-backend.md", "")
    device = documents.get("device-and-demo.md", "")
    required_phrases = [
        (index, "Fixture and live are independent modes", "index mode separation"),
        (fixture, "Fixture success is fixture evidence only", "fixture evidence boundary"),
        (live, "visible live failure with no fixture fallback", "live no-fallback boundary"),
        (local, "**OPTIONAL:**", "optional local label"),
        (local, "not required for fixture onboarding", "optional local non-requirement"),
        (device, "does not assert that any T18 device gate has passed", "T18 non-claim"),
        (live, "This revision cannot complete a shared-live run", "current live blocker"),
        (live, "UnavailableLiveRuntimeProvider", "current provider placeholder"),
    ]
    for text, phrase, description in required_phrases:
        normalized = " ".join(text.split())
        if phrase not in normalized:
            errors.append(f"runbooks missing {description}: {phrase!r}")


def lint(root: Path = ROOT) -> list[str]:
    root = root.resolve()
    errors: list[str] = []
    runbook_dir = root / "docs/runbooks"
    documents = {
        name: _read(runbook_dir / name, errors)
        for name in RUNBOOKS
    }
    unexpected = sorted(
        path.name
        for path in runbook_dir.glob("*.md")
        if path.name not in RUNBOOKS
    ) if runbook_dir.exists() else []
    if unexpected:
        errors.append(f"docs/runbooks: unvalidated markdown files: {unexpected}")
    combined = "\n".join(documents.values())

    _check_required_sections(documents, errors)
    _check_links(root, documents, errors)
    _check_references(root, combined, errors)
    _check_configuration(root, documents, combined, errors)
    _check_contract(root, documents, errors)
    _check_safety_and_boundaries(documents, combined, errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    errors = lint(args.root)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print("T19-02 runbook links, configuration, contract, and safety checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
