#!/usr/bin/env python3
"""Build-free T11-03 evidence and dependency-graph decision guard."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RECORD = ROOT / "docs/architecture/t11-03-measurement-engine-decision.json"
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def load_record(path: Path) -> dict[str, Any]:
    record = json.loads(path.read_text(encoding="utf-8"))
    require(record.get("schemaVersion") == 1, "schemaVersion must be 1")
    require(record.get("task") == "T11-03", "task must be T11-03")
    require(record.get("status") in {"blocked", "selected", "fallbacks-required"}, "invalid status")
    return record


def corpus_blockers(record: dict[str, Any]) -> list[str]:
    thresholds = record["thresholds"]
    corpus = record["physicalCorpus"]
    required = thresholds["minimumPhysicalCaptureCount"]
    actual = corpus["captureCount"]
    blockers: list[str] = []
    if actual < required:
        blockers.append(f"physical-corpus-shortfall:{required}:{actual}")
    required_clearance = max(required, actual)
    if corpus["rightsClearedCount"] != actual or corpus["rightsClearedCount"] < required_clearance:
        blockers.append(f"rights-clearance-incomplete:{required_clearance}:{corpus['rightsClearedCount']}")
    if corpus["piiClearedCount"] != actual or corpus["piiClearedCount"] < required_clearance:
        blockers.append(f"pii-clearance-incomplete:{required_clearance}:{corpus['piiClearedCount']}")
    ruler = corpus["rulerConfirmedMarkerSideMillimeters"]
    marker_side = thresholds["markerSideMillimeters"]
    if not isinstance(ruler, (int, float)) or not math.isfinite(ruler) or abs(ruler - marker_side) > 0.000001:
        blockers.append(f"ruler-evidence-missing:{marker_side:.1f}")
    if not corpus["annotationsComplete"]:
        blockers.append("corpus-annotations-incomplete")
    if not isinstance(corpus["corpusFingerprint"], str) or not corpus["corpusFingerprint"].strip():
        blockers.append("corpus-fingerprint-missing")
    return blockers


def opencv_impact_complete(impact: dict[str, Any]) -> bool:
    return all((
        isinstance(impact["binarySizeDeltaBytes"], int) and impact["binarySizeDeltaBytes"] >= 0,
        isinstance(impact["cleanBuildTimeDeltaSeconds"], (int, float))
        and math.isfinite(impact["cleanBuildTimeDeltaSeconds"])
        and impact["cleanBuildTimeDeltaSeconds"] >= 0,
        bool(impact["artifactSource"]),
        isinstance(impact["artifactSHA256"], str) and SHA256.fullmatch(impact["artifactSHA256"]) is not None,
        bool(impact["licenseIdentifier"]),
        impact["licenseReview"] in {"compatible", "incompatible"},
        impact["noticeReview"] in {"not-required", "plan-recorded"},
        impact["privacyReview"] in {"passed", "failed"},
    ))


def evidence_blocker(
    evidence: dict[str, Any],
    engine: str,
    corpus: dict[str, Any],
) -> str | None:
    if evidence.get("engine") != engine:
        return f"engine-evidence-incomplete:{engine}"
    if evidence.get("corpusFingerprint") != corpus.get("corpusFingerprint"):
        return f"corpus-mismatch:{engine}"
    total = evidence.get("totalCaseCount")
    valid = evidence.get("validMarkerCaseCount")
    detected = evidence.get("validMarkerDetectionCount")
    invalid = evidence.get("invalidMarkerCaseCount")
    invalid_accepted = evidence.get("invalidScaleAcceptanceCount")
    complete = all((
        isinstance(total, int) and total == corpus["captureCount"],
        isinstance(valid, int) and valid > 0,
        isinstance(detected, int) and isinstance(valid, int) and 0 <= detected <= valid,
        isinstance(invalid, int) and invalid > 0,
        isinstance(invalid_accepted, int) and isinstance(invalid, int) and 0 <= invalid_accepted <= invalid,
        isinstance(valid, int) and isinstance(invalid, int) and valid + invalid == total,
        isinstance(evidence.get("maximumRelativeScaleError"), (int, float))
        and math.isfinite(evidence["maximumRelativeScaleError"])
        and evidence["maximumRelativeScaleError"] >= 0,
        isinstance(evidence.get("p95LatencyMilliseconds"), (int, float))
        and math.isfinite(evidence["p95LatencyMilliseconds"])
        and evidence["p95LatencyMilliseconds"] >= 0,
        evidence.get("rawMeasurementsComplete") is True,
        evidence.get("memoryEvidenceReviewed") is True,
    ))
    return None if complete else f"engine-evidence-incomplete:{engine}"


def criterion_failures(
    evidence: dict[str, Any],
    thresholds: dict[str, Any],
) -> list[str]:
    failures: list[str] = []
    if evidence.get("sharedContractSuitePassed") is not True:
        failures.append("shared-contract-suite")
    detection_rate = evidence["validMarkerDetectionCount"] / evidence["validMarkerCaseCount"]
    if detection_rate < thresholds["minimumValidDetectionRate"]:
        failures.append("valid-marker-detection-rate")
    if evidence["invalidScaleAcceptanceCount"] > thresholds["maximumInvalidScaleAcceptances"]:
        failures.append("invalid-scale-acceptance")
    if evidence["maximumRelativeScaleError"] > thresholds["maximumRelativeScaleError"]:
        failures.append("relative-scale-error")
    if evidence["p95LatencyMilliseconds"] > thresholds["maximumP95LatencyMilliseconds"]:
        failures.append("p95-latency")
    return failures


def computed_outcome(record: dict[str, Any]) -> tuple[str, str | None, list[str]]:
    thresholds = record["thresholds"]
    corpus = record["physicalCorpus"]
    blockers = corpus_blockers(record)
    if blockers:
        return "blocked", None, blockers

    apple = record["appleEvidence"]
    if apple is None:
        return "blocked", None, ["engine-evidence-missing:apple-frameworks"]
    blocker = evidence_blocker(apple, "apple-frameworks", corpus)
    if blocker:
        return "blocked", None, [blocker]
    apple_failures = criterion_failures(apple, thresholds)
    if not apple_failures:
        return "selected", "apple-frameworks", []

    open_cv = record["openCVEvidence"]
    if open_cv is None:
        return "blocked", None, ["engine-evidence-missing:opencv-ios"]
    blocker = evidence_blocker(open_cv, "opencv-ios", corpus)
    if blocker:
        return "blocked", None, [blocker]
    impact = record["openCVAdoptionImpact"]
    if not isinstance(impact, dict) or not opencv_impact_complete(impact):
        return "blocked", None, ["opencv-impact-incomplete"]
    open_cv_failures = criterion_failures(open_cv, thresholds)
    if impact["licenseReview"] != "compatible" or impact["privacyReview"] != "passed":
        open_cv_failures.append("distribution-review")
    if open_cv_failures:
        return "fallbacks-required", "product-fallbacks", []
    if impact["adoptionApproved"] is not True:
        return "blocked", None, ["opencv-adoption-approval-missing"]
    return "selected", "opencv-ios", []


def dependency_graph_has_opencv(root: Path) -> bool:
    dependency_files = [
        root / "Packages/Package.swift",
        root / "Packages/Package.resolved",
        root / "TeamD.xcodeproj/project.pbxproj",
    ]
    for path in dependency_files:
        if path.is_file() and "opencv" in path.read_text(encoding="utf-8", errors="ignore").casefold():
            return True
    binary_suffixes = {".a", ".dylib", ".framework", ".xcframework"}
    return any(
        "opencv" in path.as_posix().casefold()
        for path in root.rglob("*")
        if path.suffix.casefold() in binary_suffixes
    )


def validate(record: dict[str, Any], root: Path) -> list[str]:
    require(record["analysisContract"] == {
        "knownMarkerSideCentimeters": 5.0,
        "minimumMarkerSidePixels": 80.0,
        "edgeMarginPixelsExclusive": 16.0,
        "minimumMarkerSideRatio": 0.65,
        "minimumGarmentMarkerGapPixels": 24.0,
        "finiteFailureCount": 8,
    }, "engine-neutral measurement contract changed")
    thresholds = record["thresholds"]
    require(thresholds == {
        "minimumPhysicalCaptureCount": 30,
        "markerSideMillimeters": 50.0,
        "minimumValidDetectionRate": 0.95,
        "maximumInvalidScaleAcceptances": 0,
        "maximumRelativeScaleError": 0.01,
        "maximumP95LatencyMilliseconds": 1000.0,
    }, "T11-02 thresholds changed")

    status, decision, blockers = computed_outcome(record)
    require(record["status"] == status, "recorded status does not match computed outcome")
    require(record["decision"] == decision, "recorded decision does not match computed outcome")
    require(record["blockers"] == blockers, "recorded blockers do not match computed blockers")
    has_opencv = dependency_graph_has_opencv(root)

    if blockers:
        require(not has_opencv, "OpenCV dependency/binary is forbidden before the gate selects it")
    elif decision == "apple-frameworks":
        require(not has_opencv, "Apple selection must not retain OpenCV in the dependency graph")
    elif decision == "opencv-ios":
        require(opencv_impact_complete(record["openCVAdoptionImpact"]), "OpenCV adoption impact is incomplete")
        require(record["openCVAdoptionImpact"]["adoptionApproved"] is True, "OpenCV adoption is not approved")
        require(has_opencv, "selected OpenCV engine is absent from the dependency graph")
    else:
        require(not has_opencv, "fallback decision must not retain OpenCV in the dependency graph")
    return blockers


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--record", type=Path, default=DEFAULT_RECORD)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--expect-status", choices=("blocked", "selected", "fallbacks-required"))
    args = parser.parse_args()
    try:
        record = load_record(args.record)
        blockers = validate(record, args.root)
        if args.expect_status:
            require(record["status"] == args.expect_status, f"expected status {args.expect_status}")
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"T11-03 decision gate: {record['status']} ({len(blockers)} blocker(s)); dependency graph guarded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
