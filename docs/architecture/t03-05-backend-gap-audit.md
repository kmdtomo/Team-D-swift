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

## Reproducible read-only verification

From a Python 3.11 environment, install the frozen archive's
`requirements-backend.txt`, add the archive root to `PYTHONPATH`, then run:

```sh
python -m pytest -q tests/test_livekit_token.py tests/test_live_agent.py tests/test_guidance_contract.py
```

The 2026-08-31 audit result was `25 passed, 1 skipped`; the skipped SDK probe
does not claim a Room or staging smoke. Protected staging must run the separate
health/token-claim/Room-join/camera-subscribe check after credentials and a
shared HTTPS FastAPI deployment are supplied. Until then T03-05 remains
unchecked.
