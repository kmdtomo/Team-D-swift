#!/usr/bin/env python3
"""Negative tests for the T19-02 runbook validator (Phase 2 execution)."""
from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

import lint_t19_02_runbooks as validator


SOURCE_ROOT = Path(__file__).resolve().parent.parent


class RunbookValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "repo"
        shutil.copytree(
            SOURCE_ROOT,
            self.root,
            ignore=shutil.ignore_patterns(".git", ".build", "DerivedData", "__pycache__", "*.pyc"),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def errors(self) -> list[str]:
        return validator.lint(self.root)

    def replace(self, relative: str, old: str, new: str) -> None:
        path = self.root / relative
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text, f"test mutation prerequisite missing: {old!r}")
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def test_current_repository_fixture_passes(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_rejects_broken_relative_link(self) -> None:
        self.replace(
            "docs/runbooks/README.md",
            "(fixture.md)",
            "(missing-fixture.md)",
        )
        self.assertTrue(any("missing link target" in error for error in self.errors()))

    def test_rejects_missing_command_reference(self) -> None:
        self.replace(
            "docs/runbooks/README.md",
            "scripts/lint_t19_02_runbooks.py",
            "scripts/missing_t19_02_lint.py",
        )
        self.assertTrue(any("missing repository path" in error for error in self.errors()))

    def test_rejects_documented_app_key_drift(self) -> None:
        self.replace(
            "docs/runbooks/live.md",
            "TEAM_D_BACKEND_BASE_URL",
            "TEAM_D_API_BASE_URL",
        )
        self.assertTrue(any("configuration keys differ" in error for error in self.errors()))

    def test_rejects_prohibited_secret_assignment(self) -> None:
        path = self.root / "docs/runbooks/live.md"
        unsafe_assignment = "export LIVEKIT_API_" + "SECRET='unsafe'\n"
        path.write_text(
            path.read_text(encoding="utf-8") + "\n```sh\n" + unsafe_assignment + "```\n",
            encoding="utf-8",
        )
        self.assertTrue(any("prohibited credential" in error for error in self.errors()))

    def test_rejects_secret_assigned_to_app_setting(self) -> None:
        path = self.root / "docs/runbooks/live.md"
        unsafe_reference = "$LIVEKIT_API_" + "SECRET"
        path.write_text(
            path.read_text(encoding="utf-8")
            + "\n```sh\nexport TEAM_D_LIVEKIT_URL=\""
            + unsafe_reference
            + "\"\n```\n",
            encoding="utf-8",
        )
        self.assertTrue(any("app build setting" in error for error in self.errors()))

    def test_rejects_local_backend_without_optional_label(self) -> None:
        self.replace(
            "docs/runbooks/optional-local-backend.md",
            "**OPTIONAL:**",
            "Required:",
        )
        self.assertTrue(any("optional local label" in error for error in self.errors()))

    def test_rejects_fixture_live_boundary_removal(self) -> None:
        self.replace(
            "docs/runbooks/fixture.md",
            "Fixture success is fixture evidence only",
            "Fixture success is sufficient evidence",
        )
        self.assertTrue(any("fixture evidence boundary" in error for error in self.errors()))

    def test_rejects_missing_required_section(self) -> None:
        self.replace(
            "docs/runbooks/troubleshooting-and-privacy.md",
            "## Session data and privacy",
            "## Data notes",
        )
        self.assertTrue(any("missing or out-of-order" in error for error in self.errors()))

    def test_rejects_contract_timeout_drift(self) -> None:
        self.replace(
            "docs/runbooks/troubleshooting-and-privacy.md",
            "`POST /api/generate-background` | 60 s",
            "`POST /api/generate-background` | 45 s",
        )
        self.assertTrue(any("generate-background" in error and "timeout" in error for error in self.errors()))

    def test_rejects_availability_claim_drift(self) -> None:
        self.replace(
            "docs/runbooks/live.md",
            "`POST /api/remove-background` | unavailable",
            "`POST /api/remove-background` | available",
        )
        self.assertTrue(any("remove-background availability" in error for error in self.errors()))


if __name__ == "__main__":
    unittest.main()
