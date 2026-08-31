---
name: team-d-ios-delivery
description: "Implement, refactor, test, review, or advance tasks in Team-D's native Swift/SwiftUI iPhone repository. Use for selecting task.md work, respecting dependencies and lanes, running fixture/live and device gates, and recording completion; do not use to change product requirements or implement the shared backend."
---

# Team-D iOS Delivery

Advance the Swift client in small, verifiable task units without confusing partial, fixture, live, Simulator, and physical-device completion.

## Start a work unit

1. Read root `AGENTS.md`, `requirements.md`, and the relevant `task.md` section.
2. Name the task ID, lane, dependencies, implementation target, required test mode, and device gate. Record the upstream artifact/version being used, owned files, the single final authoritative verification command, and any integration, live, device, or acceptance gates intentionally left open.
3. Classify each predecessor as a start, integration, or acceptance dependency. An unchecked predecessor is not itself a start blocker: continue separable work when the required contract, protocol, finite type, fixture, golden payload, fake, expected image, or approved technical decision is stable. Run the T11 Apple-framework measurement M0 early, while keeping its physical-corpus evidence mandatory for the adoption decision.
4. Inspect the current worktree and preserve user or parallel-agent changes.
5. Identify the smallest production change and its focused automated evidence before editing.

If the request would change user-visible behavior, API semantics, persistence, privacy, fallback, accuracy, or approval, use the product-requirements skill first. If an external backend contract is missing, continue only the explicitly separable fixture/client work and leave live completion blocked.

Block the start of dependent implementation only for a concrete missing artifact or decision: unresolved wire or product meaning, unavailable shared protocol/schema, an active owner on the same file, or an unapproved irreversible technology gate. Device, credential, shared-backend, and live-environment availability normally block integration or acceptance, not fixture/mock implementation.

## Respect independent AI task boundaries

Treat every other Codex task, thread, chat, or session as an autonomous user-owned workflow, not as a child agent of the current task. This applies even when it uses the same repository, checkout, branch, task list, or product goal.

- Use read-only Git/worktree status and task inspection only as needed to identify active ownership and avoid collisions. Do not treat another task's title, summary, plan, or progress as authorization to manage it.
- Do not send another task instructions, status requests, stop requests, scope restrictions, priority changes, handoff conditions, or follow-up prompts. Do not wait on, interrupt, archive, hand off, or repurpose another task on the current task's initiative.
- Manage only subagents spawned inside the current task. A peer Codex task remains independent even if its work would help the current task.
- If another task owns or is editing the same files, shared project settings, branch, or worktree, change the current task's lane, use a separate worktree, choose a non-overlapping task, or report the conflict to the current user. Never resolve the conflict by directing the other task.
- Cross-task communication or control is allowed only when the user explicitly requests it in the current task and identifies the intended coordination. Do not infer that permission from a general request to accelerate, parallelize, monitor, finish, or use subagents.
- Integrate only committed artifacts that are ready under the repository's normal review rules. Do not ask another task to commit, stop, reorder, or prepare a handoff for this task.

## Implement within the lane

- Keep one task ID and one lane per change when practical.
- Define or agree on protocols, finite types, coordinates, and fixtures before multiple lanes implement against them.
- Let lane A own `project.pbxproj`, shared schemes, package locks, root navigation, and contract schemas. Avoid broad generated-file churn.
- Use explicit enum state and validated events. Isolate side effects behind injected protocols and keep concurrency cancellation/stale-result rules observable in tests.
- Keep AVFoundation under one session owner. Keep local analysis and LiveKit publication bounded and derived from that capture pipeline.
- Do not add Swift versions of missing FastAPI/Agent/rembg responsibilities, hidden fixture fallbacks, placeholder success, or production secrets.
- Add the relevant test in the same change instead of postponing all testing to T17.

## Verify in layers

Select the least expensive meaningful layer for the task, then broaden only at the integration cadence:

1. Swift Testing/XCTest for domain state, codecs, geometry, image math, cancellation, and failure behavior.
2. Contract/golden tests for API and fixture changes.
3. Integration tests for provider composition and session cleanup.
4. XCUITest for user-visible flow, recovery, and approval.
5. Physical-device checks required by the task.

Write focused tests during implementation without running a successful build after every small edit, subcommit, or review comment. When the task's code and focused tests are complete, the task owner runs one authoritative verification command against the final candidate SHA. That one invocation includes the affected target build and focused tests; if multiple task-required configurations exist, run them sequentially inside the same invocation.

If the authoritative run fails, rerun only after changing the responsible code, configuration, or test. Record the successful candidate SHA, resolved dependencies, Xcode/Swift version, command, and result. Parent and review agents inspect the diff and this evidence; they do not rerun the same SHA in another scratch path. Rerun only when the SHA, dependency resolution, shared project setting, contract, or test changed, evidence is missing/corrupt, or a concrete reproducibility concern is recorded.

Run affected package/app suites and the app integration build once per integration wave, full XCUITest at runnable vertical slices or T17/T19, and clean-clone, long performance, device-matrix, and live end-to-end checks at their named milestones. Heavy commands (`xcodebuild`, full-package `swift test`, clean builds, XCUITest) are repository-wide single-flight. Each task owns and reuses one scratch/DerivedData path and removes regenerable scratch after recording its authoritative result.

Fixture and live are independent results. A fake camera or mock Room cannot satisfy physical capture or live publish. A Simulator pass cannot satisfy camera, orientation, interruption, thermal, measurement accuracy, VoiceOver camera operation, or export gates.

For live failures, verify that the app remains in live mode, displays the failure, preserves progress, and never invokes fixture providers. For asynchronous work, verify old session/shot/sequence/request results cannot mutate current state.

## Complete or block honestly

Use `planned`, `in_progress`, `implementation_ready`, `integration_ready`, `accepted`, and `blocked` to distinguish progress. Leave a task unchecked in every state except `accepted`; unchecked status does not prevent downstream separable work.

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

Keep audits bounded so review does not become an endless implementation loop:

- Classify every actionable audit finding as `P0`, `P1`, `P2`, or `P3`. Only `P0` blocks the current task, integration wave, or acceptance.
- Use `P0` only for a concrete, evidenced defect that makes an explicit completion condition false, fails a required build/test, violates a fixed product/security/privacy/data-lifetime/pixel-provenance invariant, risks data loss or a primary-flow crash, or makes the artifact unsafe to integrate. Do not promote preferences, speculative edge cases, cleanup ideas, or optional hardening to `P0`.
- Treat `P1` through `P3` as separate small follow-up issues. Record them concisely when useful, but skip fixing them in the current task. They must not trigger another implementation pass, another build, a new subagent, a task reopen, or another audit cycle.
- Do not add a new `task.md` item for a non-`P0` finding unless the user explicitly asks to schedule it. A short backlog or handoff note is sufficient.
- After one review pass, if there is no `P0` and the task's already-defined verification and acceptance gates pass, finish the task. Re-review only the diff that fixes a `P0` or when the candidate SHA materially changes.
- If a finding violates a mandatory completion condition, it is not a skippable `P1` through `P3`; classify it as `P0` and name the exact violated condition.

Before handoff, run formatting/lint only where configured, inspect the diff for unrelated changes and secrets, state what passed and what remains unverified, and do not push unless the user requested it.
