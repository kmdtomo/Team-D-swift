#!/usr/bin/env bash
# Protected, explicit health/token smoke. It never builds or launches the app.
set -euo pipefail

if [[ "${GITHUB_EVENT_NAME:-}" != "workflow_dispatch" || "${TEAM_D_ALLOW_PROTECTED_LIVE_SMOKE:-}" != "1" ]]; then
  echo "Live smoke is allowed only from the protected workflow_dispatch job." >&2
  exit 1
fi

backend_base_url="${TEAM_D_LIVE_BACKEND_BASE_URL:-}"
live_bearer="${TEAM_D_LIVE_SMOKE_BEARER:-}"
if [[ -z "$live_bearer" ]]; then
  echo "Protected live smoke credential is unavailable." >&2
  exit 1
fi
if [[ ! "$live_bearer" =~ ^[A-Za-z0-9._~-]+$ ]]; then
  echo "Protected live smoke credential has an invalid bearer-token shape." >&2
  exit 1
fi
backend_base_url="$(python3 - "$backend_base_url" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit, urlunsplit

value = urlsplit(sys.argv[1])
if value.scheme != "https" or not value.hostname or value.username or value.password:
    raise SystemExit("Protected live smoke requires one public HTTPS backend base URL.")
if value.path not in ("", "/") or value.query or value.fragment:
    raise SystemExit("Protected live smoke backend URL cannot contain a path, query, or fragment.")
if value.hostname.casefold() == "localhost":
    raise SystemExit("Protected live smoke backend must not be localhost.")
try:
    address = ipaddress.ip_address(value.hostname)
except ValueError:
    pass
else:
    if not address.is_global:
        raise SystemExit("Protected live smoke backend must use a public address.")
print(urlunsplit((value.scheme, value.netloc, "", "", "")))
PY
)"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/teamd-live-smoke.XXXXXX")"
cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT

session_id="ci-${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}"
printf '{"sessionId":"%s"}\n' "$session_id" > "$temporary_root/token-request.json"
authorization_scheme="Bearer"
curl_config="$temporary_root/curl.conf"
printf 'header = "Authorization: %s %s"\n' "$authorization_scheme" "$live_bearer" > "$curl_config"
chmod 600 "$curl_config"

health_status="$(curl --silent --show-error \
  --config "$curl_config" \
  --connect-timeout 5 --max-time 10 \
  --output "$temporary_root/health.json" \
  --write-out '%{http_code}' \
  "$backend_base_url/api/health")"
if [[ "$health_status" != "200" ]]; then
  echo "Protected health smoke failed with HTTP $health_status; response body is suppressed." >&2
  exit 1
fi

token_status="$(curl --silent --show-error \
  --config "$curl_config" \
  --connect-timeout 5 --max-time 15 \
  --header 'Content-Type: application/json' \
  --data-binary "@$temporary_root/token-request.json" \
  --output "$temporary_root/token.json" \
  --write-out '%{http_code}' \
  "$backend_base_url/api/livekit-token")"
if [[ "$token_status" != "200" ]]; then
  echo "Protected token smoke failed with HTTP $token_status; response body is suppressed." >&2
  exit 1
fi

python3 - "$temporary_root/health.json" "$temporary_root/token.json" <<'PY'
import json
import sys
from pathlib import Path

health = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
token = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
if health != {"status": "ok"}:
    raise SystemExit("protected health response drifted from the v1 contract")
required = {"token", "participantIdentity", "roomName", "expiresAt", "livekitUrl"}
if set(token) != required:
    raise SystemExit("protected token response fields drifted from the v1 contract")
if not all(isinstance(token[name], str) and token[name] for name in ("token", "participantIdentity", "roomName")):
    raise SystemExit("protected token response has empty identity fields")
if not isinstance(token["expiresAt"], int) or token["expiresAt"] <= 0:
    raise SystemExit("protected token response has an invalid expiry")
if not isinstance(token["livekitUrl"], str) or not token["livekitUrl"].startswith("wss://"):
    raise SystemExit("protected token response requires a WSS URL")
PY

echo "Protected health/token contract smoke passed; response values were not logged or retained."
