---
name: team-d-ios-product
description: "Interpret, refine, or review Team-D native iPhone product requirements, acceptance criteria, API contracts, fixtures, and backend boundaries. Use when a request changes or questions behavior or scope; do not use for implementation-only work that leaves requirements unchanged."
---

# Team-D iOS Product Requirements

Keep product behavior explicit, traceable, and independent of the Web implementation.

## Establish authority

1. Read the repository-root `requirements.md` completely.
2. Read the relevant `task.md` tasks and dependencies.
3. Inspect versioned contracts, fixtures, and backend availability when the question touches wire behavior.
4. Treat the source repository only as read-only evidence at the SHA recorded in the repository. Do not silently follow its moving `main`.

The user's latest explicit decision overrides documents. Otherwise, `requirements.md` defines what the product does, frozen wire contracts define payload shape, and `task.md` defines implementation order. Surface a conflict rather than choosing silently.

## Classify the request

Distinguish:

- clarification: wording changes without observable behavior change;
- contract repair: resolving a documented schema or fixture inconsistency;
- requirement change: any change to user-visible flow, accepted data, privacy, persistence, accuracy, fallback, or approval;
- implementation choice: a Swift technique that preserves requirements.

Do not treat an implementation preference as a product requirement. Do not change a requirement merely to match existing code or an unavailable backend.

## Preserve the fixed product contract

Unless the user explicitly changes it, preserve:

- the four-shot order `front -> back -> tag -> measurement`;
- manual capture outside `READY`;
- app-owned finite state transitions instead of AI prose;
- explicit measurement endpoint correction and approval;
- the four-images-plus-approved-measurement edit gate;
- text-only background generation input;
- garment RGB provenance from the original `front` image only;
- session-only intermediate data and explicit final export;
- visible separation of fixture and live failures;
- shared Python/LiveKit/rembg backend rather than a Swift port;
- fixed 2D AVFoundation guides without ARKit or automatic capture.

## Change requirements safely

Treat a requirement change as authorized only when the user gives a current, explicit direction whose observable outcome is sufficiently defined. A wish, question, exploration, or ambiguous request is not final approval. If choices such as removed steps, approval timing, persistence, payload compatibility, or migration materially change the result, present the conflict and obtain the missing decision before editing authoritative requirements.

When a requirement change is authorized and unambiguous:

1. State the previous behavior, proposed behavior, reason, and affected acceptance IDs.
2. Identify effects on domain types, API schemas, fixture/golden data, privacy, accessibility, backend ownership, tests, and physical-device evidence.
3. Update `requirements.md` first with stable IDs and testable language.
4. Update affected `task.md` implementation targets, dependencies, completion criteria, fixture/live mode, and device gates in the same change.
5. Update or add contract/fixture tests when artifacts exist. Never weaken a test just to make the current implementation pass.
6. Record unresolved external dependencies without creating a substitute backend in this repository.

Do not add OpenSpec. Do not copy source requirements or React skill files wholesale. Keep source links as provenance and translate only platform-independent product decisions.

## Contract discipline

- Use finite enums and strict payloads; reject unknown required keys and invalid normalized coordinates.
- Keep `ShotAssessment` limited to `front/back/tag`; measurement acceptance has a separate contract.
- Keep measurement-point responses to four normalized points with no confidence or centimeter values.
- Use positive Guidance sequence values because the implemented Python wire starts at 1; retain the TypeScript `0` discrepancy as an explicit source issue until repaired.
- Treat fixture and live as separate acceptance paths. A fixture contract can unblock client work but cannot declare a live dependency complete.

## Review output

For a requirements review, report only material gaps or contradictions. For each finding, cite the requirement/acceptance ID, affected task IDs, observable risk, and smallest safe correction. Do not implement code unless the user also asked for implementation.
