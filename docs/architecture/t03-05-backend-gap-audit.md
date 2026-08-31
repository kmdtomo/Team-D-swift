# T03-05 backend gap audit

The audit source is the read-only archive of
[`neko-jpg/Team-D@44065d41e8906d34e5d8e11d7cd4cc14b25d17f2`](https://github.com/neko-jpg/Team-D/tree/44065d41e8906d34e5d8e11d7cd4cc14b25d17f2).
The machine-checked record is [backend-source-audit-v1.json](../contracts/backend-source-audit-v1.json).
It records facts at this SHA; it is not a deployment manifest and does not
make an unavailable surface available.

## Verified source evidence

`backend/app.py` exposes only `GET /api/health` and the router from
`backend/livekit_token.py`. The latter mints a short-lived token with camera
and data publish permissions and denies subscription. `backend/live_agent.py`
starts with explicit `SUBSCRIBE_NONE`, accepts only video camera tracks, uses
`VideoStream(..., capacity=1)`, and its processor has one in-flight inference.
`backend/providers/vision_guidance.py` and
`backend/guidance_state_machine.py` strictly constrain the finite Guidance
contract: guidance is lossy; shot state and resync are reliable; sequences are
positive and session scoped.

The production runtime pins FastAPI 0.116.1, LiveKit Python 1.1.15,
LiveKit Agents 1.7.1, LiveKit API 1.2.1, and Uvicorn 0.35.0 from
`requirements-backend.txt`. The task-required FastAPI/LiveKit pins therefore
remain explicit without omitting the production server pin.
`requirements-livekit-smoke.txt` pins Agents
1.3.12 for its smoke-only environment and must never replace the production
runtime pins.

The reference test evidence is limited to
`tests/test_livekit_token.py`, `tests/test_live_agent.py`, and
`tests/test_guidance_contract.py`. The recorded 2026-08-31 source-archive run
was `25 passed, 1 skipped`; the skipped browser-bundle artifact scan does not
prove a deployed Room or protected staging path. These reference tests were
not rerun during this Phase 1 document update.

## Availability and live boundary

The current default developer server is Node/Vite; the source README describes
the API as a loopback Node server. The Swift repository intentionally has only
`.example.invalid` public routing values and no staging credential. Therefore,
shared HTTPS FastAPI staging, token claim/Room-join/camera-subscribe smoke, and
all credentialed live evidence are blocked rather than inferred.

The source has no adapter from real image AI inference to LiveKit data/RPC
push, no explicit 1-2 fps sampling policy, and no app routes for
`/api/analyze-shot`, `/api/suggest-measurement-points`,
`/api/generate-background`, or `/api/remove-background`. Their owner,
frozen contract, dependent task, and objective release condition are in the
machine record. The v1 client descriptors remain unavailable for these routes;
no Swift FastAPI, Agent, mask, or background substitute has been added.

| Surface | Pinned-source classification | Needed by |
|---|---|---|
| `GET /api/health` | implemented in source; staging still unverified | protected staging preflight |
| `POST /api/livekit-token` | implemented in source; staging still unverified | T08-02 |
| camera-only subscribe, capacity 1, one inference | implemented transport core | T08-02 |
| finite Guidance contract/state machine | implemented contract core | T08-02 |
| shared HTTPS FastAPI staging integration | blocked; no deployment or credential evidence | T08-02 live smoke |
| real AI inference to LiveKit Guidance push | blocked; default inference remains no-op and no publisher is wired | T08-02 live acceptance |
| 1-2 fps Agent sampling policy | blocked; capacity/concurrency bounds do not establish a sampling rate | T08-02 and T18-02 |
| `POST /api/analyze-shot` | blocked; route absent | T09-02 live acceptance |
| `POST /api/suggest-measurement-points` | blocked; route absent | T12-02 live acceptance |
| `POST /api/generate-background` | blocked; route absent | T14-02 live acceptance |
| `POST /api/remove-background` | blocked; route absent | T14-01 live acceptance |

Every blocked row is owned by the `neko-jpg/Team-D` shared backend owner. Its
frozen v1 contract, `neededBy`, and objective `releaseCondition` are mandatory
fields in the machine record. An implemented-source classification is only a
source fact: it does not claim shared HTTPS deployment, credentialed live
operation, fixture verification, or final acceptance.

## Reproducible read-only verification

From a Python 3.11 environment, install the frozen archive's
`requirements-backend.txt`, add the archive root to `PYTHONPATH`, then run:

```sh
python -m pytest -q tests/test_livekit_token.py tests/test_live_agent.py tests/test_guidance_contract.py
```

Protected staging must run the separate
health/token-claim/Room-join/camera-subscribe check after credentials and a
shared HTTPS FastAPI deployment are supplied. The four absent endpoints require
their dependent task's protected v1 contract smoke after each one is deployed.

Under the current repository checkbox policy, the committed audit documents
and dedicated validation test code may be recorded as `[x]` with status
`code_ready_unverified` after one bounded source review reports `P0 none`.
That Phase 1 status does not mean the lint/test was executed, the reference
Python suite was rerun, fixture/live/staging passed, or T03-05 was accepted.
Those gates remain pending and must be recorded separately in Phase 2.
