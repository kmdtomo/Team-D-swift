# Troubleshooting, privacy, and failure isolation

## Failure isolation order

Test one layer at a time and stop at the first failure:

| Layer | Check | Interpretation / owner |
| --- | --- | --- |
| Mode/config | `Debug-Fixture` + `テストデータ`, or `Debug-Live` + `Live モード` | mismatch is iOS configuration; never relabel the provider |
| Public route | HTTPS/WSS host is not `.example.invalid` | missing route is staging operations/configuration |
| Health | `GET /api/health` returns exact ok JSON in 5 s | DNS/TLS/deploy failure belongs to shared backend operations |
| Token | strict token fields arrive in 10 s without printing token | 422 is request/session ID; 503 is server-side LiveKit configuration |
| Room | iPhone joins expected Room | join/TLS/token claim issue; do not retry with a stored token |
| Publish | one app-produced camera track appears | iOS LiveKit adapter/camera handoff; physical device required |
| Subscribe | Agent subscribes to camera only | Agent deployment/track filtering |
| Push | finite current session/shot guidance arrives | provider/state-machine/publisher; pinned snapshot is unavailable |
| Analyze | `POST /api/analyze-shot` follows v1 | unavailable at pinned snapshot; shared backend owner |
| Measure | `POST /api/suggest-measurement-points` follows v1 | unavailable at pinned snapshot; shared backend owner |
| Mask | `POST /api/remove-background` returns validated mask-only PNG | unavailable at pinned snapshot; backend/rembg owner |
| Background | `POST /api/generate-background` sends text-only style | unavailable at pinned snapshot; background provider owner |
| App flow | capture through approved save | owning feature/device task; do not skip a failed preceding layer |

`UnavailableLiveRuntimeProvider` is the expected app-side blocker at this
revision. A separately successful fixture run narrows the failure to live
composition or external services; it does not clear the live failure.

## Timeout and retry matrix

| Contract operation | Timeout | Retry decision |
| --- | ---: | --- |
| `GET /api/health` | 5 s | safe sequential caller retry |
| `POST /api/livekit-token` | 10 s | explicit sequential retry; discard old token and identity |
| `POST /api/analyze-shot` | 20 s | retry only timeout/429/502/503/504 with same operation ID |
| `POST /api/suggest-measurement-points` | 20 s | retry only timeout/429/502/503/504 with same operation ID |
| `POST /api/remove-background` | 35 s | retry only timeout/429/502/503/504 with same operation ID |
| `POST /api/generate-background` | 60 s | retry only timeout/429/502/503/504 with same operation ID |

Never retry invalid input, unsupported content type, invalid schema, or a
non-retryable provider error. Never issue concurrent retries. Cancellation,
timeout, reconnect, and retry must preserve accepted slots, measurement edits,
and the explicit live mode. A user may choose the documented local fixed
background or original front after a provider failure; that product fallback
is not fixture mode and must remain visible.

## Session data and privacy

- Keep images, masks, assessments, endpoints, measurements, provider replies,
  and intermediate composites only in the current session's memory/protected
  temporary storage. Do not use DB, UserDefaults, ordinary URLCache, or cloud
  diagnostic upload.
- On retake, discard derived results for the replaced image without deleting
  other accepted slots. On session end/new session/abnormal recovery, verify
  every non-export artifact is inaccessible and temporary storage is removed.
- Stop camera capture, local analyzers, HTTP tasks, published track, and Room
  connection. A second session must start without a duplicate camera owner or
  stale event/result.
- Save/export only the independently selected and explicitly approved final
  front image. The user controls deletion of that final export from Photos or
  Files; the app must not retain a second copy.
- Never use `back`, `tag`, or `measurement` as mask/background input. Never
  upload an image to background generation. Never regenerate or retouch the
  garment; foreground RGB comes only from original `front`.

Treat cleanup checks as pending until a physical/live run records them. The
runbook itself is not privacy evidence.

## Logs and evidence

Allowed evidence is sanitized status metadata: commit/build/release IDs,
device/OS, timestamps, finite error code, elapsed time, pass/fail/not-run, and
aggregate performance. Do not record request/response bodies except the public
health JSON, tokens, credentials, Room URLs with credentials, participant
identities tied to a person, user images, masks, endpoint coordinates, full
filesystem paths, internal rembg routing, or provider free text.

Before sharing any build log, search it locally for credential names, bearer
headers, JWT-like values, user paths, and image filenames. If found, discard
the artifact and rerun with sanitized logging; do not hand-edit a leaked token
into a supposedly safe artifact. Revoke any exposed credential through its
owning service.

## Escalation

After two identical failures, record the first failing layer, public status
code or finite app error, elapsed time, commit/build/backend release, and the
last successful layer. Escalate to that layer's owner with secrets and images
omitted. State whether fixture and live were independently attempted and keep
all downstream gates `not run`. Do not change product requirements, timeout
values, providers, or mode to make the check pass.
