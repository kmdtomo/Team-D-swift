# T03-01 Contract provenance

The Swift wire contract is fixed from the repository requirements and task plan
against source snapshot `44065d41e8906d34e5d8e11d7cd4cc14b25d17f2`.

## Sequence compatibility decision

The source TypeScript schema permits `GuidanceEvent.sequence = 0`, while the
implemented Python backend requires `sequence >= 1`. Swift rejects zero and
uses the Python behavior, because it is the current live wire and preserves a
positive monotonic sequence invariant. This is a compatibility decision, not a
claim that the TypeScript schema has been changed; source owners must reconcile
the discrepancy before a future schema revision changes this contract.

## Source evidence and status

Evidence was read only from `neko-jpg/Team-D@44065d41e8906d34e5d8e11d7cd4cc14b25d17f2`:
`backend/guidance_state_machine.py`, `backend/livekit_token.py`,
`tests/test_guidance_contract.py`, `tests/test_livekit_token.py`,
`app/src/shared/guidanceSchemas.ts`, `app/src/shared/captureSchemas.ts`, and
`app/src/shared/measurementSchemas.ts`. Python's live implementation starts
sequences at 1; TypeScript's client schema still accepts 0. This is recorded
as source compatibility, not an invented endpoint or T03-02 API surface.

## Codec boundary

ContractKit owns the concrete wire DTOs, including points, lines, markers,
measurement drafts, token payloads, and capture/guidance payloads. DomainKit
owns only shared finite vocabulary and app composition dependencies; this
avoids retroactive `Codable` conformances across module boundaries.

Every decoded JSON object uses a dynamic-key preflight before decoding its
declared fields, including nested points, lines, markers, and measurement
drafts. This deliberately avoids relying on `Codable`'s default treatment of
unknown JSON keys. UI code must derive localized guidance from finite codes and
must not use wire `message`, confidence, or assessment `nextAction` as an
acceptance or navigation decision.
