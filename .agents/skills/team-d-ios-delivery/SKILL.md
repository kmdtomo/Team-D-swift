---
name: team-d-ios-delivery
description: "Implement, refactor, test, review, or advance tasks in Team-D's native Swift/SwiftUI iPhone repository. Use for selecting task.md work, respecting dependencies and lanes, running fixture/live and device gates, and recording completion; do not use to change product requirements or implement the shared backend."
---

# Team-D iOS Delivery

Advance the Swift client in small, verifiable task units without confusing partial, fixture, live, Simulator, and physical-device completion.

## Start a work unit

1. Read root `AGENTS.md`, `requirements.md`, and the relevant `task.md` section.
2. Name the task ID, lane, dependencies, implementation target, required test mode, and device gate.
3. Confirm every predecessor marked in the task is actually complete. Chapter order is not execution order; run the T11 Apple-framework measurement M0 immediately after its stated prerequisites.
4. Inspect the current worktree and preserve user or parallel-agent changes.
5. Identify the smallest production change and its focused automated evidence before editing.

If the request would change user-visible behavior, API semantics, persistence, privacy, fallback, accuracy, or approval, use the product-requirements skill first. If an external backend contract is missing, continue only the explicitly separable fixture/client work and leave live completion blocked.

## Implement within the lane

- Keep one task ID and one lane per change when practical.
- Define or agree on protocols, finite types, coordinates, and fixtures before multiple lanes implement against them.
- Let lane A own `project.pbxproj`, shared schemes, package locks, root navigation, and contract schemas. Avoid broad generated-file churn.
- Use explicit enum state and validated events. Isolate side effects behind injected protocols and keep concurrency cancellation/stale-result rules observable in tests.
- Keep AVFoundation under one session owner. Keep local analysis and LiveKit publication bounded and derived from that capture pipeline.
- Do not add Swift versions of missing FastAPI/Agent/rembg responsibilities, hidden fixture fallbacks, placeholder success, or production secrets.
- Add the relevant test in the same change instead of postponing all testing to T17.

## Verify in layers

Run the least expensive meaningful layer first, then broaden according to risk:

1. Swift Testing/XCTest for domain state, codecs, geometry, image math, cancellation, and failure behavior.
2. Contract/golden tests for API and fixture changes.
3. Integration tests for provider composition and session cleanup.
4. XCUITest for user-visible flow, recovery, and approval.
5. Physical-device checks required by the task.

Fixture and live are independent results. A fake camera or mock Room cannot satisfy physical capture or live publish. A Simulator pass cannot satisfy camera, orientation, interruption, thermal, measurement accuracy, VoiceOver camera operation, or export gates.

For live failures, verify that the app remains in live mode, displays the failure, preserves progress, and never invokes fixture providers. For asynchronous work, verify old session/shot/sequence/request results cannot mutate current state.

## Complete or block honestly

Leave a task unchecked when it is partial, in progress, blocked, fixture-only where live is required, Simulator-only where a device is required, or missing any listed completion criterion.

Mark `[x]` only after all of the task's completion conditions, automated tests, fixture/live checks, and device checks pass. Record evidence beneath the task in this form:

```markdown
- Verification (YYYY-MM-DD):
  - commit/build: `<SHA or build>`
  - automated tests: `<command and result>`
  - fixture: `<configuration / command / result / artifact>` or `not required`
  - live: `<configuration / backend SHA or version / command / result / artifact>` or `not required`
  - device: `<model / iOS / checked items / runbook or artifact>` or `not required`
  - limitations: `none` or a concise remaining limitation
```

If blocked, keep `[ ]` and record the reason, owner, and objective release condition. Do not lower acceptance criteria, invent evidence, or check a Swift task because the Web source implemented similar behavior.

## Review a change

Review against the task's exact completion criteria and product acceptance IDs. Prioritize state-safety, privacy, pixel provenance, contract strictness, cancellation, recovery, accessibility, and missing device/live evidence. Do not report generic style preferences as blockers.

Before handoff, run formatting/lint only where configured, inspect the diff for unrelated changes and secrets, state what passed and what remains unverified, and do not push unless the user requested it.
