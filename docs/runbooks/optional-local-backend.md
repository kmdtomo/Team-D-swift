# Optional local backend and rembg

## Optional boundary

**OPTIONAL:** this procedure is not required for fixture onboarding and is not
the supported shared-live route. It exists only to isolate backend, Agent, and
rembg behavior. It never turns a local or fixture result into shared-live
evidence.

Use the current remote default branch of `neko-jpg/Team-D` as read-only input.
Fetch before each backend diagnosis and record the exact exported commit and
retrieval time. Do not edit, branch, commit, or push that repository. Export
its files to a disposable directory; do not copy Python backend, Agent, Web,
OpenSpec, or rembg code into this Swift repository.

The v1 audit at `44065d41e8906d34e5d8e11d7cd4cc14b25d17f2` is historical evidence only.
At that commit FastAPI exposed health and token while Agent guidance push,
explicit 1--2 fps sampling, and the four provider endpoints were missing.
Do not assume those availability facts are current; inspect the exported
commit before deciding which local slices can run end to end.

## Export the read-only source

Point `SOURCE_CHECKOUT` at an existing clone, refresh its remote refs without
changing its checkout, resolve the remote default branch, and export that
exact commit:

```sh
export SOURCE_CHECKOUT='/absolute/path/to/read-only/Team-D'
export SOURCE_EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/teamd-backend-export.XXXXXX")"
git -C "$SOURCE_CHECKOUT" fetch --prune origin
git -C "$SOURCE_CHECKOUT" remote set-head origin --auto
export SOURCE_DEFAULT_REF="$(git -C "$SOURCE_CHECKOUT" symbolic-ref --quiet refs/remotes/origin/HEAD)"
export SOURCE_COMMIT="$(git -C "$SOURCE_CHECKOUT" rev-parse "${SOURCE_DEFAULT_REF}^{commit}")"
export SOURCE_RETRIEVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
test -n "$SOURCE_DEFAULT_REF"
test -n "$SOURCE_COMMIT"
git -C "$SOURCE_CHECKOUT" archive "$SOURCE_COMMIT" | tar -x -C "$SOURCE_EXPORT"
printf 'Backend source: %s at %s\n' "$SOURCE_COMMIT" "$SOURCE_RETRIEVED_AT"
cd "$SOURCE_EXPORT"
```

Copy the printed commit and retrieval time into the diagnosis evidence. Do not
store the disposable export, credentials, tokens, or request images as
evidence.

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

For a backend release that retains the current v1 health contract, the exact
expected payload is `{"status":"ok"}`. The token route can return 503 until
the backend process receives its server-only LiveKit configuration from an
approved local secret manager. This runbook deliberately provides no
credential assignment. Do not route an iPhone to loopback and do not place
server credentials or tokens in the Swift app, scheme, xcconfig, log, or
repository.

Compare the exported routes and payloads with the versioned Swift contract.
A newly available or changed route is contract drift to record and synchronize,
not permission to bypass strict client decoding. A still-missing route is an
external live blocker, not a reason to invent a substitute handler.

## Optional Agent

Only after server-only LiveKit configuration has been injected outside the
repository, start the exported worker from the disposable directory:

```sh
.venv-backend/bin/python -m backend.live_agent dev
```

Process startup alone does not prove usable guidance, 1--2 fps sampling, Room
smoke, or live acceptance. Verify those behaviors separately at the recorded
backend commit.

## Optional rembg

This sidecar check is isolated from the iPhone and exported FastAPI source. It does
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
