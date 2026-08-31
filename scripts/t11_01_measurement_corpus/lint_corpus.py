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
LOG_COLUMNS = ["capture_id","image_path","image_sha256","device_model","ios_version","marker_ruler_mm","distance_band","tilt_band","lighting_band","scenario","expected_failure","observed_failure","corners_tl_tr_br_bl","scale_px_per_cm","mask_status","measurement_endpoints","length_cm","width_cm","rights_checked","pii_checked","annotation_complete","notes"]
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
def point(value): return isinstance(value,list) and len(value)==2 and all(isinstance(v,(int,float)) and math.isfinite(v) for v in value)
def distance(a,b): return math.hypot(a[0]-b[0],a[1]-b[1])
def polygon_area(points): return sum(a[0]*b[1]-a[1]*b[0] for a,b in zip(points,points[1:]+points[:1])) / 2
def finite_geometry(value):
    return isinstance(value,dict) and set(value) in ({"x","y","side"},{"x","y","side","height"}) and all(isinstance(v,(int,float)) and math.isfinite(v) for v in value.values()) and value["side"] > 0 and value.get("height",value["side"]) > 0

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
def lint_log(path=None):
    with (path or Path(__file__).parent/"physical-corpus-log.csv").open(newline="",encoding="utf-8") as stream:
        if csv.DictReader(stream).fieldnames != LOG_COLUMNS: fail("physical log schema/columns are incomplete")
def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--render-dir",type=Path); args=parser.parse_args()
    manifest=json.loads((ROOT/"corpus-manifest.json").read_text(encoding="utf-8")); validate(manifest); lint_log()
    if args.render_dir: lint_render(manifest,args.render_dir)
    else:
        with tempfile.TemporaryDirectory(prefix="teamd-t11-01-") as temp: lint_render(manifest,Path(temp))
    print(f"T11-01 corpus lint passed: {len(manifest['cases'])} deterministic synthetic cases.")
if __name__ == "__main__": main()
