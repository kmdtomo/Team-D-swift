# Shared live runbook

## Current blocker

This revision cannot complete a shared-live run. `Config/Shared.xcconfig`
contains `backend.example.invalid` and `livekit.example.invalid`, and the app
composition uses `UnavailableLiveRuntimeProvider`. The expected result is a
visible live failure with no fixture fallback.

The audited snapshot currently reports:

| Surface | Snapshot availability | Release gate |
| --- | --- | --- |
| `GET /api/health` | available | deploy behind shared HTTPS and pass protected health smoke |
| `POST /api/livekit-token` | available | deploy with server-only credentials and verify least-privilege claims |
| `agent-guidance-push` | unavailable | wire real inference to lossy guidance and reliable state/resync push |
| `POST /api/analyze-shot` | unavailable | deploy frozen v1 handler and protected contract smoke |
| `POST /api/suggest-measurement-points` | unavailable | deploy frozen v1 handler and protected contract smoke |
| `POST /api/generate-background` | unavailable | deploy text-only handler and prove image fields are rejected |
| `POST /api/remove-background` | unavailable | deploy front-only mask handler and validate mask-only PNG |

Do not start acceptance execution until operations and the owning integration
tasks have supplied every surface needed by the intended slice. A fixture run
or an optional local service does not release this blocker.

## Public app configuration

Only these current app build settings are allowed:

| Build setting | Info.plist key | Allowed value |
| --- | --- | --- |
| `TEAM_D_BACKEND_BASE_URL` | `TeamDBackendBaseURL` | public `https://` shared-backend base URL; no user info, query, or fragment |
| `TEAM_D_LIVEKIT_URL` | `TeamDLiveKitURL` | public `wss://` LiveKit Cloud URL; no user info, query, or fragment |
| `TEAM_D_MODE` | `TeamDMode` | supplied by `Debug-Live.xcconfig` as `live`; do not override it |

The URLs are routing metadata, not credentials. Set the two public routing
values as local `Debug-Live` user-defined build settings or protected build
settings. Never commit the local Xcode project/scheme change. Never put a
LiveKit API key, LiveKit API secret, provider API key, token, internal rembg
address, or user image in the app target, an xcconfig, scheme environment,
argument, log, or artifact.

The shared `TeamD` scheme defaults to `Debug-Fixture`. For a live run, locally
set Run > Info > Build Configuration to `Debug-Live`, confirm the app badge is
`Live モード`, and leave fixture providers unavailable. Restore or discard
that local scheme edit after the run; do not commit it.

## Preflight

Use a clean terminal only for the two public routing values. Substitute the
actual public staging hosts supplied by operations:

```sh
export TEAM_D_BACKEND_BASE_URL='https://public-staging-host.example'
export TEAM_D_LIVEKIT_URL='wss://public-project.livekit.cloud'
test "${TEAM_D_BACKEND_BASE_URL#https://}" != "$TEAM_D_BACKEND_BASE_URL"
test "${TEAM_D_LIVEKIT_URL#wss://}" != "$TEAM_D_LIVEKIT_URL"
```

Do not use the committed `.example.invalid` values. Check health with a hard
five-second bound:

```sh
curl --fail --silent --show-error --max-time 5 \
  "$TEAM_D_BACKEND_BASE_URL/api/health"
```

The exact response is `{"status":"ok"}`. Then request one short-lived token
without printing its value:

```sh
curl --fail --silent --show-error --max-time 10 \
  -H 'Content-Type: application/json' \
  --data '{"sessionId":"demo-preflight"}' \
  "$TEAM_D_BACKEND_BASE_URL/api/livekit-token" | \
python3 -c 'import json,sys; p=json.load(sys.stdin); required={"token","participantIdentity","roomName","expiresAt","livekitUrl"}; assert set(p)==required and p["token"] and p["livekitUrl"].startswith(("wss://","https://")); print("token contract valid; credential value withheld")'
```

Stop if health/token fails, if the returned public LiveKit host is unexpected,
or if operations cannot confirm the Agent process, rembg/background provider,
and required endpoints at the same backend release. Never paste the token into
Xcode or an evidence record.

## Timeouts and retry policy

The frozen contract is authoritative:

| Request | Timeout | Retry |
| --- | ---: | --- |
| `GET /api/health` | 5 s | safe caller retry after checking reachability |
| `POST /api/livekit-token` | 10 s | explicit retry only; each retry creates a new identity |
| `POST /api/analyze-shot` | 20 s | same operation ID only for documented transient failure |
| `POST /api/suggest-measurement-points` | 20 s | same operation ID only for documented transient failure |
| `POST /api/remove-background` | 35 s | same operation ID only for documented transient failure |
| `POST /api/generate-background` | 60 s | same operation ID only for documented transient failure |

For the planned four provider routes, only timeout, 429, 502, 503, and 504 are
retryable. Invalid input, schema, content type, and non-retryable provider
errors require correction or a product fallback. Do not retry concurrently.
Keep the same session progress and idempotency key for an allowed same-operation
retry. Health/token have no idempotency key. A live failure stays live.

## Live execution

After every preflight gate is green:

1. Start the shared backend release and Agent through their protected
   operations procedure. Confirm capacity one, one inference in flight, and
   explicit 1--2 fps latest-frame sampling.
2. Launch the auto-signed physical-device `Debug-Live` app. Confirm the live
   badge before granting camera permission.
3. Observe token request, Room join, and app-produced camera publication using
   sanitized server/LiveKit telemetry. Do not log the token, image, track
   payload, or full participant metadata.
4. Confirm the Agent subscribes to camera only and a finite guidance event is
   pushed without periodic HTTP image polling. Check connection, publish, and
   push separately.
5. Execute capture, measurement review/approval, background generation and
   mask, original/composite comparison, explicit image approval, and save as
   described in [the device and demo runbook](device-and-demo.md).
6. End the session and complete the cleanup/privacy checks in
   [troubleshooting and privacy](troubleshooting-and-privacy.md).

At the current revision, step 2 is expected to stop at the unavailable live
provider. Record that blocker; do not claim downstream steps.

## Evidence to record

Record the Swift commit, backend source/release version, contract version,
Xcode build, iPhone model/iOS, build configuration, public host labels, and
timestamps. Record separate pass/fail/not-run results for health, token claims,
Room join, camera subscribe/publish, guidance push, each HTTP provider,
capture, measurement, background, save, and cleanup. Redact tokens and never
attach user images. These blank fields are a checklist, not T18 evidence.
