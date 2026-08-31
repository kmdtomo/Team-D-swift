#!/usr/bin/env python3
"""stdlib-only consistency checks for the frozen T03-02 HTTP v1 contract."""

from __future__ import annotations

import base64
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "Contracts" / "HTTP" / "v1"
EXPECTED_PATHS = {
    "/api/health": ("implemented", 5, "none"),
    "/api/livekit-token": ("implemented", 10, "none"),
    "/api/analyze-shot": ("unavailable", 20, "required-stable-per-operation"),
    "/api/suggest-measurement-points": ("unavailable", 20, "required-stable-per-operation"),
    "/api/generate-background": ("unavailable", 60, "required-stable-per-operation"),
    "/api/remove-background": ("unavailable", 35, "required-stable-per-operation"),
}
REQUIRED_GOLDENS = {
    "health.response.json", "token.request.json", "token.response.json", "token.error-422.json", "token.error-422-validation.json", "token.error-503.json",
    "analyze-shot.request.parts.json", "analyze-shot.response.json", "analyze-shot.error.json",
    "measurement.request.parts.json", "measurement.response.json", "measurement.error.json",
    "background.request.json", "background.response.png.json", "background.error.json",
    "mask.request.parts.json", "mask.response.png.json", "mask.error.json",
}


def load(path: Path) -> object:
    with path.open(encoding="utf-8") as file:
        return json.load(file)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def validate_png_metadata(value: object, label: str) -> None:
    require(isinstance(value, dict), f"{label}: object required")
    require(set(value) == {"contentType", "base64", "sha256", "sourceFree"}, f"{label}: strict fields")
    require(value["contentType"] == "image/png" and value["sourceFree"] is True, f"{label}: PNG/sourceFree")
    payload = base64.b64decode(value["base64"], validate=True)
    require(payload.startswith(b"\x89PNG\r\n\x1a\n"), f"{label}: PNG signature")
    require(hashlib.sha256(payload).hexdigest() == value["sha256"], f"{label}: sha256")


def validate_references(value: object, root: object) -> None:
    if isinstance(value, dict):
        reference = value.get("$ref")
        if isinstance(reference, str):
            if reference.startswith("#/"):
                target = root
                for segment in reference[2:].split("/"):
                    require(isinstance(target, dict) and segment in target, f"broken internal reference {reference}")
                    target = target[segment]
            elif "#" not in reference:
                require((CONTRACT / reference).is_file(), f"broken external reference {reference}")
            else:
                raise AssertionError(f"unsupported reference {reference}")
        for child in value.values():
            validate_references(child, root)
    elif isinstance(value, list):
        for child in value:
            validate_references(child, root)


def resolve(schema: dict[str, object], root: dict[str, object]) -> dict[str, object]:
    reference = schema.get("$ref")
    if not isinstance(reference, str):
        return schema
    if reference.startswith("#/"):
        target: object = root
        for segment in reference[2:].split("/"):
            target = target[segment]  # type: ignore[index]
        return resolve(target, root)  # type: ignore[arg-type]
    return load(CONTRACT / reference)  # type: ignore[return-value]


def validate(value: object, schema: dict[str, object], root: dict[str, object]) -> None:
    schema = resolve(schema, root)
    if "oneOf" in schema:
        matches = 0
        for alternative in schema["oneOf"]:  # type: ignore[index]
            try:
                validate(value, alternative, root)
                matches += 1
            except AssertionError:
                pass
        require(matches == 1, "oneOf mismatch")
        return
    if "const" in schema:
        require(value == schema["const"], "const mismatch")
    if "enum" in schema:
        require(value in schema["enum"], "enum mismatch")
    kind = schema.get("type")
    checks = {"object": lambda: isinstance(value, dict), "array": lambda: isinstance(value, list), "string": lambda: isinstance(value, str), "integer": lambda: isinstance(value, int) and not isinstance(value, bool), "number": lambda: isinstance(value, (int, float)) and not isinstance(value, bool), "boolean": lambda: isinstance(value, bool)}
    if kind:
        require(checks[kind](), f"type mismatch: {kind}")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        for name in schema.get("required", []):
            require(name in value, f"missing {name}")
        if schema.get("additionalProperties") is False:
            require(set(value) <= set(properties), "unknown property")
        for name, child in properties.items():
            if name in value:
                validate(value[name], child, root)
    if isinstance(value, list):
        require(len(value) >= schema.get("minItems", 0), "minItems")
        if "maxItems" in schema:
            require(len(value) <= schema["maxItems"], "maxItems")
        if "items" in schema:
            for child in value:
                validate(child, schema["items"], root)
    if isinstance(value, str):
        require(len(value) >= schema.get("minLength", 0), "minLength")
        if "maxLength" in schema:
            require(len(value) <= schema["maxLength"], "maxLength")
        if "pattern" in schema:
            import re
            require(re.search(schema["pattern"], value) is not None, "pattern")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        require(value == value and value not in (float("inf"), -float("inf")), "finite")
        if "minimum" in schema:
            require(value >= schema["minimum"], "minimum")
        if "maximum" in schema:
            require(value <= schema["maximum"], "maximum")


def main() -> None:
    openapi_path = CONTRACT / "openapi.json"
    availability_path = CONTRACT / "availability.json"
    openapi = load(openapi_path)
    availability = load(availability_path)
    rendered = openapi_path.read_text(encoding="utf-8")
    require("/api/analyze-live" not in rendered, "forbidden endpoint present")
    require(openapi["openapi"] == "3.1.0" and openapi["info"]["version"] == "1.0.0", "OpenAPI v1 required")
    validate_references(openapi, openapi)
    require(set(openapi["paths"]) == set(EXPECTED_PATHS), "exactly six paths required")
    schemas = openapi["components"]["schemas"]
    for path, (status, timeout, idempotency) in EXPECTED_PATHS.items():
        operation = next(iter(openapi["paths"][path].values()))
        require(operation["x-team-d-availability"] == status, f"{path}: availability")
        require(operation["x-team-d-timeout-seconds"] == timeout, f"{path}: timeout")
        require(operation["x-team-d-idempotency"] == idempotency, f"{path}: idempotency")
        expected_retry = "safe-caller-retry" if path == "/api/health" else "explicit-only-new-identity" if path == "/api/livekit-token" else "caller-may-retry-documented-failures"
        require(operation["x-team-d-retry"] == expected_retry, f"{path}: retry")
        if status == "unavailable":
            require(any(parameter.get("$ref") == "#/components/parameters/IdempotencyKey" for parameter in operation["parameters"]), f"{path}: idempotency header")
            require(operation["x-team-d-timeout-retryable"] is True, f"{path}: timeout retry")
    for path in ("/api/analyze-shot", "/api/suggest-measurement-points", "/api/remove-background"):
        encoding = next(iter(openapi["paths"][path].values()))["requestBody"]["content"]["multipart/form-data"]["encoding"]
        require(encoding["image"]["contentType"] == "image/jpeg, image/png, image/heic", f"{path}: image media")
    require("contentMediaType" not in schemas["ImageRequest"]["properties"]["image"], "ImageRequest MIME belongs to multipart encoding")
    require("contentMediaType" not in schemas["AnalyzeRequest"]["properties"]["image"], "AnalyzeRequest MIME belongs to multipart encoding")
    require(openapi["paths"]["/api/analyze-shot"]["post"]["requestBody"]["content"]["multipart/form-data"]["encoding"]["requestedShot"]["contentType"] == "text/plain", "analyze text part")
    surfaces = availability["surfaces"]
    require(availability["pinnedSourceSHA"] == "44065d41e8906d34e5d8e11d7cd4cc14b25d17f2", "pinned SHA")
    require(surfaces["health"]["available"] and surfaces["livekit-token"]["available"], "implemented surfaces")
    for name in ("analyze-shot", "suggest-measurement-points", "generate-background", "remove-background", "agent-guidance-push"):
        require(surfaces[name]["available"] is False, f"{name}: must remain unavailable")
        require(all(surfaces[name].get(field) for field in ("owner", "evidence", "releaseCondition")), f"{name}: provenance")
    provider_schema = load(CONTRACT / "schemas" / "provider-error.schema.json")
    require(provider_schema["additionalProperties"] is False, "strict provider error")
    manifest = load(CONTRACT / "goldens.json")
    files = {Path(name).name for name in manifest["files"]}
    require(files == REQUIRED_GOLDENS, "golden manifest drift")
    for relative in manifest["files"]:
        require((CONTRACT / relative).is_file(), f"missing golden {relative}")
    validate_png_metadata(load(CONTRACT / "goldens" / "background.response.png.json"), "background PNG")
    validate_png_metadata(load(CONTRACT / "goldens" / "mask.response.png.json"), "mask PNG")
    background = load(CONTRACT / "goldens" / "background.request.json")
    require(set(background) == {"styleId"}, "background must be text-only styleId")
    measurement = load(CONTRACT / "goldens" / "measurement.response.json")
    require(set(measurement) == {"lengthStart", "lengthEnd", "widthStart", "widthEnd"}, "measurement has exactly four points")
    golden_schemas = {"health.response.json": "Health", "token.request.json": "TokenRequest", "token.response.json": "TokenResponse", "token.error-422.json": "TokenValidationError", "token.error-422-validation.json": "TokenValidationError", "token.error-503.json": "TokenError", "analyze-shot.response.json": "ShotAssessment", "analyze-shot.error.json": "ProviderError", "measurement.response.json": "MeasurementPoints", "measurement.error.json": "ProviderError", "background.request.json": "BackgroundRequest", "background.error.json": "ProviderError", "mask.error.json": "ProviderError"}
    for filename, schema_name in golden_schemas.items():
        validate(load(CONTRACT / "goldens" / filename), schemas[schema_name], openapi)
    multipart = {"analyze-shot.request.parts.json": "schemas/multipart-analyze.schema.json", "measurement.request.parts.json": "schemas/multipart-image.schema.json", "mask.request.parts.json": "schemas/multipart-mask.schema.json"}
    for filename, schema_file in multipart.items():
        manifest_value = load(CONTRACT / "goldens" / filename)
        validate(manifest_value, load(CONTRACT / schema_file), openapi)
    print("T03-02 contract lint passed.")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"T03-02 contract lint failed: {error}", file=sys.stderr)
        raise SystemExit(1)
