# T19-02 runbook index

This directory is the operator entry point for development, live integration,
physical-device checks, demo preparation, privacy, and failure isolation. The
runbooks describe reproducible procedures; they are not evidence that a
procedure has already passed.

## Current implementation truth

The repository is pinned to the read-only source audit at
`neko-jpg/Team-D@44065d41e8906d34e5d8e11d7cd4cc14b25d17f2`.
At this Swift repository revision:

- `Debug-Fixture` is deterministic and requires no backend, LiveKit project,
  Docker, API credential, or physical camera.
- `Config/Shared.xcconfig` still routes to `backend.example.invalid` and
  `livekit.example.invalid`.
- live startup uses `UnavailableLiveRuntimeProvider`; it fails visibly and
  never substitutes fixture success.
- the audited source implements health and token issuance. Shared HTTPS
  staging, Agent guidance push, explicit 1--2 fps sampling, shot analysis,
  measurement-point suggestion, background generation, and background removal
  are still release-gated as recorded in
  [the backend gap audit](../architecture/t03-05-backend-gap-audit.md).
- T18 physical-device and end-to-end live evidence is pending. Nothing in
  these runbooks claims T18 completion.

Fixture and live are independent modes and need independent evidence.

## Runbook order

1. Start with [the deterministic fixture runbook](fixture.md). It is the only
   route that is expected to work without external services.
2. Use [the shared live runbook](live.md) only after every named readiness gate
   is supplied by the shared-backend and iOS integration owners.
3. Use [the physical iPhone and demo runbook](device-and-demo.md) for automatic
   signing, device checks, the 50 mm marker, service prewarm, and the
   capture-to-save checklist.
4. Use [the optional local backend runbook](optional-local-backend.md) only for
   backend diagnosis. It is not part of fixture onboarding or the supported
   shared-live route.
5. Use [troubleshooting and privacy](troubleshooting-and-privacy.md) to isolate
   failures without exposing session data or changing modes.

The established first-run details remain in
[the T02-03 fixture baseline](../development/fixture-baseline.md). Contract and
availability authority remains in
[`Contracts/HTTP/v1/availability.json`](../../Contracts/HTTP/v1/availability.json)
and [`Contracts/HTTP/v1/openapi.json`](../../Contracts/HTTP/v1/openapi.json).

## Evidence boundary

Every evidence record must include commit, Xcode build, build configuration,
device/Simulator and OS, start/end timestamps, and the exact result. Keep
fixture and live results in separate entries. Record a blocked or failed step
as blocked or failed; do not continue by changing to fixture and label that a
live result.

Never store tokens, credentials, user images, internal rembg routing, or raw
provider payloads in the repository, build log, screenshot, or test artifact.
Only the final image independently selected and approved by the user may be
exported.

## Documentation validation

The source-only validator checks local links and command references, current
configuration keys, contract availability/timeouts, required sections,
fixture/live separation, optional-local wording, and prohibited secret
assignments:

```sh
python3 scripts/lint_t19_02_runbooks.py
```

The dedicated negative tests are authored for Phase 2 and intentionally not
executed as part of T19-02 Phase 1:

```sh
python3 scripts/test_lint_t19_02_runbooks.py
```
