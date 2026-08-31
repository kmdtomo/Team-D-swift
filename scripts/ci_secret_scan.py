#!/usr/bin/env python3
"""Scan tracked source, fixture artifacts, logs, and app products without echoing values."""

from __future__ import annotations

import argparse
import importlib.util
import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFY_SCRIPT = ROOT / "scripts/verify_t03_03.py"
SPEC = importlib.util.spec_from_file_location("teamd_t03_secret_boundary", VERIFY_SCRIPT)
VERIFY = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(VERIFY)

GITHUB_CREDENTIAL_PATTERN = re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")
AUTHORIZATION = re.compile(r"(?i)authorization\s*:\s*bearer\s+([^\s\"']+)")
SAFE_REFERENCES = ("${{", "$TEAM_D_", "<redacted>", "example.invalid", "synthetic.not-a-secret")


def iter_files(path: Path):
    if path.is_symlink():
        return
    if path.is_file():
        yield path
        return
    if path.is_dir():
        for child in sorted(path.rglob("*")):
            if child.is_file() and not child.is_symlink():
                yield child


def label(path: Path) -> str:
    try:
        return path.resolve().relative_to(ROOT.resolve()).as_posix()
    except ValueError:
        return path.name


def scan(path: Path) -> list[str]:
    value = VERIFY.scanned_file_content(path)
    categories = list(VERIFY.findings(value))
    if GITHUB_CREDENTIAL_PATTERN.search(value):
        categories.append("GitHub token")
    for match in AUTHORIZATION.finditer(value):
        candidate = match.group(1)
        if not any(marker in candidate for marker in SAFE_REFERENCES):
            categories.append("Authorization bearer")
    if path.suffix == ".plist":
        try:
            VERIFY.check_plist(Path(label(path)), plistlib.loads(path.read_bytes()))
        except plistlib.InvalidFileException:
            pass
        except SystemExit:
            categories.append("sensitive plist field")
    return sorted(set(categories))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tracked", action="store_true", help="scan every Git-tracked file")
    parser.add_argument("--path", action="append", default=[], type=Path, help="scan a file or directory recursively")
    args = parser.parse_args()
    if not args.tracked and not args.path:
        parser.error("at least one --tracked or --path input is required")

    requested: list[Path] = []
    if args.tracked:
        requested.extend(VERIFY.tracked_paths())
    for path in args.path:
        resolved = path if path.is_absolute() else ROOT / path
        if not resolved.exists():
            raise SystemExit(f"secret scan input does not exist: {label(resolved)}")
        requested.extend(iter_files(resolved))

    findings: list[str] = []
    seen: set[Path] = set()
    for path in requested:
        resolved = path.resolve()
        if resolved in seen or not resolved.is_file():
            continue
        seen.add(resolved)
        categories = scan(resolved)
        if categories:
            findings.append(f"{label(resolved)}: {', '.join(categories)}")
    if findings:
        print("T19-01 secret scan failed (values suppressed):", *findings, sep="\n", file=sys.stderr)
        raise SystemExit(1)
    print(f"T19-01 secret scan passed for {len(seen)} files.")


if __name__ == "__main__":
    main()
