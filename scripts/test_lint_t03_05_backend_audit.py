#!/usr/bin/env python3
"""Dedicated negative tests for the T03-05 semantic audit validator."""
from __future__ import annotations

import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/lint_t03_05_backend_audit.py"
SPEC = importlib.util.spec_from_file_location("lint_t03_05_backend_audit", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load T03-05 audit validator")
LINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINT)


class BackendSourceAuditValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.audit = json.loads(LINT.AUDIT_PATH.read_text())
        cls.availability = json.loads(LINT.AVAILABILITY_PATH.read_text())
        cls.openapi = json.loads(LINT.OPENAPI_PATH.read_text())
        cls.document = LINT.DOCUMENT_PATH.read_text()

    def assert_audit_rejected(self, mutate) -> None:
        candidate = copy.deepcopy(self.audit)
        mutate(candidate)
        with self.assertRaises(LINT.AuditValidationError):
            LINT.validate_audit(candidate)

    def assert_availability_rejected(self, mutate) -> None:
        candidate = copy.deepcopy(self.availability)
        mutate(candidate)
        with self.assertRaises(LINT.AuditValidationError):
            LINT.validate_availability(candidate)

    def assert_openapi_rejected(self, mutate) -> None:
        candidate = copy.deepcopy(self.openapi)
        mutate(candidate)
        with self.assertRaises(LINT.AuditValidationError):
            LINT.validate_openapi(candidate)

    def test_committed_artifacts_are_valid(self) -> None:
        LINT.validate_audit(self.audit)
        LINT.validate_availability(self.availability)
        LINT.validate_openapi(self.openapi)
        LINT.validate_document(self.document)
        LINT.validate_repository()

    def test_source_sha_and_production_pin_drift_are_rejected(self) -> None:
        self.assert_audit_rejected(lambda value: value["source"].update(sha="0" * 40))
        self.assert_audit_rejected(
            lambda value: value["productionRuntime"]["pins"].update(
                {"livekit-agents": "1.3.12"}
            )
        )
        self.assert_audit_rejected(
            lambda value: value["productionRuntime"]["pins"].pop("uvicorn")
        )

    def test_smoke_only_pins_cannot_replace_production(self) -> None:
        self.assert_audit_rejected(
            lambda value: value["smokeRuntime"].update(scope="production runtime pin")
        )
        self.assert_audit_rejected(
            lambda value: value["smokeRuntime"]["pins"].update(
                {"livekit-agents": "1.7.1"}
            )
        )

    def test_implemented_and_blocked_surface_sets_are_closed(self) -> None:
        self.assert_audit_rejected(lambda value: value["implemented"].pop())
        self.assert_audit_rejected(lambda value: value["blockers"].pop())
        self.assert_audit_rejected(
            lambda value: value["implemented"].append(
                copy.deepcopy(value["implemented"][0])
            )
        )
        self.assert_audit_rejected(
            lambda value: value["blockers"].append(copy.deepcopy(value["blockers"][0]))
        )

    def test_implemented_metadata_drift_is_rejected(self) -> None:
        fields = (
            "sourcePaths",
            "owner",
            "contract",
            "neededBy",
            "releaseCondition",
            "evidence",
        )
        for field in fields:
            with self.subTest(field=field):
                self.assert_audit_rejected(
                    lambda value, field=field: value["implemented"][0].update(
                        {field: [] if field == "sourcePaths" else "drifted"}
                    )
                )

    def test_blocker_metadata_drift_is_rejected(self) -> None:
        fields = ("sourcePaths", "owner", "contract", "neededBy", "releaseCondition")
        for field in fields:
            with self.subTest(field=field):
                self.assert_audit_rejected(
                    lambda value, field=field: value["blockers"][0].update(
                        {field: [] if field == "sourcePaths" else "drifted"}
                    )
                )

    def test_http_and_agent_availability_false_states_are_enforced(self) -> None:
        for name in (
            "analyze-shot",
            "suggest-measurement-points",
            "generate-background",
            "remove-background",
            "agent-guidance-push",
        ):
            with self.subTest(name=name):
                self.assert_availability_rejected(
                    lambda value, name=name: value["surfaces"][name].update(
                        available=True
                    )
                )

    def test_implemented_availability_cannot_be_hidden(self) -> None:
        for name in ("health", "livekit-token"):
            with self.subTest(name=name):
                self.assert_availability_rejected(
                    lambda value, name=name: value["surfaces"][name].update(
                        available=False
                    )
                )

    def test_availability_owner_and_release_condition_are_required(self) -> None:
        self.assert_availability_rejected(
            lambda value: value["surfaces"]["agent-guidance-push"].update(
                owner="Swift client"
            )
        )
        self.assert_availability_rejected(
            lambda value: value["surfaces"]["generate-background"].update(
                releaseCondition=""
            )
        )

    def test_openapi_version_and_surface_classification_must_align(self) -> None:
        self.assert_openapi_rejected(
            lambda value: value["info"].update(version="2.0.0")
        )
        self.assert_openapi_rejected(
            lambda value: value["paths"]["/api/generate-background"]["post"].update(
                {"x-team-d-availability": "implemented"}
            )
        )

        def replace_health_method(value) -> None:
            operation = value["paths"]["/api/health"].pop("get")
            value["paths"]["/api/health"]["post"] = operation

        self.assert_openapi_rejected(replace_health_method)

    def test_document_must_preserve_phase_one_and_pending_gate_semantics(self) -> None:
        for phrase in (
            "code_ready_unverified",
            "does not mean the lint/test was executed",
            "shared HTTPS FastAPI staging",
            "25 passed, 1 skipped",
        ):
            with self.subTest(phrase=phrase):
                candidate = self.document.replace(phrase, "")
                with self.assertRaises(LINT.AuditValidationError):
                    LINT.validate_document(candidate)


if __name__ == "__main__":
    unittest.main()
