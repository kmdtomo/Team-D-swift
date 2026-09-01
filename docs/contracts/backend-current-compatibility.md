# Current backend compatibility for T08-02 and T09-01

This is a scoped compatibility record for the Swift tasks T08-02 and T09-01.
It does not replace the historical HTTP v1 contract or silently redefine
unrelated endpoints.

## Read-only inspection

- Repository: `https://github.com/neko-jpg/Team-D`
- Remote default branch: `main`
- Inspected commit: `a25a8542664b4bd3bfe3ff00171ea56cd373966c`
- Retrieved: `2026-08-31T16:48:22Z` (`2026-09-01T01:48:22+09:00`)
- Access: read-only shallow clone; no source-repository mutation
- Session-identity reinspection: the same remote `main` commit was retrieved
  read-only at `2026-09-01T00:30:29Z`
  (`2026-09-01T09:30:29+09:00`); no backend source was changed

## T08-02 guidance transport

The current backend implements camera-only subscription, bounded latest-frame
processing, provider inference, and LiveKit data publication. Its
`GuidanceTransportAdapter` calls `publish_data(payload, reliable: Bool)` without
a topic. LiveKit Swift 2.16.0 exposes payload and topic to `RoomDelegate`, but
not the reliability flag.

The Swift adapter therefore keeps its explicit versioned topics and adds one
audited compatibility path for an empty topic. It routes only the exact closed
top-level shape of `GuidanceEvent` to the lossy stream and the exact closed
shape of `GuidanceStateEvent` to the opaque reliable stream. Unknown shapes are
dropped. Reliable bytes remain non-navigating and non-accepting until T08-03
owns their state schema and synchronization behavior.

The token route derives `roomName` as
`listing-photo-session-<app sessionId>`, while the current Agent constructs its
guidance state machine with that Room name as `GuidanceEvent.sessionId`. The
frozen app contract still owns the original app session ID. Swift therefore
normalizes only an event session that exactly equals the active token
response's `roomName` back to the current app session before applying the
existing session, shot, sequence, and expiry filter. It does not accept an
arbitrary prefixed session, and a previous token's Room name is invalidated on
leave, failure, and reconnect.

## T09-01 shot assessment

The current backend implements `POST /api/analyze-shot` with:

- `requestedShot` as a form field restricted to `front`, `back`, or `tag`;
- the binary multipart field named `file`;
- a 20-second provider timeout;
- strict `ShotAssessment` success JSON;
- provider errors wrapped as `{"detail": ProviderError}`;
- upload limits of 10 MiB and JPEG, PNG, or WebP at this inspected commit.

The historical Swift v1 fixture remains available through
`ShotAssessmentWireContract.frozenSwiftV1`. Live composition explicitly selects
`upstreamA25A854`, which changes only the binary field name and error envelope.
It still sends the original high-resolution bytes, retains the stable
idempotency key, strictly decodes finite outcomes, and makes HEIC rejection a
visible provider failure rather than re-encoding or substituting fixture data.

## Remaining gates

Source compatibility does not prove protected live success. Shared backend and
LiveKit credentials, live provider configuration, iPhone camera publish and
Agent subscription/push, three-shot assessment behavior, latency, thermal and
memory evidence, and physical-device recovery remain separate gates.
