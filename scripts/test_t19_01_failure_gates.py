#!/usr/bin/env python3
"""Prove schema, fixture-hash, and secret violations fail their CI gates."""

from __future__ import annotations

import json
import subprocess
import tarfile
import tempfile
from pathlib import Path


SOURCE_ROOT = Path(__file__).resolve().parents[1]


def run(root: Path, *command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=root, text=True, capture_output=True, check=False)


def archive_head(destination: Path) -> None:
    archive = destination.parent / "source.tar"
    with archive.open("wb") as stream:
        subprocess.run(["git", "archive", "--format=tar", "HEAD"], cwd=SOURCE_ROOT, stdout=stream, check=True)
    with tarfile.open(archive) as source:
        source.extractall(destination)


with tempfile.TemporaryDirectory(prefix="teamd-t19-01-negative-") as temporary:
    root = Path(temporary) / "repo"
    root.mkdir()
    archive_head(root)

    schema_gate = run(root, "python3", "scripts/lint_t03_02.py")
    assert schema_gate.returncode == 0, schema_gate.stdout + schema_gate.stderr
    openapi_path = root / "Contracts/HTTP/v1/openapi.json"
    openapi = json.loads(openapi_path.read_text(encoding="utf-8"))
    openapi["paths"]["/api/analyze-shot"]["post"]["x-team-d-timeout-seconds"] = 21
    openapi_path.write_text(json.dumps(openapi), encoding="utf-8")
    schema_failure = run(root, "python3", "scripts/lint_t03_02.py")
    assert schema_failure.returncode == 1
    assert "/api/analyze-shot: timeout" in schema_failure.stderr

    root = Path(temporary) / "hash-repo"
    root.mkdir()
    archive_head(root)
    hash_gate = run(root, "python3", "scripts/lint_t19_03_inventory.py")
    assert hash_gate.returncode == 0, hash_gate.stdout + hash_gate.stderr
    marker = root / "output/pdf/t11-01-50mm-marker.pdf"
    marker.write_bytes(marker.read_bytes() + b"hash-drift")
    hash_failure = run(root, "python3", "scripts/lint_t19_03_inventory.py")
    assert hash_failure.returncode == 1
    assert "marker PDF checksum drift" in hash_failure.stderr

    secret_file = root / "intentional-secret.txt"
    secret_value = "LIVEKIT_API_" + "SECRET=must-not-appear"
    secret_file.write_text(secret_value, encoding="utf-8")
    secret_failure = run(root, "python3", "scripts/ci_secret_scan.py", "--path", str(secret_file))
    assert secret_failure.returncode == 1
    assert "credential assignment" in secret_failure.stderr
    assert "must-not-appear" not in secret_failure.stdout + secret_failure.stderr

print("T19-01 intentional schema/hash/secret failure gates passed.")
