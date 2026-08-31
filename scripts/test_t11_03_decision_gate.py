import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("t11_03_decision_gate.py")
SPEC = importlib.util.spec_from_file_location("t11_03_decision_gate", MODULE_PATH)
assert SPEC and SPEC.loader
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class DecisionGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.record = json.loads(gate.DEFAULT_RECORD.read_text(encoding="utf-8"))
        self.root = Path(tempfile.mkdtemp())
        (self.root / "Packages").mkdir()
        (self.root / "Packages/Package.swift").write_text("let package = Package()", encoding="utf-8")

    def test_current_blocked_record_is_valid_without_opencv(self) -> None:
        blockers = gate.validate(copy.deepcopy(self.record), self.root)
        self.assertIn("physical-corpus-shortfall:30:0", blockers)

    def test_blocked_record_cannot_select_an_engine(self) -> None:
        record = copy.deepcopy(self.record)
        record["decision"] = "apple-frameworks"
        with self.assertRaisesRegex(ValueError, "recorded decision"):
            gate.validate(record, self.root)

    def test_open_cv_dependency_is_rejected_before_selection(self) -> None:
        (self.root / "Packages/Package.swift").write_text(
            '.package(url: "https://example.invalid/opencv.git")',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "dependency/binary is forbidden"):
            gate.validate(copy.deepcopy(self.record), self.root)

    def test_recorded_blockers_must_equal_computed_blockers(self) -> None:
        record = copy.deepcopy(self.record)
        record["blockers"] = []
        with self.assertRaisesRegex(ValueError, "recorded blockers"):
            gate.validate(record, self.root)

    def test_passing_apple_evidence_computes_apple_selection(self) -> None:
        record = self.complete_physical_record()
        record["appleEvidence"] = self.evidence("apple-frameworks")
        record["status"] = "selected"
        record["decision"] = "apple-frameworks"
        record["blockers"] = []
        self.assertEqual(gate.computed_outcome(record), ("selected", "apple-frameworks", []))

    def test_apple_failure_without_open_cv_evidence_stays_blocked(self) -> None:
        record = self.complete_physical_record()
        record["appleEvidence"] = self.evidence("apple-frameworks")
        record["appleEvidence"]["validMarkerDetectionCount"] = 18
        self.assertEqual(
            gate.computed_outcome(record),
            ("blocked", None, ["engine-evidence-missing:opencv-ios"]),
        )

    def complete_physical_record(self) -> dict:
        record = copy.deepcopy(self.record)
        record["physicalCorpus"] = {
            "corpusFingerprint": "rights-cleared-corpus-v1",
            "captureCount": 30,
            "rightsClearedCount": 30,
            "piiClearedCount": 30,
            "rulerConfirmedMarkerSideMillimeters": 50.0,
            "annotationsComplete": True,
        }
        record["blockers"] = []
        return record

    @staticmethod
    def evidence(engine: str) -> dict:
        return {
            "engine": engine,
            "corpusFingerprint": "rights-cleared-corpus-v1",
            "totalCaseCount": 30,
            "validMarkerCaseCount": 20,
            "validMarkerDetectionCount": 20,
            "invalidMarkerCaseCount": 10,
            "invalidScaleAcceptanceCount": 0,
            "maximumRelativeScaleError": 0.005,
            "p95LatencyMilliseconds": 500.0,
            "rawMeasurementsComplete": True,
            "memoryEvidenceReviewed": True,
            "sharedContractSuitePassed": True,
        }


if __name__ == "__main__":
    unittest.main()
