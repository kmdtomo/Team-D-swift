#!/usr/bin/env python3
"""Strict schema, geometry, provenance, and deterministic-output lint for T11-01."""
from __future__ import annotations
import argparse, csv, hashlib, json, math, re, tempfile, zlib
from pathlib import Path
import generate_synthetic

ROOT = Path(__file__).resolve().parents[2] / "Fixtures/MeasurementCorpus"
REPO = ROOT.parents[1]
FAILURES = {"MARKER_MISSING","MARKER_MULTIPLE","MARKER_TOO_SMALL","MARKER_OCCLUDED","GARMENT_OUT_OF_FRAME","GARMENT_MARKER_OVERLAP","SEGMENTATION_FAILED","ENDPOINTS_INVALID"}
CASE_KEYS = {"id","file","sha256","markerMode","markerGeometry","markerCorners","expectedCorners","renderedScalePxPerCm","scaleAccepted","annotationId","expectedFailure","failurePair","boundary","qualityHint","garmentMode","qualityFlag"}
SHA = re.compile(r"^[0-9a-f]{64}$")
LOG_COLUMNS = ["capture_id","image_path","image_sha256","marker_print_id","device_model","ios_version","distance_band","tilt_band","lighting_band","scenario","expected_failure","observed_failure","corners_tl_tr_br_bl","scale_px_per_cm","mask_status","measurement_endpoints","length_cm","width_cm","rights_checked","rights_basis","pii_checked","annotation_complete","notes"]
MARKER_LOG_COLUMNS = ["marker_print_id","marker_pdf_sha256","print_scale_percent","ruler_measurement_mm","evidence_path","evidence_sha256","rights_checked","rights_basis","pii_checked","review_complete","notes"]
CAPTURE_ID = re.compile(r"^physical-[a-z0-9]+(?:-[a-z0-9]+)*$")
MARKER_PRINT_ID = re.compile(r"^marker-print-[a-z0-9]+(?:-[a-z0-9]+)*$")
IOS_VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")
CAPTURE_EXTENSIONS = {".heic", ".heif", ".jpg", ".jpeg", ".png"}
EVIDENCE_EXTENSIONS = CAPTURE_EXTENSIONS | {".pdf"}
DISTANCE_BANDS = {"close", "medium", "far"}
TILT_BANDS = {"overhead", "slight"}
LIGHTING_BANDS = {"bright-indoor", "diffuse-indoor", "dim-indoor"}
PHYSICAL_SCENARIOS = {
    "valid", "perspective-valid", "dark", "blur", "marker-missing",
    "marker-multiple", "marker-too-small-79px", "marker-occluded",
    "garment-out-of-frame", "segmentation-failed", "endpoints-invalid",
    "edge-16px", "ratio-0649", "overlap-23px",
}
PHYSICAL_FAILURES = {
    "marker-missing": "MARKER_MISSING",
    "marker-multiple": "MARKER_MULTIPLE",
    "marker-too-small-79px": "MARKER_TOO_SMALL",
    "marker-occluded": "MARKER_OCCLUDED",
    "garment-out-of-frame": "GARMENT_OUT_OF_FRAME",
    "segmentation-failed": "SEGMENTATION_FAILED",
    "endpoints-invalid": "ENDPOINTS_INVALID",
    "edge-16px": "MARKER_MISSING",
    "ratio-0649": "MARKER_MISSING",
    "overlap-23px": "GARMENT_MARKER_OVERLAP",
}
CORE_BUCKETS = {
    "valid-close-slight-bright": 6,
    "valid-medium-overhead-diffuse": 6,
    "valid-far-slight-dim": 6,
    "perspective-valid": 4,
    "dark": 4,
    "blur": 4,
}
BOUNDARY_CASES = {
    "marker-too-small-79px":{"minimumMarkerSidePx":79},
    "marker-at-80px":{"minimumMarkerSidePx":80},
    "edge-16px":{"edgeMarginPx":16,"compatibilityMapping":"no valid marker candidate accepted"},
    "edge-17px":{"edgeMarginPx":17},
    "ratio-0649":{"sideRatio":.649,"compatibilityMapping":"no valid marker candidate accepted"},
    "ratio-0650":{"sideRatio":.650},
    "overlap-23px":{"garmentMarkerGapPx":23},
    "overlap-24px":{"garmentMarkerGapPx":24},
}
SCENARIO_RULES = {
    "valid": {"markerMode":"valid","garmentMode":None,"expectedFailure":None,"failurePair":{"MARKER_MISSING":False,"MARKER_MULTIPLE":False,"MARKER_TOO_SMALL":False,"MARKER_OCCLUDED":False,"GARMENT_OUT_OF_FRAME":False,"GARMENT_MARKER_OVERLAP":False,"SEGMENTATION_FAILED":False,"ENDPOINTS_INVALID":False},"boundary":None},
    "marker-missing": {"markerMode":"none","garmentMode":None,"expectedFailure":"MARKER_MISSING","failurePair":{"MARKER_MISSING":True},"boundary":None},
    "marker-multiple": {"markerMode":"multiple","garmentMode":None,"expectedFailure":"MARKER_MULTIPLE","failurePair":{"MARKER_MULTIPLE":True},"boundary":None},
    "marker-too-small-79px": {"markerMode":"valid","garmentMode":None,"expectedFailure":"MARKER_TOO_SMALL","failurePair":{"MARKER_TOO_SMALL":True},"boundary":{"minimumMarkerSidePx":79}},
    "marker-at-80px": {"markerMode":"valid","garmentMode":None,"expectedFailure":None,"failurePair":{"MARKER_TOO_SMALL":False},"boundary":{"minimumMarkerSidePx":80}},
    "marker-occluded": {"markerMode":"occluded","garmentMode":None,"expectedFailure":"MARKER_OCCLUDED","failurePair":{"MARKER_OCCLUDED":True},"boundary":None},
    "garment-out-of-frame": {"markerMode":"valid","garmentMode":"out_of_frame","expectedFailure":"GARMENT_OUT_OF_FRAME","failurePair":{"GARMENT_OUT_OF_FRAME":True},"boundary":None},
    "segmentation-failed": {"markerMode":"valid","garmentMode":"low_contrast","expectedFailure":"SEGMENTATION_FAILED","failurePair":{"SEGMENTATION_FAILED":True},"boundary":None},
    "endpoints-invalid": {"markerMode":"valid","garmentMode":"endpoint_invalid","expectedFailure":"ENDPOINTS_INVALID","failurePair":{"ENDPOINTS_INVALID":True},"boundary":None},
    "edge-16px": {"markerMode":"valid","garmentMode":None,"expectedFailure":"MARKER_MISSING","failurePair":{},"boundary":{"edgeMarginPx":16,"compatibilityMapping":"no valid marker candidate accepted"}},
    "edge-17px": {"markerMode":"valid","garmentMode":None,"expectedFailure":None,"failurePair":{},"boundary":{"edgeMarginPx":17}},
    "ratio-0649": {"markerMode":"valid","garmentMode":None,"expectedFailure":"MARKER_MISSING","failurePair":{},"boundary":{"sideRatio":.649,"compatibilityMapping":"no valid marker candidate accepted"}},
    "ratio-0650": {"markerMode":"valid","garmentMode":None,"expectedFailure":None,"failurePair":{},"boundary":{"sideRatio":.650}},
    "overlap-23px": {"markerMode":"valid","garmentMode":None,"expectedFailure":"GARMENT_MARKER_OVERLAP","failurePair":{"GARMENT_MARKER_OVERLAP":True},"boundary":{"garmentMarkerGapPx":23}},
    "overlap-24px": {"markerMode":"valid","garmentMode":None,"expectedFailure":None,"failurePair":{"GARMENT_MARKER_OVERLAP":False},"boundary":{"garmentMarkerGapPx":24}},
}

def fail(message): raise ValueError(f"T11-01 corpus lint: {message}")
def point(value): return isinstance(value,list) and len(value)==2 and all(not isinstance(v,bool) and isinstance(v,(int,float)) and math.isfinite(v) for v in value)
def distance(a,b): return math.hypot(a[0]-b[0],a[1]-b[1])
def polygon_area(points): return sum(a[0]*b[1]-a[1]*b[0] for a,b in zip(points,points[1:]+points[:1])) / 2
def finite_geometry(value):
    return isinstance(value,dict) and set(value) in ({"x","y","side"},{"x","y","side","height"}) and all(isinstance(v,(int,float)) and math.isfinite(v) for v in value.values()) and value["side"] > 0 and value.get("height",value["side"]) > 0

def strict_number(value, label, *, positive=False):
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        fail(f"{label}: expected a finite number")
    if not math.isfinite(parsed) or (positive and parsed <= 0): fail(f"{label}: expected a finite positive number")
    return parsed

def strict_true(value, label):
    if value != "true": fail(f"{label}: must be literal true after human review")

def parsed_json(value, label):
    try:
        return json.loads(value)
    except (TypeError, json.JSONDecodeError):
        fail(f"{label}: must be valid JSON")

def validated_relative_path(value, extensions, label):
    if not isinstance(value, str) or not value or "\\" in value: fail(f"{label}: path must be a nonempty POSIX relative path")
    path = Path(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts): fail(f"{label}: path traversal/absolute paths are forbidden")
    if path.suffix.lower() not in extensions: fail(f"{label}: unsupported file extension")
    return path

def file_has_expected_magic(path):
    data = path.read_bytes()[:32]
    suffix = path.suffix.lower()
    if suffix in {".jpg", ".jpeg"}: return data.startswith(b"\xff\xd8\xff")
    if suffix == ".png": return data.startswith(b"\x89PNG\r\n\x1a\n")
    if suffix in {".heic", ".heif"}: return len(data) >= 12 and data[4:8] == b"ftyp"
    if suffix == ".pdf": return data.startswith(b"%PDF-")
    return False

def verified_external_file(root, relative, expected_hash, label):
    root = root.resolve()
    try:
        root.relative_to(REPO.resolve())
    except ValueError:
        pass
    else:
        fail("physical evidence root must remain outside the repository")
    target = (root / relative).resolve()
    try:
        target.relative_to(root)
    except ValueError:
        fail(f"{label}: resolved path escapes the physical evidence root")
    if not target.is_file(): fail(f"{label}: referenced external file is missing")
    if not file_has_expected_magic(target): fail(f"{label}: file signature does not match its approved image/PDF extension")
    if hashlib.sha256(target.read_bytes()).hexdigest() != expected_hash: fail(f"{label}: external file hash mismatch")

def csv_rows(path, columns, label):
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != columns: fail(f"{label} schema/columns are incomplete")
        rows = list(reader)
    for index, row in enumerate(rows, 2):
        if None in row or any(value is None for value in row.values()): fail(f"{label} row {index}: malformed CSV columns")
    return rows

def validate_marker_log(path, marker_pdf_sha256, physical_root=None):
    records, verified_ids, paths, hashes = {}, set(), set(), set()
    for index, row in enumerate(csv_rows(path, MARKER_LOG_COLUMNS, "marker print evidence log"), 2):
        label = f"marker print evidence row {index}"
        marker_id = row["marker_print_id"]
        if not MARKER_PRINT_ID.fullmatch(marker_id) or marker_id in records: fail(f"{label}: marker_print_id must be unique and non-identifying")
        if row["marker_pdf_sha256"] != marker_pdf_sha256: fail(f"{label}: marker PDF hash is not the frozen T11-01 artifact")
        if strict_number(row["print_scale_percent"], f"{label} print scale") != 100.0: fail(f"{label}: marker must be printed at 100 percent")
        if strict_number(row["ruler_measurement_mm"], f"{label} ruler measurement", positive=True) != 50.0: fail(f"{label}: ruler measurement must be 50.0mm")
        evidence_path = validated_relative_path(row["evidence_path"], EVIDENCE_EXTENSIONS, f"{label} evidence_path")
        evidence_hash = row["evidence_sha256"]
        if not SHA.fullmatch(evidence_hash): fail(f"{label}: evidence SHA-256 is invalid")
        if str(evidence_path) in paths or evidence_hash in hashes: fail(f"{label}: evidence path/hash must be unique")
        strict_true(row["rights_checked"], f"{label} rights_checked")
        if row["rights_basis"] != "first-party-capture": fail(f"{label}: ruler evidence must be a first-party capture")
        strict_true(row["pii_checked"], f"{label} pii_checked")
        strict_true(row["review_complete"], f"{label} review_complete")
        if physical_root is not None:
            verified_external_file(physical_root, evidence_path, evidence_hash, label)
            verified_ids.add(marker_id)
        paths.add(str(evidence_path)); hashes.add(evidence_hash); records[marker_id] = row
    return records, verified_ids

def validate_corners(value, label):
    corners = parsed_json(value, label)
    if not isinstance(corners, list) or len(corners) != 4 or not all(point(item) and all(component >= 0 for component in item) for item in corners): fail(f"{label}: corners must be four finite nonnegative TL/TR/BR/BL points")
    if polygon_area(corners) <= 0: fail(f"{label}: corners must be ordered TL/TR/BR/BL clockwise in image coordinates")
    return corners

def validate_endpoints(value, label):
    endpoints = parsed_json(value, label)
    expected = {"lengthStart", "lengthEnd", "widthStart", "widthEnd"}
    if not isinstance(endpoints, dict) or set(endpoints) != expected or not all(point(item) and all(component >= 0 for component in item) for item in endpoints.values()): fail(f"{label}: endpoints must be four finite nonnegative pixel points")

def core_bucket(row):
    scenario = row["scenario"]
    if scenario != "valid": return scenario if scenario in {"perspective-valid", "dark", "blur"} else None
    conditions = (row["distance_band"], row["tilt_band"], row["lighting_band"])
    return {
        ("close", "slight", "bright-indoor"): "valid-close-slight-bright",
        ("medium", "overhead", "diffuse-indoor"): "valid-medium-overhead-diffuse",
        ("far", "slight", "dim-indoor"): "valid-far-slight-dim",
    }.get(conditions)

def lint_log(path=None, marker_path=None, physical_root=None):
    path = path or Path(__file__).parent / "physical-corpus-log.csv"
    marker_path = marker_path or Path(__file__).parent / "marker-print-evidence.csv"
    marker_hash = json.loads((ROOT / "corpus-manifest.json").read_text(encoding="utf-8"))["artifacts"][0]["sha256"]
    marker_records, verified_markers = validate_marker_log(marker_path, marker_hash, physical_root)
    rows = csv_rows(path, LOG_COLUMNS, "physical corpus log")
    ids, paths, hashes, verified_captures = set(), set(), set(), set()
    distribution = {name: 0 for name in CORE_BUCKETS}
    for index, row in enumerate(rows, 2):
        label = f"physical corpus row {index}"
        capture_id = row["capture_id"]
        if not CAPTURE_ID.fullmatch(capture_id) or capture_id in ids: fail(f"{label}: capture_id must be unique and non-identifying")
        image_path = validated_relative_path(row["image_path"], CAPTURE_EXTENSIONS, f"{label} image_path")
        image_hash = row["image_sha256"]
        if not SHA.fullmatch(image_hash): fail(f"{label}: image SHA-256 is invalid")
        if str(image_path) in paths or image_hash in hashes: fail(f"{label}: image path/hash must be unique")
        if row["marker_print_id"] not in marker_records: fail(f"{label}: marker_print_id has no reviewed 50.0mm ruler evidence")
        if not row["device_model"].startswith("iPhone") or "simulator" in row["device_model"].lower(): fail(f"{label}: device_model must identify a physical iPhone model")
        if not IOS_VERSION.fullmatch(row["ios_version"]): fail(f"{label}: ios_version is invalid")
        if row["distance_band"] not in DISTANCE_BANDS or row["tilt_band"] not in TILT_BANDS or row["lighting_band"] not in LIGHTING_BANDS: fail(f"{label}: distance/tilt/lighting bands are outside the runbook vocabulary")
        scenario = row["scenario"]
        if scenario not in PHYSICAL_SCENARIOS: fail(f"{label}: scenario is not an approved T11-01 physical case")
        expected_failure = row["expected_failure"] or None
        observed_failure = row["observed_failure"] or None
        if expected_failure not in FAILURES | {None} or observed_failure not in FAILURES | {None}: fail(f"{label}: failure code is not finite")
        if expected_failure != PHYSICAL_FAILURES.get(scenario): fail(f"{label}: expected failure does not match the scenario")
        marker_unavailable = scenario in {"marker-missing", "marker-multiple", "marker-occluded"}
        if marker_unavailable:
            if row["corners_tl_tr_br_bl"] or row["scale_px_per_cm"]: fail(f"{label}: ambiguous/unavailable marker must not publish one corner/scale result")
        else:
            validate_corners(row["corners_tl_tr_br_bl"], f"{label} corners")
            strict_number(row["scale_px_per_cm"], f"{label} scale_px_per_cm", positive=True)
        expected_mask = {
            "dark": "quality_rejected",
            "blur": "quality_rejected",
            "garment-out-of-frame": "garment_clipped",
            "segmentation-failed": "segmentation_failed",
        }.get(scenario, "garment_complete")
        if row["mask_status"] != expected_mask: fail(f"{label}: mask_status does not match the reviewed core/quality annotation")
        if scenario in {"garment-out-of-frame", "segmentation-failed"}:
            if row["measurement_endpoints"]: fail(f"{label}: unavailable garment geometry must not invent endpoints")
        else:
            validate_endpoints(row["measurement_endpoints"], f"{label} measurement_endpoints")
        strict_number(row["length_cm"], f"{label} length_cm", positive=True)
        strict_number(row["width_cm"], f"{label} width_cm", positive=True)
        strict_true(row["rights_checked"], f"{label} rights_checked")
        if row["rights_basis"] not in {"first-party-capture", "documented-license"}: fail(f"{label}: rights_basis must state first-party capture or a documented license")
        if row["rights_basis"] == "documented-license" and not row["notes"].strip(): fail(f"{label}: documented-license requires a non-identifying license reference in notes")
        strict_true(row["pii_checked"], f"{label} pii_checked")
        strict_true(row["annotation_complete"], f"{label} annotation_complete")
        if physical_root is not None:
            verified_external_file(physical_root, image_path, image_hash, label)
            verified_captures.add(capture_id)
        bucket = core_bucket(row)
        if bucket is not None: distribution[bucket] += 1
        ids.add(capture_id); paths.add(str(image_path)); hashes.add(image_hash)
    missing = {name: required - distribution[name] for name, required in CORE_BUCKETS.items() if distribution[name] < required}
    core_ids = {row["capture_id"] for row in rows if core_bucket(row) is not None}
    linked_to_verified_marker = all(row["marker_print_id"] in verified_markers for row in rows if core_bucket(row) is not None)
    ready = not missing and physical_root is not None and core_ids.issubset(verified_captures) and linked_to_verified_marker
    blockers = []
    if missing: blockers.append(f"required core matrix {len(core_ids)}/30; missing distribution: " + ", ".join(f"{name} {distribution[name]}/{CORE_BUCKETS[name]}" for name in CORE_BUCKETS if name in missing))
    if physical_root is None: blockers.append("external physical evidence root was not supplied, so image/evidence hashes are unverified")
    elif not core_ids.issubset(verified_captures): blockers.append("one or more core capture files are not hash-verified")
    if not marker_records: blockers.append("no reviewed ruler-confirmed 50.0mm marker print evidence")
    elif physical_root is not None and not linked_to_verified_marker: blockers.append("one or more core captures are not linked to hash-verified ruler evidence")
    return {
        "status": "ready" if ready else "blocked",
        "reviewedCaptures": len(rows),
        "reviewedCoreCaptures": len(core_ids),
        "fileVerifiedCaptures": len(verified_captures),
        "reviewedMarkerPrints": len(marker_records),
        "fileVerifiedMarkerPrints": len(verified_markers),
        "distribution": distribution,
        "blockers": blockers,
    }

def validate_annotations(annotations):
    if not isinstance(annotations,dict) or not annotations: fail("annotations must be a nonempty object")
    for name, annotation in annotations.items():
        if set(annotation) != {"mask","endpointsPx","valuesCm"}: fail(f"{name}: annotation keys are strict")
        mask, endpoints, values = annotation["mask"], annotation["endpointsPx"], annotation["valuesCm"]
        if not isinstance(mask,dict) or set(mask) != {"status","polygon"} or mask["status"] not in {"garment_complete","garment_clipped","segmentation_failed","quality_rejected"}: fail(f"{name}: invalid mask")
        if mask["status"] == "garment_complete":
            if not isinstance(mask["polygon"],list) or len(mask["polygon"]) < 3 or not all(point(p) and all(0 <= v < 800 for v in p) for p in mask["polygon"]): fail(f"{name}: complete mask requires in-bounds polygon")
        elif mask["polygon"] is not None: fail(f"{name}: failed mask must not invent polygon")
        if not isinstance(endpoints,dict) or set(endpoints) != {"lengthStart","lengthEnd","widthStart","widthEnd"} or not all(point(p) for p in endpoints.values()): fail(f"{name}: invalid endpoints")
        if values is not None and (set(values) != {"length","width"} or not all(isinstance(v,(int,float)) and v > 0 for v in values.values())): fail(f"{name}: invalid measurement values")

def validate(manifest):
    if set(manifest) != {"schemaVersion","generator","image","marker","thresholds","failureCodes","artifacts","annotations","cases"}: fail("top-level keys are strict")
    if manifest["schemaVersion"] != 2 or manifest["generator"] != "generate_synthetic.py": fail("unsupported schema/generator")
    if manifest["image"] != {"format":"PNG-RGB8","width":800,"height":800}: fail("image declaration must be PNG-RGB8 800x800")
    if manifest["marker"] != {"outerMm":50.0,"blackFrameMm":5.0,"whiteInnerMm":40.0,"printScale":"100%"}: fail("marker geometry is frozen")
    if manifest["thresholds"] != {"minimumMarkerSidePx":80,"edgeMarginPx":16,"minimumSideRatio":0.65,"minimumGarmentMarkerGapPx":24}: fail("thresholds are frozen")
    if not isinstance(manifest["failureCodes"],list) or set(manifest["failureCodes"]) != FAILURES or len(manifest["failureCodes"]) != len(FAILURES): fail("failure codes are exact")
    artifacts = manifest["artifacts"]
    if not isinstance(artifacts,list) or len(artifacts) != 1: fail("exactly one marker PDF provenance record required")
    artifact = artifacts[0]
    if set(artifact) != {"path","sha256","generatedBy","pageSize","markerGeometry","dependency"} or not SHA.fullmatch(artifact["sha256"]): fail("invalid marker PDF provenance")
    if artifact["path"] != "output/pdf/t11-01-50mm-marker.pdf" or artifact["generatedBy"] != "scripts/t11_01_measurement_corpus/marker_pdf.py" or artifact["pageSize"] != "A4 595.276x841.890pt": fail("marker PDF provenance mismatch")
    if artifact["markerGeometry"] != {"outerMm":50.0,"blackFrameMm":5.0,"whiteInnerMm":40.0}: fail("marker PDF geometry mismatch")
    dep = artifact["dependency"]
    if dep != {"name":"ReportLab","version":"4.4.9","license":"BSD-3-Clause","provenance":"https://www.reportlab.com/software/opensource/"}: fail("ReportLab provenance mismatch")
    if hashlib.sha256((REPO / artifact["path"]).read_bytes()).hexdigest() != artifact["sha256"]: fail("marker PDF hash mismatch")
    validate_annotations(manifest["annotations"])
    ids, files, hashes = set(), set(), set()
    cases_by_id = {}
    coverage = {code:{True:0,False:0} for code in FAILURES}
    for case in manifest["cases"]:
        if set(case) - CASE_KEYS or (CASE_KEYS - {"garmentMode","qualityFlag"}) - set(case): fail("case keys are strict and required")
        cid = case["id"]
        if not isinstance(cid,str) or not cid or cid in ids: fail("case IDs must be unique strings")
        if not isinstance(case["file"],str) or not case["file"].endswith(".png") or case["file"] in files: fail(f"{cid}: files must be unique PNG names")
        if not isinstance(case["sha256"],str) or not SHA.fullmatch(case["sha256"]) or case["sha256"] in hashes: fail(f"{cid}: SHA-256 must be exact and unique")
        ids.add(cid); files.add(case["file"]); hashes.add(case["sha256"])
        cases_by_id[cid] = case
        if case["markerMode"] not in {"none","valid","multiple","occluded"}: fail(f"{cid}: invalid marker mode")
        geometry = case["markerGeometry"]
        if case["markerMode"] == "none":
            if geometry is not None or case["markerCorners"] is not None: fail(f"{cid}: missing marker cannot declare geometry")
        elif not finite_geometry(geometry) or not (0 <= geometry["x"] < 800 and 0 <= geometry["y"] < 800 and geometry["x"] + geometry["side"] <= 800 and geometry["y"] + geometry.get("height",geometry["side"]) <= 800):
            fail(f"{cid}: marker geometry must be finite, in bounds, and use only x/y/side/height")
        corners = case["expectedCorners"]
        if case["markerMode"] in {"none","multiple","occluded"} and corners is not None: fail(f"{cid}: rejected marker must not publish corners")
        if corners is not None:
            if not isinstance(corners,list) or len(corners)!=4 or not all(point(p) and all(0 <= v < 800 for v in p) for p in corners): fail(f"{cid}: malformed/out-of-bounds corners")
            if corners != case["markerCorners"] or polygon_area(corners) <= 0: fail(f"{cid}: corner order must be TL/TR/BR/BL clockwise")
            top,right,bottom,left = distance(corners[0],corners[1]),distance(corners[1],corners[2]),distance(corners[2],corners[3]),distance(corners[3],corners[0])
            if not (corners[0][1] <= corners[1][1] <= corners[2][1] and corners[0][1] <= corners[3][1] <= corners[2][1] and top>0 and right>0 and bottom>0 and left>0): fail(f"{cid}: corners are not robust TL/TR/BR/BL")
            if cid != "perspective-valid":
                height = geometry.get("height", geometry["side"])
                axis = [[geometry["x"],geometry["y"]],[geometry["x"]+geometry["side"],geometry["y"]],[geometry["x"]+geometry["side"],geometry["y"]+height],[geometry["x"],geometry["y"]+height]]
                if corners != axis: fail(f"{cid}: axis-aligned corners must match marker geometry")
        if case["annotationId"] not in manifest["annotations"]: fail(f"{cid}: missing annotation")
        annotation = manifest["annotations"][case["annotationId"]]
        scale = case["renderedScalePxPerCm"]
        if scale is not None and (not isinstance(scale,(int,float)) or scale <= 0): fail(f"{cid}: invalid rendered scale")
        if cid == "perspective-valid":
            if scale != 20.0 or not case["scaleAccepted"]: fail("perspective-valid must document its 20px/cm rectified scale")
        elif scale is not None and not math.isclose(scale, geometry["side"] / 5.0, abs_tol=.0001): fail(f"{cid}: scale must equal marker side / 5cm")
        if case["scaleAccepted"]:
            if case["expectedFailure"] is not None or scale is None or annotation["valuesCm"] is None: fail(f"{cid}: accepted scale requires usable annotation")
            values, endpoints = annotation["valuesCm"], annotation["endpointsPx"]
            if not math.isclose(values["length"], distance(endpoints["lengthStart"],endpoints["lengthEnd"])/scale, abs_tol=0.0001) or not math.isclose(values["width"], distance(endpoints["widthStart"],endpoints["widthEnd"])/scale, abs_tol=0.0001): fail(f"{cid}: cm values do not derive from px/cm")
        elif annotation["valuesCm"] is not None: fail(f"{cid}: rejected scale must not emit cm values")
        failure = case["expectedFailure"]
        if failure is not None and failure not in FAILURES: fail(f"{cid}: unknown failure")
        if case.get("qualityHint") is not None:
            if case["qualityHint"] not in {"TOO_DARK","TOO_BLURRY"} or case["scaleAccepted"] or failure is not None or annotation["mask"]["status"] != "quality_rejected": fail(f"{cid}: quality is not a scale success")
        boundary = case["boundary"]
        if cid in BOUNDARY_CASES and boundary != BOUNDARY_CASES[cid]: fail(f"{cid}: boundary binding mismatch")
        if boundary is not None:
            if "edgeMarginPx" in boundary:
                margin = min(v for p in corners for v in (p[0],p[1],799-p[0],799-p[1]))
                if not math.isclose(margin,boundary["edgeMarginPx"],abs_tol=0.001): fail(f"{cid}: edge boundary does not match rendered corners")
            if "sideRatio" in boundary:
                ratio = min(distance(corners[0],corners[1]),distance(corners[1],corners[2])) / max(distance(corners[0],corners[1]),distance(corners[1],corners[2]))
                if not math.isclose(ratio,boundary["sideRatio"],abs_tol=0.00001): fail(f"{cid}: ratio boundary does not match rendered geometry")
            if "garmentMarkerGapPx" in boundary and min(p[0] for p in corners)-550 != boundary["garmentMarkerGapPx"]: fail(f"{cid}: garment gap does not match rendered geometry")
            if (boundary.get("edgeMarginPx", 17) <= 16 or boundary.get("sideRatio", .65) < .65) and boundary.get("compatibilityMapping") != "no valid marker candidate accepted": fail(f"{cid}: candidate rejection needs compatibility mapping")
        for code, polarity in case["failurePair"].items():
            if code not in FAILURES or not isinstance(polarity,bool): fail(f"{cid}: invalid failure evidence")
            coverage[code][polarity] += 1
    missing = [c for c,v in coverage.items() if not v[True] or not v[False]]
    if missing: fail("missing positive/negative evidence: "+", ".join(sorted(missing)))
    if not set(BOUNDARY_CASES).issubset(cases_by_id): fail("required boundary cases are missing")
    if not set(SCENARIO_RULES).issubset(cases_by_id): fail("required finite failure scenarios are missing")
    for cid, expected in SCENARIO_RULES.items():
        case = cases_by_id[cid]
        for key, value in expected.items():
            if case.get(key) != value: fail(f"{cid}: semantic failure binding mismatch for {key}")
    for cid, flag, hint in (("dark","dark","TOO_DARK"),("blur","blur","TOO_BLURRY")):
        case = cases_by_id.get(cid)
        if not case or case.get("qualityFlag") != flag or case.get("qualityHint") != hint or case["scaleAccepted"] or case["expectedFailure"] is not None or case["annotationId"] != "qualityRejected":
            fail(f"{cid}: quality binding mismatch")
    if manifest["annotations"]["endpointsInvalid"]["endpointsPx"]["widthStart"][0] >= 110: fail("endpoint-invalid needs out-of-garment endpoint")

def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR": fail("generated output is not a PNG")
    return int.from_bytes(data[16:20],"big"), int.from_bytes(data[20:24],"big")
def rgb_pixels(data):
    width, height = png_size(data); offset, payload = 8, b""
    while offset < len(data):
        length = int.from_bytes(data[offset:offset+4],"big"); kind = data[offset+4:offset+8]
        if kind == b"IDAT": payload += data[offset+8:offset+8+length]
        offset += length + 12
    raw = zlib.decompress(payload); stride = width * 3 + 1
    if len(raw) != stride * height or any(raw[row*stride] != 0 for row in range(height)): fail("generator PNG must use complete RGB filter-0 rows")
    return width, height, b"".join(raw[row*stride+1:(row+1)*stride] for row in range(height))
def luminance_and_edges(data):
    width, height, pixels = rgb_pixels(data)
    luminance = [(pixels[i]*299 + pixels[i+1]*587 + pixels[i+2]*114)/1000 for i in range(0,len(pixels),3)]
    horizontal = sum(abs(luminance[y*width+x]-luminance[y*width+x+1]) for y in range(height) for x in range(width-1))
    vertical = sum(abs(luminance[y*width+x]-luminance[(y+1)*width+x]) for y in range(height-1) for x in range(width))
    return sum(luminance)/len(luminance), (horizontal+vertical)/(width*(height-1)+(width-1)*height)
def lint_render(manifest, directory):
    generate_synthetic.generate(directory)
    rendered = {}
    for case in manifest["cases"]:
        data=(directory/case["file"]).read_bytes()
        if hashlib.sha256(data).hexdigest()!=case["sha256"]: fail(f"{case['id']}: generated hash mismatch")
        if png_size(data) != (800,800): fail(f"{case['id']}: generated image dimensions mismatch")
        rendered[case["id"]] = data
    valid_luma, valid_edges = luminance_and_edges(rendered["valid"])
    dark_luma, _ = luminance_and_edges(rendered["dark"])
    _, blur_edges = luminance_and_edges(rendered["blur"])
    if dark_luma >= valid_luma * .3: fail("dark pixels are not materially darker than valid")
    if blur_edges >= valid_edges * .9: fail("blur pixels are not materially less sharp than valid")
    if rendered["perspective-valid"] == rendered["valid"]: fail("perspective pixels must differ from valid")
    required = {"segmentation-failed","endpoints-invalid","ratio-0649","ratio-0650","overlap-23px","overlap-24px","dark","blur"}
    if not required.issubset(rendered) or len({hashlib.sha256(rendered[c]).hexdigest() for c in required}) != len(required): fail("semantic cases require distinct rendered hashes")
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--render-dir",type=Path)
    parser.add_argument("--physical-root",type=Path,help="external directory containing reviewed capture and ruler-evidence files")
    parser.add_argument("--require-physical-gate",action="store_true",help="fail unless the complete 30-capture/ruler gate is externally hash-verified")
    parser.add_argument("--summary-json",action="store_true")
    args=parser.parse_args()
    manifest=json.loads((ROOT/"corpus-manifest.json").read_text(encoding="utf-8")); validate(manifest)
    physical_summary=lint_log(physical_root=args.physical_root)
    if args.render_dir: lint_render(manifest,args.render_dir)
    else:
        with tempfile.TemporaryDirectory(prefix="teamd-t11-01-") as temp: lint_render(manifest,Path(temp))
    print(f"T11-01 corpus lint passed: {len(manifest['cases'])} deterministic synthetic cases.")
    if args.summary_json: print(json.dumps(physical_summary,sort_keys=True,separators=(",",":")))
    else: print(f"T11-01 physical gate {physical_summary['status']}: {physical_summary['reviewedCoreCaptures']}/30 reviewed core captures; {physical_summary['fileVerifiedCaptures']} external capture files and {physical_summary['fileVerifiedMarkerPrints']} ruler records hash-verified.")
    if args.require_physical_gate and physical_summary["status"] != "ready": fail("physical gate remains blocked: " + "; ".join(physical_summary["blockers"]))
if __name__ == "__main__": main()
