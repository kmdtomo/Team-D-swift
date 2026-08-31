#!/usr/bin/env python3
"""Python 3.9+ standard-library lint for T01-02 fixture governance."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import zlib


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Fixtures"
MANIFEST_PATH = FIXTURES / "asset-manifest.json"
SOURCE_REPOSITORY = "https://github.com/neko-jpg/Team-D"
SOURCE_SHA = "44065d41e8906d34e5d8e11d7cd4cc14b25d17f2"
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg"}
TEXT_EXTENSIONS = {".json", ".md", ".txt"}
IGNORED_DIRECTORY_NAMES = {".git", ".build", "build", "DerivedData", "xcuserdata"}
DEPENDENCY_MANIFESTS = {"Package.swift", "Package.resolved", "Podfile", "Cartfile", "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "requirements.txt", "requirements-backend.txt"}
CANONICAL = {
    "source-front": ("fixtures/garment/front.png", "95953a647997ce537d3cd5293b9f981cc500b3e2", "67592247ea559212a05b71293acf9cdf3b0283ec1088436fe00742f4fc825b2c"),
    "source-back": ("fixtures/garment/back.png", "7edea57f5e45ddd5b0fee5c39e07f08a51db2807", "7b19f191e55653a0086df4d2b00e77b1be63d475c797355876b852f5a7933e74"),
    "source-tag": ("fixtures/garment/tag.png", "ed627ba138ea8405f8c82549d40bdfc1ca17cccf", "5ef810c78fd30928697d8599ce78771b1176121412b6f106419706f9ac8dd8a1"),
    "source-dark": ("fixtures/garment/dark.png", "4cdf07854c9dfada87f1336107d2ac1fe09a9704", "22c5aed90496e1092f37edc6c0cc430e19eba0a7ea6dcedea226f12be263658d"),
    "source-blur": ("fixtures/garment/blur.png", "231abbc3e98e4a86ed9fbed44918fb03652ee4a2", "6cae429f10c34a4de92850b02aa3080eeae823e7d0b30bb3085706703e0b489c"),
    "source-wrong-shot": ("fixtures/garment/wrong-shot.png", "ed627ba138ea8405f8c82549d40bdfc1ca17cccf", "5ef810c78fd30928697d8599ce78771b1176121412b6f106419706f9ac8dd8a1"),
    "source-known-front-mask": ("fixtures/garment/known-front-mask.png", "33eb4e5d762b9ce6762f9969a20cc75ff3853420", "683068a31ba9f99e790696e74398036a6f00a32bf315974b8224fe283f8f8d68"),
    "source-known-back-mask": ("fixtures/garment/known-back-mask.png", "33eb4e5d762b9ce6762f9969a20cc75ff3853420", "683068a31ba9f99e790696e74398036a6f00a32bf315974b8224fe283f8f8d68"),
    "source-known-tag-mask": ("fixtures/garment/known-tag-mask.png", "ef5dc6e4221f234fac3b8d8f802c87105af76990", "a49c5c7087a356a7f7a892cc230708d730a3462653bcbd3f3fc498e20eea98fa"),
}
CANONICAL_DISPOSITIONS = {**{key: "regenerate" for key in CANONICAL}, "source-known-back-mask": "reject", "source-known-tag-mask": "reject"}
CANONICAL_OBSERVED = {
    "source-front": {"format": "PNG RGBA8", "width": 800, "height": 800, "description": "source candidate image; behavior is not adopted as an assessor contract"},
    "source-back": {"format": "PNG RGBA8", "width": 800, "height": 800, "description": "source candidate image; behavior is not adopted as an assessor contract"},
    "source-tag": {"format": "PNG RGBA8", "width": 800, "height": 800, "description": "source candidate image; behavior is not adopted as an assessor contract"},
    "source-dark": {"format": "PNG RGBA8", "width": 800, "height": 800, "description": "source candidate image; no current iOS assessor code is inferred"},
    "source-blur": {"format": "PNG RGBA8", "width": 800, "height": 800, "description": "source candidate image; no current iOS assessor code is inferred"},
    "source-wrong-shot": {"format": "PNG RGBA8", "width": 800, "height": 800, "description": "byte-identical source candidate to tag.png"},
    "source-known-front-mask": {"format": "PNG RGBA8", "width": 800, "height": 800, "description": "opaque white garment and opaque black background; not an alpha mask"},
    "source-known-back-mask": {"format": "PNG RGBA8", "width": 800, "height": 800, "description": "opaque white garment and opaque black background; byte-identical to known-front-mask.png"},
    "source-known-tag-mask": {"format": "PNG RGBA8", "width": 800, "height": 800, "description": "opaque white tag region and opaque black background; not an alpha mask"},
}
CANONICAL_TARGET_EXPECTATIONS = {
    "source-front": {"scenario": "front accepted", "shot": "front", "assessment": "ok"},
    "source-back": {"scenario": "back accepted", "shot": "back", "assessment": "ok"},
    "source-tag": {"scenario": "tag accepted", "shot": "tag", "assessment": "ok"},
    "source-dark": {"scenario": "low luminance retry", "requestedShot": "front", "assessment": "retry", "issue": "TOO_DARK"},
    "source-blur": {"scenario": "blur retry", "requestedShot": "front", "assessment": "retry", "issue": "TOO_BLURRY"},
    "source-wrong-shot": {"scenario": "tag fixture used when front was requested", "requestedShot": "front", "assessment": "retry", "issue": "WRONG_SHOT"},
    "source-known-front-mask": {"scenario": "front-only known mask", "forShot": "front", "mask": "documented target mask encoding paired with regenerated front fixture"},
    "source-known-back-mask": {"scenario": "no iOS use: only front is eligible for masking/composition"},
    "source-known-tag-mask": {"scenario": "no iOS use: tag is never eligible for masking/composition"},
}
REQUIRED_ALLOW = {"root:Fixtures/Approved/", "extension:.png", "extension:.jpg", "extension:.jpeg", "extension:.json"}
REQUIRED_DENY = {
    "fixture-extension:.js", "fixture-extension:.mjs", "fixture-extension:.cjs", "fixture-extension:.ts", "fixture-extension:.tsx", "fixture-extension:.html", "fixture-extension:.css", "fixture-extension:.wasm",
    "fixture-path:node_modules", "fixture-path:openspec", "repository-path:ekyc-ar-ui-flow-final.png",
    "dependency:react", "dependency:react-dom", "dependency:vite", "dependency:typescript", "dependency:zod", "dependency:opencv.js", "dependency:opencv-js", "dependency:wasm", "dependency:fastapi", "dependency:rembg", "dependency:birefnet", "dependency:livekit-agents",
}
CANONICAL_RIGHTS_REVIEW = {
    "reviewedOn": "2026-08-31",
    "result": "unverified",
    "evidence": [
        "The fixed source root has no LICENSE or COPYING file.",
        "fixtures/README.md contains no redistribution grant for fixture binaries.",
        "THIRD_PARTY_NOTICES does not license the fixture binaries.",
    ],
    "decision": "do-not-copy",
}


def fail(message: str) -> None:
    raise ValueError(f"T01-02 lint: {message}")


def policy_entries(name: str) -> set[str]:
    path = FIXTURES / name
    if not path.is_file():
        fail(f"missing policy file Fixtures/{name}")
    return {line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if len(data) < 45 or data[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"{path.relative_to(ROOT)} must be a PNG RGBA8 image")
    offset, width, height, saw_ihdr, saw_iend = 8, 0, 0, False, False
    while offset < len(data):
        if offset + 12 > len(data):
            fail(f"{path.relative_to(ROOT)} has a truncated PNG chunk")
        length = int.from_bytes(data[offset:offset + 4], "big")
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            fail(f"{path.relative_to(ROOT)} has a truncated PNG payload")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        expected_crc = int.from_bytes(data[offset + 8 + length:chunk_end], "big")
        if (zlib.crc32(kind + payload) & 0xffffffff) != expected_crc:
            fail(f"{path.relative_to(ROOT)} has an invalid PNG CRC")
        if not saw_ihdr:
            if kind != b"IHDR" or length != 13 or payload[8] != 8 or payload[9] != 6:
                fail(f"{path.relative_to(ROOT)} must start with an RGBA8 IHDR")
            width, height, saw_ihdr = int.from_bytes(payload[:4], "big"), int.from_bytes(payload[4:8], "big"), True
        if kind == b"IEND":
            if length != 0 or chunk_end != len(data):
                fail(f"{path.relative_to(ROOT)} has an invalid PNG IEND")
            saw_iend = True
            break
        offset = chunk_end
    if not saw_ihdr or not saw_iend:
        fail(f"{path.relative_to(ROOT)} lacks a complete PNG IEND")
    return width, height


def jpeg_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if len(data) < 4 or data[:2] != b"\xff\xd8" or data[-2:] != b"\xff\xd9":
        fail(f"{path.relative_to(ROOT)} is not a JPEG")
    index = 2
    while index + 9 <= len(data):
        while index < len(data) and data[index] == 0xff:
            index += 1
        marker = data[index]
        index += 1
        if marker in {0xd8, 0xd9} or 0xd0 <= marker <= 0xd7:
            continue
        if index + 2 > len(data):
            break
        length = int.from_bytes(data[index:index + 2], "big")
        if length < 2 or index + length > len(data):
            break
        if marker in {0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf}:
            if length < 8:
                break
            width, height = int.from_bytes(data[index + 5:index + 7], "big"), int.from_bytes(data[index + 3:index + 5], "big")
            if width > 0 and height > 0:
                return width, height
        index += length
    fail(f"{path.relative_to(ROOT)} has no valid JPEG frame header")


def load_manifest() -> dict:
    try:
        value = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid manifest: {error}")
    snapshot = value.get("sourceSnapshot")
    if value.get("schemaVersion") != 1 or snapshot != {"repository": SOURCE_REPOSITORY, "commit": SOURCE_SHA, "readOnly": True}:
        fail("manifest must contain the exact read-only source repository and snapshot")
    if value.get("rightsReview") != CANONICAL_RIGHTS_REVIEW:
        fail("manifest must record dated license evidence and the do-not-copy decision")
    boundary = value.get("liveDependencyBoundary")
    canonical_boundary = {
        "introducedByT01_02": "none",
        "livekitSwift": "must be pinned and license/NOTICE-reviewed in T19-03",
        "neverBundle": ["LiveKit JavaScript", "LiveKit Python", "FastAPI backend", "rembg", "BiRefNet"],
        "openCViOS": "may be considered only after the T11 Apple-framework gate",
        "neverAdopt": ["OpenCV.js", "WASM"],
    }
    if boundary != canonical_boundary:
        fail("manifest must record the live dependency boundary")
    canonical_policy = {
        "copyRequires": ["verified-license", "verified-notice-if-required", "approved-target-hash"],
        "unverifiedBinaryAction": "do-not-copy",
        "allowedFixtureRoot": "Fixtures/Approved",
        "generatedTargetDimensions": {"width": 800, "height": 800},
    }
    if value.get("policy") != canonical_policy:
        fail("manifest must contain the canonical copy and generated-target policy")
    if not isinstance(value.get("assets"), list) or len(value["assets"]) != 9:
        fail("manifest must inventory exactly nine source candidates")
    return value


def target_path(value: str) -> Path:
    pure = PurePosixPath(value)
    if pure.is_absolute() or ".." in pure.parts or not value.startswith("Fixtures/Approved/"):
        fail("fixture target must be a non-traversing Fixtures/Approved path")
    candidate = (ROOT / pure).resolve()
    approved = (FIXTURES / "Approved").resolve()
    if candidate == approved or approved not in candidate.parents:
        fail("fixture target resolves outside Fixtures/Approved")
    return candidate


def validate_assets(manifest: dict) -> dict[str, dict]:
    observed: dict[str, tuple[str, str, str]] = {}
    targets: dict[str, dict] = {}
    for asset in manifest["assets"]:
        if not isinstance(asset, dict) or not isinstance(asset.get("id"), str):
            fail("every asset must have an ID")
        asset_id = asset["id"]
        observed[asset_id] = (asset.get("sourcePath"), asset.get("sourceGitBlobSha1"), asset.get("sourceSha256"))
        source = asset.get("sourceObserved")
        if source != CANONICAL_OBSERVED.get(asset_id):
            fail(f"{asset_id} source observation differs from the canonical inventory")
        if asset.get("classification") != CANONICAL_DISPOSITIONS.get(asset_id):
            fail(f"{asset_id} has a non-canonical T01-02 disposition")
        if asset.get("regeneratedTargetExpected") != CANONICAL_TARGET_EXPECTATIONS.get(asset_id):
            fail(f"{asset_id} regenerated target expectation differs from the canonical inventory")
        generation = asset.get("generation")
        if not isinstance(generation, dict) or not isinstance(generation.get("method"), str) or not generation["method"].strip() or generation.get("sourceCodeCopied") is not False:
            fail(f"{asset_id} must state that source code was not copied")
        rights = asset.get("rights")
        if not isinstance(rights, dict) or rights.get("status") != "unverified" or rights.get("decision") != "do-not-copy" or not isinstance(rights.get("notice"), str) or not rights["notice"].strip():
            fail(f"{asset_id} must record unverified rights, do-not-copy, and a notice")
        target, target_hash = asset.get("targetPath"), asset.get("targetSha256")
        if target is None:
            if target_hash is not None:
                fail(f"{asset_id} has a target hash without a target")
            continue
        if asset["classification"] == "reject":
            fail(f"rejected asset {asset_id} must not have a target")
        if not isinstance(target, str) or PurePosixPath(target).suffix.lower() not in IMAGE_EXTENSIONS or not isinstance(target_hash, str) or len(target_hash) != 64 or any(character not in "0123456789abcdef" for character in target_hash):
            fail(f"{asset_id} has an invalid generated target")
        target_path(target)
        if target in targets:
            fail(f"multiple assets claim {target}")
        targets[target] = asset
    if observed != CANONICAL:
        fail("manifest source IDs, paths, blob IDs, or SHA-256 values differ from the canonical nine-image inventory")
    return targets


def files_under(root: Path):
    for path in root.rglob("*"):
        if any(part in IGNORED_DIRECTORY_NAMES for part in path.relative_to(ROOT).parts):
            continue
        if path.is_file():
            yield path


def validate_repository(assets: dict[str, dict], allow: set[str], deny: set[str]) -> None:
    if allow != REQUIRED_ALLOW or not REQUIRED_DENY.issubset(deny):
        fail("allowlist or denylist is missing a required T01-02 policy entry")
    allowed_extensions = {entry[10:] for entry in allow if entry.startswith("extension:")}
    forbidden_extensions = {entry[18:] for entry in deny if entry.startswith("fixture-extension:")}
    forbidden_components = {entry[13:].casefold() for entry in deny if entry.startswith("fixture-path:")}
    repository_paths = {entry[16:].casefold() for entry in deny if entry.startswith("repository-path:")}
    forbidden_dependencies = {entry[11:] for entry in deny if entry.startswith("dependency:")}
    for path in files_under(ROOT):
        relative = path.relative_to(ROOT).as_posix()
        parts = {part.casefold() for part in path.relative_to(ROOT).parts}
        if parts & forbidden_components:
            fail(f"denylisted repository path component in {relative}")
        if relative.casefold() in repository_paths:
            fail(f"denylisted source-Web image exists: {relative}")
        suffix = path.suffix.lower()
        if suffix in forbidden_extensions:
            fail(f"denylisted Web/WASM extension in {relative}")
        if path.name in DEPENDENCY_MANIFESTS:
            text = path.read_text(encoding="utf-8", errors="replace").lower()
            for dependency in forbidden_dependencies:
                if dependency in text:
                    fail(f"denylisted dependency {dependency!r} found in {relative}")
    approved = (FIXTURES / "Approved").resolve()
    for path in files_under(FIXTURES):
        relative = path.relative_to(ROOT).as_posix()
        suffix = path.suffix.lower()
        if suffix not in IMAGE_EXTENSIONS | TEXT_EXTENSIONS:
            fail(f"fixture extension is not allowlisted: {relative}")
        if suffix not in IMAGE_EXTENSIONS:
            continue
        if not path.resolve().is_relative_to(approved):
            fail(f"fixture binary is outside Fixtures/Approved: {relative}")
        asset = assets.get(relative)
        if asset is None or suffix not in allowed_extensions:
            fail(f"fixture binary is not allowlisted and manifest-approved: {relative}")
        if digest(path) != asset["targetSha256"]:
            fail(f"fixture hash does not match manifest: {relative}")
        dimensions = png_dimensions(path) if suffix == ".png" else jpeg_dimensions(path)
        target_dimensions = manifest_dimensions()
        if dimensions != target_dimensions:
            fail(f"fixture dimensions do not match manifest: {relative}")
    for target in assets:
        if not target_path(target).is_file():
            fail(f"manifest-approved generated target is missing: {target}")


def manifest_dimensions() -> tuple[int, int]:
    policy = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))["policy"]["generatedTargetDimensions"]
    return policy["width"], policy["height"]


def main() -> int:
    try:
        manifest = load_manifest()
        assets = validate_assets(manifest)
        validate_repository(assets, policy_entries("allowlist.txt"), policy_entries("denylist.txt"))
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    print("T01-02 lint passed: canonical nine-image inventory is classified; no source binary was copied.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
