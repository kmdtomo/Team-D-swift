# T03-02 HTTP v1 contract

`Contracts/HTTP/v1/openapi.json` is the versioned HTTP contract authority. Its
availability companion is pinned to source snapshot
`44065d41e8906d34e5d8e11d7cd4cc14b25d17f2`.

## Source status

`backend/app.py:10-22` implements only `GET /api/health` and registers the
token router. `backend/livekit_token.py:43-63,292-330` implements strict token
request/response handling. The source test asserts health `200` JSON at
`tests/test_livekit_token.py:231-239`; token `200` JSON and expiry equality at
`:254-268`; token TTL default/cap at `:271-308`.

The four planned HTTP paths are deliberately marked unavailable. Agent guidance
push is also unavailable: `backend/live_agent.py:839-846` uses a no-op default
inference callback, while `backend/guidance_state_machine.py:115-168` defines
payload semantics without a LiveKit data-packet/RPC publisher.

## Retry and error boundary

The source token route retains its native FastAPI `422` detail and its `503`
`{"detail":"livekit_unavailable"}`; it is not converted into `ProviderError`.
It has no idempotency header and no automatic retry; a user-requested retry
receives a newly minted identity.

The planned four paths require a stable `Idempotency-Key` per operation. Their
`ProviderError` retryability is false for invalid input, schema, and unsupported
content type; true for rate limit, upstream 502/503/504, and transport timeout.
Automatic retry belongs to later client tasks.

Health permits safe caller retry; token permits only an explicit retry that
receives a new identity. Planned endpoints permit callers to retry documented
transient failures (429, 502, 503, 504, and transport timeout); invalid input,
schema, and content-type failures are not retryable. Image multipart parts
accept only JPEG, PNG, or HEIC; analyze also fixes `requestedShot` as text/plain.

## Deliberately deferred decisions

T14-02 owns the permitted `styleId` allowlist. Backend owners must implement
and smoke every unavailable path before it becomes available. The contract does
not define an analyze-live endpoint.
