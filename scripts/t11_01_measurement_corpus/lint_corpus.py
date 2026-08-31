#!/usr/bin/env python3
"""Schema and deterministic-output lint for T11-01 measurement corpus."""
from __future__ import annotations

import argparse
import hashlib
import json
import tempfile
from pathlib import Path

import generate_synthetic

ROOT = Path(__file__).resolve().parents[2] / "Fixtures/MeasurementCorpus"
FAILURES = {"MARKER_MISSING", "MARKER_MULTIPLE", "MARKER_TOO_SMALL", "MARKER_OCCLUDED", "GARMENT_OUT_OF_FRAME", "GARMENT_MARKER_OVERLAP", "SEGMENTATION_FAILED", "ENDPOINTS_INVALID"}


def fail(message):
    raise ValueError(message)


def validate(manifest):
    if manifest.get("schemaVersion") != 1 or manifest.get("generator") != "generate_synthetic.py":
        fail("unsupported corpus schema or generator")
    if manifest.get("marker") != {"outerMm": 50.0, "blackFrameMm": 5.0, "whiteInnerMm": 40.0, "printScale": "100%"}:
        fail("marker must be 50.0mm outer / 5mm black frame / 40mm white inner at 100%")
    if set(manifest.get("failureCodes", [])) != FAILURES:
        fail("failureCodes must contain exactly the finite MeasurementFailure values")
    thresholds = manifest.get("thresholds")
    if thresholds != {"minimumMarkerSidePx": 80, "edgeMarginPx": 16, "minimumSideRatio": 0.65, "minimumGarmentMarkerGapPx": 24}:
        fail("thresholds do not match the frozen T11 values")
    ids = set()
    pair_coverage = {code: {True: 0, False: 0} for code in FAILURES}
    for case in manifest.get("cases", []):
        case_id = case.get("id")
        if not isinstance(case_id, str) or case_id in ids:
            fail("case IDs must be unique strings")
        ids.add(case_id)
        if not isinstance(case.get("sha256"), str) or len(case["sha256"]) != 64:
            fail(f"{case_id}: SHA-256 is required")
        failure = case.get("expectedFailure")
        if failure is not None and failure not in FAILURES:
            fail(f"{case_id}: unknown expected failure")
        corners = case.get("expectedCorners")
        if corners is not None:
            if not isinstance(corners, list) or len(corners) != 4:
                fail(f"{case_id}: requires four ordered corners")
            if any(not isinstance(point, list) or len(point) != 2 or not all(isinstance(value, int) and 0 <= value < 800 for value in point) for point in corners):
                fail(f"{case_id}: corners must be in image bounds")
            if not (corners[0][0] <= corners[1][0] and corners[0][1] <= corners[3][1]):
                fail(f"{case_id}: corners must use top-left, top-right, bottom-right, bottom-left order")
        if case.get("expectedScalePxPerCm") is not None and case["expectedScalePxPerCm"] <= 0:
            fail(f"{case_id}: scale must be positive")
        if not isinstance(case.get("expectedMask"), str) or not isinstance(case.get("expectedMeasurementsCm"), dict):
            fail(f"{case_id}: mask and real-world measurement expectations are required")
        for code, polarity in case.get("failurePair", {}).items():
            if code not in FAILURES or not isinstance(polarity, bool):
                fail(f"{case_id}: invalid failure pair")
            pair_coverage[code][polarity] += 1
    missing = [code for code, values in pair_coverage.items() if not values[True] or not values[False]]
    if missing:
        fail(f"missing positive/negative cases for: {', '.join(sorted(missing))}")


def lint_render(manifest, directory):
    generate_synthetic.generate(directory)
    for case in manifest["cases"]:
        path = directory / case["file"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != case["sha256"]:
            fail(f"{case['id']}: generated hash mismatch")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--render-dir", type=Path)
    args = parser.parse_args()
    manifest = json.loads((ROOT / "corpus-manifest.json").read_text(encoding="utf-8"))
    validate(manifest)
    if args.render_dir:
        lint_render(manifest, args.render_dir)
    else:
        with tempfile.TemporaryDirectory(prefix="teamd-t11-01-") as temp:
            lint_render(manifest, Path(temp))
    print(f"T11-01 corpus lint passed: {len(manifest['cases'])} deterministic synthetic cases.")


if __name__ == "__main__":
    main()
