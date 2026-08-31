# Optional local backend and rembg

## Optional boundary

**OPTIONAL:** this procedure is not required for fixture onboarding and is not
the supported shared-live route. It exists only to isolate backend, Agent, and
rembg behavior. It never turns a local or fixture result into shared-live
evidence.

Use the pinned `neko-jpg/Team-D` source as read-only input. Do not edit, branch,
commit, or push that repository. Export its files to a disposable directory;
do not copy Python backend, Agent, Web, OpenSpec, or rembg code into this Swift
repository.

At snapshot `44065d41e8906d34e5d8e11d7cd4cc14b25d17f2`, FastAPI exposes only health
and token. Agent inference defaults to a no-op, guidance push and explicit
1--2 fps sampling are missing, and the four provider endpoints are missing.
The local commands below cannot run an end-to-end product flow.

## Export the read-only source

Point `SOURCE_CHECKOUT` at an existing read-only clone and export the exact
snapshot without changing its checkout:

```sh
export SOURCE_CHECKOUT='/absolute/path/to/read-only/Team-D'
export SOURCE_EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/teamd-backend-export.XXXXXX")"
git -C "$SOURCE_CHECKOUT" archive \
  44065d41e8906d34e5d8e11d7cd4cc14b25d17f2 | tar -x -C "$SOURCE_EXPORT"
test "$(git -C "$SOURCE_CHECKOUT" rev-parse 44065d41e8906d34e5d8e11d7cd4cc14b25d17f2)" = \
  44065d41e8906d34e5d8e11d7cd4cc14b25d17f2
cd "$SOURCE_EXPORT"
```

Keep all environments, model caches, request inputs, and outputs inside this
disposable export. The production backend lock is `requirements-backend.txt`;
`requirements-livekit-smoke.txt` is smoke-only and must not replace it.

## Optional FastAPI

Python 3.11 or later is required:

```sh
python3.11 -m venv .venv-backend
.venv-backend/bin/python -m pip install -r requirements-backend.txt
.venv-backend/bin/python -m uvicorn backend.app:app \
  --host 127.0.0.1 --port 8000
```

In another terminal, health requires no credential:

```sh
curl --fail --silent --show-error --max-time 5 \
  http://127.0.0.1:8000/api/health
```

The exact expected payload is `{"status":"ok"}`. The token route returns 503
until the backend process receives its server-only LiveKit configuration from
an approved local secret manager. This runbook deliberately provides no
credential assignment. Do not route an iPhone to loopback and do not place
server credentials or tokens in the Swift app, scheme, xcconfig, log, or
repository.

The pinned FastAPI app does not expose analyze-shot, measurement-point,
generate-background, or remove-background. A 404 from those paths is expected
snapshot evidence, not a reason to invent a substitute handler.

## Optional Agent

Only after server-only LiveKit configuration has been injected outside the
repository, start the pinned worker from the disposable export:

```sh
.venv-backend/bin/python -m backend.live_agent dev
```

This verifies worker startup and camera-only transport behavior at most. The
pinned default inference is a no-op and does not publish usable guidance. Do
not claim Agent push, 1--2 fps sampling, Room smoke, or live acceptance from
process startup.

## Optional rembg

This sidecar check is isolated from the iPhone and FastAPI snapshot. It does
not make `/api/remove-background` available:

```sh
python3.11 -m venv .venv-rembg
.venv-rembg/bin/python -m pip install -r requirements-rembg.txt
export REMBG_HOME="$SOURCE_EXPORT/.cache/rembg"
.venv-rembg/bin/rembg d birefnet-general-lite
export LOCAL_REMBG_PORT=7000
.venv-rembg/bin/rembg s --host 127.0.0.1 \
  --port "$LOCAL_REMBG_PORT" --log_level warning --threads 1 --no-ui
```

In another terminal in the same disposable export, prewarm with the audited
fixture and write output only under the disposable directory:

```sh
mkdir -p "$SOURCE_EXPORT/tmp/rembg-prewarm"
curl --fail --silent --show-error --max-time 120 \
  -X POST "http://127.0.0.1:${LOCAL_REMBG_PORT}/api/remove" \
  -F 'file=@fixtures/garment/front.png;type=image/png' \
  -F 'model=birefnet-general-lite' -F 'om=true' \
  -o "$SOURCE_EXPORT/tmp/rembg-prewarm/mask.png"
file "$SOURCE_EXPORT/tmp/rembg-prewarm/mask.png"
```

The loopback address and port belong only to this disposable backend shell.
Never assign them to `TEAM_D_BACKEND_BASE_URL`, expose them to the LAN, or put
them in app configuration/evidence. Sidecar success does not prove same-size
mask validation, FastAPI wiring, or iPhone integration.

## Stop and clean up

Stop Uvicorn, Agent, and rembg with Ctrl-C. Confirm no other process uses the
disposable export, verify `SOURCE_EXPORT` is the directory created above, then
delete that export using the operator's normal recoverable cleanup procedure.
Do not delete or modify `SOURCE_CHECKOUT`. Do not preserve request images,
masks, tokens, terminal transcripts, or model caches as repository artifacts.
