#!/usr/bin/env python3
"""Reject T03-05 source, contract, pin, and availability drift."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
AUDIT_PATH = ROOT / "docs/contracts/backend-source-audit-v1.json"
DOCUMENT_PATH = ROOT / "docs/architecture/t03-05-backend-gap-audit.md"
AVAILABILITY_PATH = ROOT / "Contracts/HTTP/v1/availability.json"
OPENAPI_PATH = ROOT / "Contracts/HTTP/v1/openapi.json"

SHA = "44065d41e8906d34e5d8e11d7cd4cc14b25d17f2"
CONTRACT_VERSION = "1.0.0"
BACKEND_OWNER = "neko-jpg/Team-D shared backend owner"
PINNED_RUNTIME = {
    "fastapi": "0.116.1",
    "livekit": "1.1.15",
    "livekit-agents": "1.7.1",
    "livekit-api": "1.2.1",
    "uvicorn": "0.35.0",
}
SMOKE_RUNTIME = {
    "livekit-agents": "1.3.12",
    "httpx": "0.28.1",
    "python-dotenv": "1.2.3",
}

EXPECTED_IMPLEMENTED: dict[str, dict[str, Any]] = {
    "GET /api/health": {
        "sourcePaths": ["backend/app.py"],
        "owner": BACKEND_OWNER,
        "contract": "pinned-source GET health surface returns only status=ok and no secret",
        "neededBy": "protected staging preflight",
        "releaseCondition": "implemented at pinned source; protected shared-HTTPS health smoke is tracked separately",
        "evidence": "create_app registers GET /api/health and returns only status=ok",
    },
    "POST /api/livekit-token": {
        "sourcePaths": ["backend/app.py", "backend/livekit_token.py"],
        "owner": BACKEND_OWNER,
        "contract": "strict sessionId request to a 90 second default and 300 second hard-max token with room join, camera/data publish, and explicit subscribe deny",
        "neededBy": "T08-02 protected live smoke",
        "releaseCondition": "implemented at pinned source; protected token-claim and Room-join smoke is tracked separately",
        "evidence": "router is included; token grants publish camera and data, and deny subscribe",
    },
    "LiveKit camera-only transport core": {
        "sourcePaths": ["backend/live_agent.py"],
        "owner": BACKEND_OWNER,
        "contract": "explicit SUBSCRIBE_NONE followed by camera-video-only subscription, VideoStream capacity 1, and at most one inference in flight",
        "neededBy": "T08-02 protected live smoke",
        "releaseCondition": "implemented at pinned source; protected camera subscription is tracked separately",
        "evidence": "explicit SUBSCRIBE_NONE plus video/camera filtering, VideoStream capacity=1, and LatestFrameProcessor max_concurrency=1",
    },
    "Guidance contract and state machine": {
        "sourcePaths": [
            "backend/guidance_state_machine.py",
            "backend/providers/vision_guidance.py",
        ],
        "owner": BACKEND_OWNER,
        "contract": "finite provider decision plus positive session-scoped sequence; GuidanceEvent is lossy and shot-change/resync state is reliable",
        "neededBy": "T08-02 live guidance acceptance",
        "releaseCondition": "implemented at pinned source; real provider and LiveKit publisher remain a separate blocker",
        "evidence": "finite provider decision; lossy GuidanceEvent and reliable shot/resync state carry positive session-scoped sequence",
    },
}

EXPECTED_BLOCKERS: dict[str, dict[str, Any]] = {
    "shared HTTPS FastAPI staging integration": {
        "sourcePaths": ["package.json", "README.md", "backend/app.py"],
        "owner": BACKEND_OWNER,
        "contract": "deploy the audited FastAPI health/token surface behind a non-secret HTTPS base URL and make protected staging credentials available outside this repository",
        "neededBy": "T08-02 protected live smoke",
        "releaseCondition": "health and least-privilege token claims pass against protected staging; Room join and camera-only subscription are observed without fixture fallback",
    },
    "real AI inference to LiveKit Guidance push": {
        "sourcePaths": [
            "backend/live_agent.py",
            "backend/guidance_state_machine.py",
            "backend/providers/vision_guidance.py",
        ],
        "owner": BACKEND_OWNER,
        "contract": "adapt a VisionGuidanceProvider result through GuidanceStateMachine and publish GuidanceEvent as lossy data; publish shot-change/resync as reliable data packet or RPC",
        "neededBy": "T08-02 live guidance acceptance",
        "releaseCondition": "a protected Room smoke observes finite, session/shot/sequence/expiry-valid pushed events; no HTTP polling or free-text navigation is introduced",
    },
    "1-2 fps Agent sampling policy": {
        "sourcePaths": ["backend/live_agent.py"],
        "owner": BACKEND_OWNER,
        "contract": "sample the latest camera frame at an explicit 1-2 fps bound while retaining capacity=1 and one inference in flight",
        "neededBy": "T08-02 and T18-02 live performance evidence",
        "releaseCondition": "source test and protected metrics demonstrate a 1-2 fps selection rate, pending capacity <= 1, and inference concurrency <= 1",
    },
    "POST /api/analyze-shot": {
        "sourcePaths": ["backend/app.py"],
        "owner": BACKEND_OWNER,
        "contract": "frozen v1 multipart requestedShot plus image to strict ShotAssessment, ProviderError envelope, and 20 second timeout",
        "neededBy": "T09-02 live acceptance",
        "releaseCondition": "endpoint is deployed and T09-02's protected contract smoke covers success, invalid input, timeout, and provider failure",
    },
    "POST /api/suggest-measurement-points": {
        "sourcePaths": ["backend/app.py"],
        "owner": BACKEND_OWNER,
        "contract": "frozen v1 corrected measurement multipart image to exactly four NormalizedPoint values, ProviderError envelope, and 20 second timeout",
        "neededBy": "T12-02 live acceptance",
        "releaseCondition": "endpoint is deployed and T12-02's protected contract smoke covers success, invalid input, timeout, and provider failure",
    },
    "POST /api/generate-background": {
        "sourcePaths": ["backend/app.py"],
        "owner": BACKEND_OWNER,
        "contract": "frozen v1 text-only allowed style request to image/png background, ProviderError envelope, and 60 second timeout; no image, mask, tag, or measurement input",
        "neededBy": "T14-02 live acceptance",
        "releaseCondition": "endpoint is deployed and T14-02's protected contract smoke proves image fields are rejected and failure retains session progress",
    },
    "POST /api/remove-background": {
        "sourcePaths": ["backend/app.py"],
        "owner": BACKEND_OWNER,
        "contract": "frozen v1 front-only multipart image to same-size mask-only image/png, ProviderError envelope, and 35 second timeout",
        "neededBy": "T14-01 live acceptance",
        "releaseCondition": "endpoint is deployed and T14-01's protected contract smoke proves non-front bytes are rejected and invalid masks are not accepted",
    },
}

EXPECTED_AVAILABILITY = {
    "health": ("/api/health", "get", True),
    "livekit-token": ("/api/livekit-token", "post", True),
    "analyze-shot": ("/api/analyze-shot", "post", False),
    "suggest-measurement-points": ("/api/suggest-measurement-points", "post", False),
    "generate-background": ("/api/generate-background", "post", False),
    "remove-background": ("/api/remove-background", "post", False),
    "agent-guidance-push": (None, None, False),
}

REQUIRED_DOCUMENT_TEXT = {
    SHA,
    "FastAPI 0.116.1",
    "LiveKit Python 1.1.15",
    "LiveKit Agents 1.7.1",
    "LiveKit API 1.2.1",
    "requirements-livekit-smoke.txt",
    "smoke-only environment",
    "tests/test_livekit_token.py",
    "tests/test_live_agent.py",
    "tests/test_guidance_contract.py",
    "25 passed, 1 skipped",
    "shared HTTPS FastAPI staging",
    "real AI inference to LiveKit Guidance push",
    "1-2 fps Agent sampling policy",
    "code_ready_unverified",
    "does not mean the lint/test was executed",
}


class AuditValidationError(ValueError):
    """Raised when the committed audit no longer expresses the frozen facts."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditValidationError(message)


def keyed(items: object, label: str) -> dict[str, dict[str, Any]]:
    require(isinstance(items, list), f"{label} must be an array")
    result: dict[str, dict[str, Any]] = {}
    for item in items:
        require(isinstance(item, dict), f"{label} entries must be objects")
        surface = item.get("surface")
        require(isinstance(surface, str) and surface, f"{label} surface must be non-empty")
        require(surface not in result, f"duplicate {label} surface: {surface}")
        result[surface] = item
    return result


def validate_audit(audit: object) -> None:
    require(isinstance(audit, dict), "audit root must be an object")
    require(
        set(audit) == {
            "schemaVersion",
            "source",
            "productionRuntime",
            "smokeRuntime",
            "implemented",
            "blockers",
        },
        "audit root fields drifted",
    )
    require(audit["schemaVersion"] == 1, "unsupported audit schemaVersion")
    require(
        audit["source"]
        == {
            "repository": "https://github.com/neko-jpg/Team-D",
            "sha": SHA,
            "access": "read-only git archive",
            "pythonMinimum": "3.11",
        },
        "source authority drifted",
    )
    require(
        audit["productionRuntime"]
        == {"requirementsFile": "requirements-backend.txt", "pins": PINNED_RUNTIME},
        "production runtime pins drifted",
    )
    require(
        audit["smokeRuntime"]
        == {
            "requirementsFile": "requirements-livekit-smoke.txt",
            "scope": "smoke-only; never a production runtime pin",
            "pins": SMOKE_RUNTIME,
        },
        "smoke-only runtime pins or scope drifted",
    )
    require(
        SMOKE_RUNTIME["livekit-agents"] != PINNED_RUNTIME["livekit-agents"],
        "smoke runtime must remain distinct from production",
    )

    implemented = keyed(audit["implemented"], "implemented")
    blockers = keyed(audit["blockers"], "blocker")
    require(set(implemented) == set(EXPECTED_IMPLEMENTED), "implemented surface set drifted")
    require(set(blockers) == set(EXPECTED_BLOCKERS), "blocker surface set drifted")
    for surface, expected in EXPECTED_IMPLEMENTED.items():
        require(
            implemented[surface] == {"surface": surface, **expected},
            f"implemented metadata drifted: {surface}",
        )
    for surface, expected in EXPECTED_BLOCKERS.items():
        require(
            blockers[surface] == {"surface": surface, **expected},
            f"blocker metadata drifted: {surface}",
        )


def validate_availability(availability: object) -> None:
    require(isinstance(availability, dict), "availability root must be an object")
    require(availability.get("version") == CONTRACT_VERSION, "availability version drifted")
    require(availability.get("pinnedSourceSHA") == SHA, "availability source SHA drifted")
    surfaces = availability.get("surfaces")
    require(isinstance(surfaces, dict), "availability surfaces must be an object")
    require(set(surfaces) == set(EXPECTED_AVAILABILITY), "availability surface set drifted")
    for name, (path, _method, available) in EXPECTED_AVAILABILITY.items():
        item = surfaces[name]
        require(isinstance(item, dict), f"availability surface must be an object: {name}")
        require(item.get("available") is available, f"availability state drifted: {name}")
        if path is None:
            require("path" not in item, f"non-HTTP availability surface gained a path: {name}")
        else:
            require(item.get("path") == path, f"availability path drifted: {name}")
        require(item.get("owner") == "shared backend", f"availability owner drifted: {name}")
        require(
            isinstance(item.get("evidence"), str) and bool(item["evidence"].strip()),
            f"availability evidence missing: {name}",
        )
        require(
            isinstance(item.get("releaseCondition"), str)
            and bool(item["releaseCondition"].strip()),
            f"availability release condition missing: {name}",
        )


def validate_openapi(openapi: object) -> None:
    require(isinstance(openapi, dict), "OpenAPI root must be an object")
    info = openapi.get("info")
    require(isinstance(info, dict), "OpenAPI info must be an object")
    require(info.get("version") == CONTRACT_VERSION, "OpenAPI version drifted")
    paths = openapi.get("paths")
    require(isinstance(paths, dict), "OpenAPI paths must be an object")
    for path, method, available in EXPECTED_AVAILABILITY.values():
        if path is None:
            continue
        require(path in paths, f"OpenAPI path missing: {path}")
        path_item = paths[path]
        require(isinstance(path_item, dict), f"OpenAPI path must be an object: {path}")
        operation = path_item.get(method)
        require(isinstance(operation, dict), f"OpenAPI method missing: {method} {path}")
        expected = "implemented" if available else "unavailable"
        require(
            operation.get("x-team-d-availability") == expected,
            f"OpenAPI availability drifted: {path}",
        )


def validate_document(document: object) -> None:
    require(isinstance(document, str), "audit document must be text")
    for required in REQUIRED_DOCUMENT_TEXT:
        require(required in document, f"audit document omitted required evidence: {required}")
    for surface in EXPECTED_BLOCKERS:
        require(surface in document, f"audit document omitted blocker: {surface}")


def validate_repository(root: Path = ROOT) -> None:
    audit = json.loads((root / AUDIT_PATH.relative_to(ROOT)).read_text())
    availability = json.loads((root / AVAILABILITY_PATH.relative_to(ROOT)).read_text())
    openapi = json.loads((root / OPENAPI_PATH.relative_to(ROOT)).read_text())
    document = (root / DOCUMENT_PATH.relative_to(ROOT)).read_text()
    validate_audit(audit)
    validate_availability(availability)
    validate_openapi(openapi)
    validate_document(document)
    source_text = (root / "requirements.md").read_text() + (root / "task.md").read_text()
    require(source_text.count(SHA) >= 2, "requirements/task source pin drifted")


def main() -> None:
    validate_repository()
    print("T03-05 backend source audit lint passed")


if __name__ == "__main__":
    main()
