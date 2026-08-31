#!/usr/bin/env python3
"""Reject T03-05 source-SHA, pin, and availability drift without source access."""
from __future__ import annotations

import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUDIT_PATH = ROOT / "docs/contracts/backend-source-audit-v1.json"
SHA = "44065d41e8906d34e5d8e11d7cd4cc14b25d17f2"
PINNED_RUNTIME = {
    "fastapi": "0.116.1",
    "livekit": "1.1.15",
    "livekit-agents": "1.7.1",
    "livekit-api": "1.2.1",
    "uvicorn": "0.35.0",
}
IMPLEMENTED = {
    "GET /api/health",
    "POST /api/livekit-token",
    "LiveKit camera-only transport core",
    "Guidance contract and state machine",
}
IMPLEMENTED_PATHS = {
    "GET /api/health": ["backend/app.py"],
    "POST /api/livekit-token": ["backend/app.py", "backend/livekit_token.py"],
    "LiveKit camera-only transport core": ["backend/live_agent.py"],
    "Guidance contract and state machine": ["backend/guidance_state_machine.py", "backend/providers/vision_guidance.py"],
}
BLOCKED = {
    "shared HTTPS FastAPI staging integration",
    "real AI inference to LiveKit Guidance push",
    "1-2 fps Agent sampling policy",
    "POST /api/analyze-shot",
    "POST /api/suggest-measurement-points",
    "POST /api/generate-background",
    "POST /api/remove-background",
}
BLOCKER_PATHS = {
    "shared HTTPS FastAPI staging integration": ["package.json", "README.md", "backend/app.py"],
    "real AI inference to LiveKit Guidance push": ["backend/live_agent.py", "backend/guidance_state_machine.py", "backend/providers/vision_guidance.py"],
    "1-2 fps Agent sampling policy": ["backend/live_agent.py"],
    "POST /api/analyze-shot": ["backend/app.py"],
    "POST /api/suggest-measurement-points": ["backend/app.py"],
    "POST /api/generate-background": ["backend/app.py"],
    "POST /api/remove-background": ["backend/app.py"],
}


def validate(audit: object) -> None:
    assert isinstance(audit, dict) and set(audit) == {
        "schemaVersion", "source", "productionRuntime", "smokeRuntime", "implemented", "blockers"
    }
    assert audit["schemaVersion"] == 1
    source = audit["source"]
    assert source == {
        "repository": "https://github.com/neko-jpg/Team-D",
        "sha": SHA,
        "access": "read-only git archive",
        "pythonMinimum": "3.11",
    }
    production = audit["productionRuntime"]
    assert production == {"requirementsFile": "requirements-backend.txt", "pins": PINNED_RUNTIME}
    smoke = audit["smokeRuntime"]
    assert smoke["requirementsFile"] == "requirements-livekit-smoke.txt"
    assert smoke["scope"] == "smoke-only; never a production runtime pin"
    assert smoke["pins"] == {"livekit-agents": "1.3.12", "httpx": "0.28.1", "python-dotenv": "1.2.3"}
    assert smoke["pins"]["livekit-agents"] != PINNED_RUNTIME["livekit-agents"]

    implemented = audit["implemented"]
    assert isinstance(implemented, list)
    implemented_surfaces = [item["surface"] for item in implemented]
    assert len(implemented_surfaces) == len(IMPLEMENTED) == len(set(implemented_surfaces))
    assert set(implemented_surfaces) == IMPLEMENTED
    for item in implemented:
        assert set(item) == {"surface", "sourcePaths", "evidence"}
        assert item["sourcePaths"] == IMPLEMENTED_PATHS[item["surface"]]
        assert isinstance(item["evidence"], str) and item["evidence"]

    blockers = audit["blockers"]
    assert isinstance(blockers, list)
    blocker_surfaces = [item["surface"] for item in blockers]
    assert len(blocker_surfaces) == len(BLOCKED) == len(set(blocker_surfaces))
    assert set(blocker_surfaces) == BLOCKED
    for item in blockers:
        assert set(item) == {"surface", "sourcePaths", "owner", "contract", "neededBy", "releaseCondition"}
        assert item["sourcePaths"] == BLOCKER_PATHS[item["surface"]]
        assert item["owner"] == "neko-jpg/Team-D shared backend owner"
        assert all(isinstance(item[field], str) and item[field] for field in ("contract", "neededBy", "releaseCondition"))

    source_text = (ROOT / "requirements.md").read_text() + (ROOT / "task.md").read_text()
    assert source_text.count(SHA) >= 2
    availability = json.loads((ROOT / "Contracts/HTTP/v1/availability.json").read_text())
    assert availability["pinnedSourceSHA"] == SHA
    unavailable = {
        surface["path"]
        for surface in availability["surfaces"].values()
        if surface.get("available") is False and "path" in surface
    }
    assert unavailable == {"/api/analyze-shot", "/api/suggest-measurement-points", "/api/generate-background", "/api/remove-background"}


def rejects(mutator) -> None:
    candidate = copy.deepcopy(AUDIT)
    mutator(candidate)
    try:
        validate(candidate)
    except AssertionError:
        return
    raise AssertionError("negative semantic audit case unexpectedly passed")


AUDIT = json.loads(AUDIT_PATH.read_text())
validate(AUDIT)
rejects(lambda value: value["source"].update(sha="0" * 40))
rejects(lambda value: value["productionRuntime"]["pins"].update({"livekit-agents": "1.3.12"}))
rejects(lambda value: value["productionRuntime"]["pins"].pop("uvicorn"))
rejects(lambda value: value["blockers"].pop())
rejects(lambda value: value["blockers"][0].update(owner="Swift client"))
rejects(lambda value: value["implemented"][0].update(sourcePaths=["backend/imagined.py"]))
rejects(lambda value: value["implemented"].append(copy.deepcopy(value["implemented"][0])))
rejects(lambda value: value["blockers"].append(copy.deepcopy(value["blockers"][0])))
print("T03-05 backend source audit lint passed")
