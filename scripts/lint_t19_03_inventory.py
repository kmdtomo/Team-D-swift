#!/usr/bin/env python3
"""Source-only drift checks for the T19-03 Phase 1 dependency inventory."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "Licenses/dependency-inventory.json"
NOTICE = ROOT / "Licenses/NOTICE.md"
PACKAGE = ROOT / "Packages/Package.swift"
PROJECT = ROOT / "TeamD.xcodeproj/project.pbxproj"
FIXTURES = ROOT / "Fixtures/asset-manifest.json"
CORPUS = ROOT / "Fixtures/MeasurementCorpus/corpus-manifest.json"
MARKER = ROOT / "output/pdf/t11-01-50mm-marker.pdf"
EXPECTED_PRODUCTS = ["DomainKit", "ContractKit", "CaptureKit", "APIClient", "LiveKitBridge", "MeasurementKit", "CompositionKit", "TestSupport"]
MARKER_SHA256 = "4e5158506dbdf66623f281e8b9d7b01f7c23349beeefbf5682030d165b638217"
FORBIDDEN_FIXTURE_SUFFIXES = {".js", ".mjs", ".cjs", ".ts", ".tsx", ".html", ".css", ".wasm"}
FORBIDDEN_TRACKED_PATH_PARTS = {"node_modules", "openspec", "document-autocapture"}


def fail(message: str) -> None:
    raise AssertionError(message)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def item(inventory: dict, identifier: str) -> dict:
    matches = [entry for entry in inventory["items"] if entry["id"] == identifier]
    if len(matches) != 1:
        fail(f"expected exactly one inventory item {identifier!r}")
    return matches[0]


def main() -> None:
    inventory = read_json(INVENTORY)
    if inventory.get("schemaVersion") != 1 or inventory.get("phase") != "code_ready_unverified":
        fail("inventory schema/Phase 1 status drift")
    if inventory.get("reviewedOn") != "2026-08-31" or not inventory.get("sourceCommit"):
        fail("inventory must retain a dated committed-baseline review")
    if inventory.get("pendingInputs") != ["T08-01 final LiveKit Swift package pin and checksum", "T11-03 OpenCV iOS adoption decision", "T14-01 shared-service/model distribution facts"]:
        fail("pending release inputs drift")

    package = PACKAGE.read_text(encoding="utf-8")
    if ".package(" in package or any(ROOT.rglob("Package.resolved")):
        fail("external SwiftPM package added: update the inventory and NOTICE first")
    products = re.findall(r'\.library\(name: "([^"]+)"', package)
    if products != EXPECTED_PRODUCTS:
        fail(f"local package products drifted: {products!r}")
    app_bundle = inventory["appBundle"]
    if app_bundle["externalSwiftPackages"] != [] or app_bundle["packageResolved"] is not None:
        fail("inventory no longer matches external package state")
    if app_bundle["localSwiftPackage"]["products"] != EXPECTED_PRODUCTS:
        fail("inventory local product list drift")

    project = PROJECT.read_text(encoding="utf-8")
    if "XCRemoteSwiftPackageReference" in project:
        fail("remote Xcode Swift package added: update the inventory and NOTICE first")
    resource_sections = re.findall(r'/\* Begin PBXResourcesBuildPhase section \*/(.*?)/\* End PBXResourcesBuildPhase section \*/', project, re.S)
    if len(resource_sections) != 1 or re.findall(r'files = \((.*?)\);', resource_sections[0], re.S) != ["", "", ""]:
        fail("resource build phase changed: inventory bundled assets before adding resources")
    if app_bundle["resourceBuildPhaseFiles"] != []:
        fail("inventory resource list must be empty for this baseline")

    fixture_manifest = read_json(FIXTURES)
    assets = fixture_manifest.get("assets", [])
    classifications = [asset.get("classification") for asset in assets]
    if len(assets) != 9 or classifications.count("regenerate") != 7 or classifications.count("reject") != 2:
        fail("fixture candidate provenance/count drift")
    if any(asset.get("targetPath") is not None for asset in assets):
        fail("a fixture target was approved: update inventory, hash, and NOTICE")
    approved = ROOT / "Fixtures/Approved"
    if approved.exists() and any(path.is_file() for path in approved.rglob("*")):
        fail("approved fixture binary exists without a Phase 1 inventory update")
    forbidden_fixture_files = [path.relative_to(ROOT).as_posix() for path in (ROOT / "Fixtures").rglob("*") if path.is_file() and path.suffix.lower() in FORBIDDEN_FIXTURE_SUFFIXES]
    if forbidden_fixture_files:
        fail(f"forbidden Web/WASM fixture assets found: {forbidden_fixture_files}")
    forbidden_paths = [path.relative_to(ROOT).as_posix() for path in ROOT.rglob("*") if any(part.lower() in FORBIDDEN_TRACKED_PATH_PARTS for part in path.relative_to(ROOT).parts)]
    if forbidden_paths:
        fail(f"forbidden copied Web asset/path found: {forbidden_paths[:3]}")

    if sha256(MARKER) != MARKER_SHA256:
        fail("marker PDF checksum drift")
    corpus = read_json(CORPUS)
    artifact = corpus["artifacts"][0]
    if artifact["path"] != "output/pdf/t11-01-50mm-marker.pdf" or artifact["sha256"] != MARKER_SHA256:
        fail("corpus marker provenance drift")
    if item(inventory, "measurement-marker-pdf")["checksum"] != f"sha256:{MARKER_SHA256}":
        fail("inventory marker checksum drift")
    reportlab = item(inventory, "reportlab-marker-generator")
    if reportlab["version"] != artifact["dependency"]["version"] or not reportlab["license"].startswith(artifact["dependency"]["license"]):
        fail("ReportLab generator record drift")

    for identifier in ("livekit-swift", "opencv-ios", "rembg-birefnet-shared-service", "web-reference-code"):
        if item(inventory, identifier)["bundled"] is not False:
            fail(f"{identifier} must remain non-bundled in Phase 1")
    notice = NOTICE.read_text(encoding="utf-8")
    for phrase in ("no external Swift", "LiveKit Swift", "OpenCV iOS", "rembg and BiRefNet", "not copied"):
        if phrase not in notice:
            fail(f"NOTICE missing required boundary: {phrase}")
    print("T19-03 inventory source-only checks passed")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, IndexError, json.JSONDecodeError) as error:
        print(f"T19-03 inventory check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
