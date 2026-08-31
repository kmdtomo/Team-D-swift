---
name: team-d-ios-delivery
description: "Implement, refactor, test, review, or advance tasks in Team-D's native Swift/SwiftUI iPhone repository. Use for selecting task.md work, respecting dependencies and lanes, running fixture/live and device gates, and recording completion; do not use to change product requirements or implement the shared backend."
---

# Team-D iOS Delivery

Advance the Swift client in small, verifiable task units without confusing partial, fixture, live, Simulator, and physical-device completion.

## Start a work unit

1. Read root `AGENTS.md`, `requirements.md`, and the relevant `task.md` section.
2. Name the task ID, lane, dependencies, implementation target, required test mode, and device gate. Record the upstream artifact/version being used, owned files, tests to author for deferred verification, and any integration, live, device, or acceptance gates intentionally left open.
3. Classify each predecessor as a start, integration, or acceptance dependency. An unchecked predecessor is not itself a start blocker: continue separable work when the required contract, protocol, finite type, fixture, golden payload, fake, expected image, or approved technical decision is stable. Run the T11 Apple-framework measurement M0 early, while keeping its physical-corpus evidence mandatory for the adoption decision.
4. Inspect the current worktree and preserve user or parallel-agent changes.
5. Identify the smallest production change and its focused automated evidence before editing.

If the request would change user-visible behavior, API semantics, persistence, privacy, fallback, accuracy, or approval, use the product-requirements skill first. If an external backend contract is missing, continue only the explicitly separable fixture/client work and leave live completion blocked.

Block the start of dependent implementation only for a concrete missing artifact or decision: unresolved wire or product meaning, unavailable shared protocol/schema, an active owner on the same file, or an unapproved irreversible technology gate. Device, credential, shared-backend, and live-environment availability normally block integration or acceptance, not fixture/mock implementation.

## Freeze the assignment boundary

The task IDs, lane, files, and deliverables explicitly named in the initial user request or subagent assignment are the worker's complete and immutable scope for that work unit.

- Record the exact assignment boundary before editing. `task.md`, unchecked tasks, dependencies, available worker slots, nearby code, and discovered follow-up work are context, not authorization to expand the boundary.
- A request to implement one task, one slice, or an enumerated set ends when that exact production scope and its required test code are committed and reported with implementation-review data. If the worker owns `task.md`, it also source-reviews, checks, records, and commits the assigned task block before ending. Do not select the next task, continue down the checklist, refill the worker with another task, or interpret “make progress,” “parallelize,” or “finish your assignment” as permission to widen it.
- A parent may dispatch only task IDs that were explicitly included in the parent's own initial assignment. Each child receives a bounded assignment and terminates after returning its candidate commit; do not reuse the completed child with `followup_task` for a new task.
- If the initial request explicitly assigns the entire `task.md`, the whole file is in scope. Otherwise never infer repository-wide completion from access to the file or from a parent role.
- New work requires a new explicit user instruction or a new parent assignment that is already inside the parent's fixed initial boundary. Record out-of-scope dependencies and follow-ups, then stop instead of implementing them.
- The parent ends its turn after every task in its initial boundary has been committed and recorded as `code_ready_unverified`, or objectively blocked, and all already-running children in that boundary have reported. A code commit without the owned `task.md` implementation record is not the parent's completion trigger. Do not automatically begin final verification unless it was also part of the initial assignment.

## Respect independent AI task boundaries

Treat every other Codex task, thread, chat, or session as an autonomous user-owned workflow, not as a child agent of the current task. This applies even when it uses the same repository, checkout, branch, task list, or product goal.

- Use read-only Git/worktree status and task inspection only as needed to identify active ownership and avoid collisions. Do not treat another task's title, summary, plan, or progress as authorization to manage it.
- Do not send another task instructions, status requests, stop requests, scope restrictions, priority changes, handoff conditions, or follow-up prompts. Do not wait on, interrupt, archive, hand off, or repurpose another task on the current task's initiative.
- Manage only subagents spawned inside the current task. A peer Codex task remains independent even if its work would help the current task.
- If another task owns or is editing the same files, shared project settings, branch, or worktree, change the current task's lane, use a separate worktree, choose a non-overlapping task, or report the conflict to the current user. Never resolve the conflict by directing the other task.
- Cross-task communication or control is allowed only when the user explicitly requests it in the current task and identifies the intended coordination. Do not infer that permission from a general request to accelerate, parallelize, monitor, finish, or use subagents.
- Integrate only committed artifacts that are ready under the repository's normal review rules. Do not ask another task to commit, stop, reorder, or prepare a handoff for this task.

## Use one parent with direct implementation subagents

When the user asks this task to use subagents or parallelize delivery, use a shallow topology inside the current task:

- Default to one parent and up to three direct implementation subagents when four concurrency slots are available. Use fewer children when fewer conflict-free work units exist; an idle slot is cheaper than file conflicts or duplicate work.
- Do not let children spawn grandchildren. Do not create or manage peer Codex tasks as a substitute for child agents. Parallel workers for this plan must be descendants of the current parent only.
- Prefer `gpt-5.6-sol` with `high` reasoning for the parent when model choice is available; reserve `xhigh` for genuinely difficult architecture, integration, or `P0` decisions. Prefer `gpt-5.6-terra` with `medium` reasoning for implementation children. Preserve an explicit user model choice over these defaults.
- The parent owns task selection, dependency/artifact checks, lane and file ownership, shared contracts, `project.pbxproj` and scheme/package integration, candidate integration, final verification dispatch, verification evidence, and `task.md` updates.
- Each child receives exactly one task ID and lane at a time, an upstream commit, an exclusive file set, a dedicated branch/worktree, tests to author, and the required fixture/live/device gates. The child normally returns one or two meaningful commits, using a third only when separation is necessary.
- Children must not edit `task.md`, shared project files, package locks, shared schemas, or root navigation unless the parent explicitly assigns that ownership. They return the candidate SHA, changed files, tests authored but not run, and remaining integration/live/device gates.
- During the implementation phase, children do not run `swift build`, `swift test`, `xcodebuild`, XCUITest, app launch, clean build, or any command that compiles or links the product. They may run source-only formatting, schema/document lint, `git diff --check`, and secret/static scans that create no build artifacts.
- During Phase 1, do not reserve a child as a standing reviewer. The parent checks ownership, scope, and obvious `P0` risks only; defer the full integrated review to the Phase 2 verification owner. `P1` through `P3` do not consume another child pass.
- When a child returns the full candidate, test code, and implementation-review data, end that child work unit. Do not reuse it for another task. The parent performs the single bounded source review and serial `task.md` update. Device, live, credential, physical-corpus, and acceptance gates remain recorded without extending the assignment.
- Integrate candidate commits without running builds only when integration is inside the parent's fixed assignment. After every task in that boundary is committed or blocked, stop; begin the dedicated final verification phase only under a separate explicit assignment or when the initial request included it.
- In final verification, assign one direct child as the exclusive verification-and-fix owner of one clean integrated worktree. Prefer `gpt-5.6-sol` with `high` reasoning when available. Other children must not write to that worktree; they may perform bounded read-only diagnosis only when the verification owner requests a specific failure analysis.

## Implement within the lane

- Keep one task ID and one lane per change when practical.
- Define or agree on protocols, finite types, coordinates, and fixtures before multiple lanes implement against them.
- Let lane A own `project.pbxproj`, shared schemes, package locks, root navigation, and contract schemas. Avoid broad generated-file churn.
- Use explicit enum state and validated events. Isolate side effects behind injected protocols and keep concurrency cancellation/stale-result rules observable in tests.
- Keep AVFoundation under one session owner. Keep local analysis and LiveKit publication bounded and derived from that capture pipeline.
- Do not add Swift versions of missing FastAPI/Agent/rembg responsibilities, hidden fixture fallbacks, placeholder success, or production secrets.
- Add the relevant test in the same change instead of postponing all testing to T17.

## Separate implementation from final verification

Use two explicit phases.

### Phase 1: implementation sweep

- Implement production code and author the focused Swift Testing/XCTest, contract, fixture, integration, and XCUITest coverage named by each task, but do not run commands that compile, link, launch, or test the product.
- Require corresponding test code whenever the task has automatable behavior. For genuinely docs-only or physical-only work, record `tests authored: not applicable` and the reason; do not add empty or always-passing tests for checkbox credit.
- After the full task scope and tests are committed, perform one bounded source review. If there is no P0, mark `[x]`, record `code_ready_unverified`, the commits, production scope, tests authored, `P0 none`, deferred execution, and all pending gates. This is implementation evidence only, not evidence that the code builds or works.
- Integrate committed candidates so later tasks can build on stable source artifacts. Resolve textual merge conflicts and shared-file ownership centrally, but defer compiler, linker, test, Simulator, and app-runtime feedback.
- Do not create task-specific `.build`, scratch, DerivedData, clean clones, Simulator clones, or test-result bundles during this phase. Do not delete unrelated existing artifacts.

### Phase 2: dedicated final verification and repair

- Begin after all locally implementable tasks are `code_ready_unverified` and every genuinely blocked task has a concrete external/device/contract release condition.
- Use one clean integrated worktree and one reusable scratch/DerivedData root. One verification owner reviews the full integrated diff, runs the build and required tests, and owns all verification-driven fixes so writers do not conflict.
- Verify in order: package/app compilation, focused and full Swift tests, contract/fixture tests, app integration builds, XCUITest, then the named physical-device/live/performance gates. Preserve fixture and live as independent results.
- Treat compiler/linker failures, required-test failures, and violated mandatory acceptance conditions as `P0`. Fix them in the verification worktree and rerun only after the responsible code, configuration, or test changes. Skip `P1` through `P3` under the bounded audit rule.
- Record the final integrated SHA, resolved dependencies, Xcode/Swift version, commands, results, and remaining external gates. Delete the reusable build/scratch artifacts after evidence is recorded.
- A task moves from `code_ready_unverified` to `implementation_ready`, `integration_ready`, or `accepted` only from this phase. Keep its implementation checkbox checked while status and verification evidence advance. If verification proves the production scope or required test code was incomplete, return it to `[ ]`; an ordinary build/test failure alone does not erase the implementation record.

Fixture and live are independent results. A fake camera or mock Room cannot satisfy physical capture or live publish. A Simulator pass cannot satisfy camera, orientation, interruption, thermal, measurement accuracy, VoiceOver camera operation, or export gates.

For live failures, verify that the app remains in live mode, displays the failure, preserves progress, and never invokes fixture providers. For asynchronous work, verify old session/shot/sequence/request results cannot mutate current state.

## Complete or block honestly

Use `planned`, `in_progress`, `code_ready_unverified`, `implementation_ready`, `integration_ready`, `accepted`, and `blocked` to distinguish progress. Leave partial, uncommitted, missing-wiring, and P0-bearing tasks unchecked. Check a task at `code_ready_unverified` and keep it checked through later states; checkbox status does not prevent downstream separable work and never proves final acceptance. `code_ready_unverified` is the normal endpoint of Phase 1 and must never be described as built, tested, or working.

Mark `[x]` only when the whole production implementation and corresponding test code or justified `not applicable` are committed, one bounded source review has no P0, and the task record names remaining gates. Record Phase 1 evidence beneath the task in this form:

```markdown
- Implementation review (YYYY-MM-DD):
  - status: `code_ready_unverified`
  - commits: `<production/test SHA>`
  - production scope: `<full task scope summary>`
  - tests authored: `<paths and cases>` or `not applicable: <reason>`
  - source review: `P0 none`
  - execution: `build/test not run; deferred to Phase 2`
  - pending gates: `<integration/fixture/live/device/acceptance>` or `none`
```

Record Phase 2 evidence separately:

```markdown
- Verification (YYYY-MM-DD):
  - commit/build: `<SHA or build>`
  - automated tests: `<command and result>`
  - fixture: `<configuration / command / result / artifact>` or `not required`
  - live: `<configuration / backend SHA or version / command / result / artifact>` or `not required`
  - device: `<model / iOS / checked items / runbook or artifact>` or `not required`
  - limitations: `none` or a concise remaining limitation
```

The task-record commit is tracked by Git and must not self-reference its own SHA. Do not mechanically rewrite or uncheck pre-policy progress records for formatting alone; require concrete evidence that full production scope, required test code, or P0 safety is missing.

If blocked before the full implementation/test candidate exists, keep `[ ]` and record the reason, owner, and objective release condition. Do not lower acceptance criteria, invent evidence, or check a Swift task because the Web source implemented similar behavior. Final acceptance still requires every completion condition, automated test, fixture/live check, and physical-device gate; it is read from `accepted` plus the Phase 2 evidence, not the checkbox alone.

## Review a change

Review against the task's exact completion criteria and product acceptance IDs. Prioritize state-safety, privacy, pixel provenance, contract strictness, cancellation, recovery, accessibility, and missing device/live evidence. Do not report generic style preferences as blockers.

Keep audits bounded so review does not become an endless implementation loop:

- Classify every actionable audit finding as `P0`, `P1`, `P2`, or `P3`. Only `P0` blocks the current task, integration wave, or acceptance.
- Use `P0` only for a concrete, evidenced defect that makes an explicit completion condition false, fails a required build/test, violates a fixed product/security/privacy/data-lifetime/pixel-provenance invariant, risks data loss or a primary-flow crash, or makes the artifact unsafe to integrate. Do not promote preferences, speculative edge cases, cleanup ideas, or optional hardening to `P0`.
- Treat `P1` through `P3` as separate small follow-up issues. Record them concisely when useful, but skip fixing them in the current task. They must not trigger another implementation pass, another build, a new subagent, a task reopen, or another audit cycle.
- Do not add a new `task.md` item for a non-`P0` finding unless the user explicitly asks to schedule it. A short backlog or handoff note is sufficient.
- After one Phase 1 review pass, if there is no `P0` and the full implementation/test candidate is committed, record and check the task, then finish the assigned work unit without waiting for Phase 2 gates. Re-review only the diff that fixes a `P0` or when the candidate SHA materially changes.
- If a finding violates a mandatory completion condition, it is not a skippable `P1` through `P3`; classify it as `P0` and name the exact violated condition.

Before handoff, run formatting/lint only where configured, inspect the diff for unrelated changes and secrets, state what passed and what remains unverified, and do not push unless the user requested it.
