#!/usr/bin/env python3
"""Adversarial tests for the T03-02 contract lint."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class T0302LintTests(unittest.TestCase):
    def copied_repository(self) -> Path:
        directory = Path(tempfile.mkdtemp(prefix="teamd-t03-02-"))
        shutil.copytree(ROOT / "Contracts", directory / "Contracts")
        shutil.copy2(ROOT / "scripts" / "lint_t03_02.py", directory / "lint_t03_02.py")
        return directory

    def run_lint(self, directory: Path) -> subprocess.CompletedProcess[str]:
        scripts = directory / "scripts"
        scripts.mkdir(exist_ok=True)
        shutil.copy2(directory / "lint_t03_02.py", scripts / "lint_t03_02.py")
        return subprocess.run(["python3", str(scripts / "lint_t03_02.py")], cwd=directory, capture_output=True, text=True)

    def test_accepts_frozen_contract(self) -> None:
        directory = self.copied_repository()
        self.assertEqual(self.run_lint(directory).returncode, 0)

    def test_rejects_forbidden_path_and_png_hash_drift(self) -> None:
        directory = self.copied_repository()
        openapi = directory / "Contracts/HTTP/v1/openapi.json"
        openapi.write_text(openapi.read_text(encoding="utf-8").replace("/api/health", "/api/analyze-live"), encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)
        shutil.rmtree(directory)
        directory = self.copied_repository()
        png = directory / "Contracts/HTTP/v1/goldens/mask.response.png.json"
        value = json.loads(png.read_text(encoding="utf-8"))
        value["sha256"] = "0" * 64
        png.write_text(json.dumps(value), encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)

    def test_rejects_availability_and_background_semantic_drift(self) -> None:
        directory = self.copied_repository()
        availability = directory / "Contracts/HTTP/v1/availability.json"
        value = json.loads(availability.read_text(encoding="utf-8"))
        value["surfaces"]["analyze-shot"]["available"] = True
        availability.write_text(json.dumps(value), encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)

    def test_rejects_token_and_measurement_schema_mutations(self) -> None:
        directory = self.copied_repository()
        token = directory / "Contracts/HTTP/v1/goldens/token.response.json"
        value = json.loads(token.read_text(encoding="utf-8"))
        value["token"] = ""
        token.write_text(json.dumps(value), encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)

    def test_rejects_single_mime_schema_drift(self) -> None:
        directory = self.copied_repository()
        openapi = directory / "Contracts/HTTP/v1/openapi.json"
        value = json.loads(openapi.read_text(encoding="utf-8"))
        value["components"]["schemas"]["ImageRequest"]["properties"]["image"]["contentMediaType"] = "image/jpeg"
        openapi.write_text(json.dumps(value), encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)

    def test_rejects_multipart_content_type_and_rogue_part_key(self) -> None:
        directory = self.copied_repository()
        parts = directory / "Contracts/HTTP/v1/goldens/analyze-shot.request.parts.json"
        value = json.loads(parts.read_text(encoding="utf-8"))
        value["contentType"] = "application/json"
        parts.write_text(json.dumps(value), encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)
        shutil.rmtree(directory)
        directory = self.copied_repository()
        parts = directory / "Contracts/HTTP/v1/goldens/measurement.request.parts.json"
        value = json.loads(parts.read_text(encoding="utf-8"))
        value["parts"][0]["rogue"] = True
        parts.write_text(json.dumps(value), encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)
        shutil.rmtree(directory)
        directory = self.copied_repository()
        token = directory / "Contracts/HTTP/v1/goldens/token.response.json"
        value = json.loads(token.read_text(encoding="utf-8"))
        value["expiresAt"] = 0
        token.write_text(json.dumps(value), encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)
        shutil.rmtree(directory)
        directory = self.copied_repository()
        token = directory / "Contracts/HTTP/v1/goldens/token.response.json"
        value = json.loads(token.read_text(encoding="utf-8"))
        value["livekitUrl"] = "http://example.invalid"
        token.write_text(json.dumps(value), encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)
        shutil.rmtree(directory)
        directory = self.copied_repository()
        points = directory / "Contracts/HTTP/v1/goldens/measurement.response.json"
        value = json.loads(points.read_text(encoding="utf-8"))
        value["lengthStart"]["x"] = 1.01
        points.write_text(json.dumps(value), encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)
        shutil.rmtree(directory)
        directory = self.copied_repository()
        request = directory / "Contracts/HTTP/v1/goldens/background.request.json"
        request.write_text('{"styleId":"clean-white","image":"forbidden"}', encoding="utf-8")
        self.assertNotEqual(self.run_lint(directory).returncode, 0)


if __name__ == "__main__":
    unittest.main()
