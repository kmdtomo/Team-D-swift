# Team-D Swift Repository Instructions

## Read first

Before planning, coding, reviewing, or marking work complete:

1. Read [`requirements.md`](./requirements.md) for product behavior and acceptance criteria.
2. Read [`task.md`](./task.md) for task dependencies, lane ownership, completion criteria, test mode, and physical-device gates.
3. Load the relevant repository skill from `.agents/skills/` when the request matches it.

The priority order is the user's latest explicit instruction, `requirements.md`, frozen wire contracts and fixtures, then `task.md`. Report a conflict instead of silently changing product behavior.

## Repository boundary

- This repository contains the native iPhone client. Use Swift, SwiftUI, AVFoundation, Swift Concurrency, URLSession, LiveKit Swift SDK, Vision, Core Image, Accelerate, ImageIO, simd, Core Graphics, Swift Testing, XCTest, and XCUITest as selected in `task.md`.
- Treat `neko-jpg/Team-D` as a read-only source at the SHA recorded in `requirements.md` and `task.md`. Reading, fetching, diffing, and running its tests are allowed; editing, committing, branching, or pushing there are not.
- Do not add OpenSpec or copy the source repository's OpenSpec skills, React skill, Web code, Web fixtures without a license decision, or Web build configuration.
- Do not port Python FastAPI, LiveKit Agent, rembg, or BiRefNet into Swift. Consume the shared backend through versioned contracts.
- Do not add ARKit, WebXR, 3D AR, 6DoF, automatic capture, OpenCV.js, or WASM. OpenCV for iOS is allowed only after the Apple-framework measurement gate in T11 fails its recorded criteria and the adoption gate is approved.

## Product invariants

- Start cold launches in the camera capture flow: show the in-flow permission state when needed, otherwise show `front 1/4`. Do not add a home, dashboard, tab shell, login gate, or separate tutorial before capture.
- Keep the fixed order `front -> back -> tag -> measurement`.
- Keep the manual shutter available outside `READY` whenever capture is technically possible.
- Never let AI free text, confidence, or `nextAction` alone accept a slot or choose navigation.
- Preserve accepted slots and measurement edits through retakes, reconnects, interruptions, and provider failures.
- Do not unlock background editing until all four images exist and measurement status is `approved_cv` or `approved_manual`.
- Use only the original `front` RGB for garment pixels in a composite. Never regenerate, retouch, recolor, or reshape the garment.
- Keep images, masks, assessments, endpoints, measurements, and intermediate outputs in the session only. The sole persistence exception is the final image the user explicitly approves and exports.
- Never replace a live failure with fixture success. Fixture and live are visible, independently verified modes.
- Never place API keys, LiveKit secrets, rembg internal addresses, tokens, or user images in source, committed xcconfig files, fixtures, logs, caches, screenshots, or test artifacts.

## Work selection and progress

- Identify the `task.md` task ID and lane before changing files. Treat listed predecessors as integration/acceptance dependencies unless a missing concrete artifact or decision makes them a hard start dependency; T11 remains the early measurement M0 decision gate.
- Freeze the work unit to the task IDs, lane, files, and deliverables explicitly named in the initial user request or subagent assignment. `task.md`, its unchecked items, dependencies, adjacent code, available worker slots, and discovered follow-ups do not expand that scope.
- After the initially assigned scope is committed and reported, stop. Do not select the next checklist item, refill the same worker with another task, or continue toward repository-wide completion unless the initial request explicitly assigned that broader range. A parent may dispatch only task IDs inside its own fixed initial scope, and each child ends after its bounded assignment.
- Never use an unchecked predecessor by itself as a reason to wait. Start separable fixture/mock work when the required versioned contract, protocol, finite type, fixture, golden payload, fake, expected image, or approved technical decision is stable. Record the specific missing artifact and release condition when work truly cannot start.
- At slice start, record the task/lane, referenced artifact and version, owned files, tests to author for deferred verification, and unresolved integration, live, device, and acceptance gates so another worker can safely build on the result.
- Keep a change to one task ID and one lane when practical. Agree on protocols and schemas before crossing lane boundaries.
- Lane A owns shared project files such as `project.pbxproj`, shared schemes, package lockfiles, contract schemas, and root navigation. Avoid unrelated formatting or dependency updates.
- Track work as `planned`, `in_progress`, `code_ready_unverified`, `implementation_ready`, `integration_ready`, `accepted`, or `blocked`. `code_ready_unverified` means committed code and authored but unexecuted tests only. Treat `[ ]` as any state except `accepted`; it is not a start gate. Change it to `[x]` only after every listed completion condition, automated test, fixture/live check, and required physical-device check passes.
- A source-Web completion, Simulator pass, mock Room, fake camera, or fixture pass does not satisfy a required Swift live or physical-device gate.
- If an external backend, credential, or device is unavailable, continue any separable fixture/mock implementation, leave integration/acceptance unchecked, and record the blocker, owner, and release condition. An unavailable required contract or unresolved product meaning can block the dependent implementation; do not fabricate either one.
- When multiple lanes inside the fixed initial assignment can proceed independently and delegation is available and authorized, keep those non-conflicting lanes active with bounded tasks. Prefer one task ID and lane per worker in a dedicated branch/worktree; do not let parallel workers edit the same shared file or `task.md`. Do not use an idle slot as authorization to add an unassigned task.

## Implementation rules

- Model workflow and connection as explicit, typed enums and validated events. Keep capture phase, accepted slots, measurement approval, and connection status separable.
- Inject time, UUIDs, providers, image stores, and configuration. Production features must not read process environment or global singletons directly.
- Isolate AVFoundation mutation and callbacks behind one owned session executor/actor. Do not create competing capture sessions for preview, photo capture, local analysis, and LiveKit publish.
- Normalize orientation and coordinates explicitly with ImageIO metadata and preview-layer transforms. Do not port CSS `object-fit` math.
- Bound frame processing, cancellation, retries, and timeouts. Prefer the latest frame and discard stale async results by session, shot, sequence, expiry, and request ID.
- Decode all external responses strictly into finite Swift types. Reject unknown required enum values and invalid coordinates; map provider errors into explicit recoverable states.
- Keep UI copy owned and localized by the app. Display one actionable Japanese instruction, not backend prose or internal diagnostics.
- Use semantic SwiftUI controls, text styles, colors, safe-area behavior, and accessibility APIs. Keep custom touch targets at least 44 by 44 points.

## Verification

- Use two phases: first implement every non-blocked local task without compiling or running tests; then use one dedicated verification owner on the fully integrated source to build, test, review, and repair it.
- During the implementation phase, write the required tests but do not run `swift build`, `swift test`, `xcodebuild`, XCUITest, app launches, clean builds, or other compile/link commands. Source-only lint, schema/document validation, secret scans, and `git diff --check` are allowed when they create no build artifacts. Mark committed candidates `code_ready_unverified` and keep them unchecked.
- After all locally implementable tasks reach `code_ready_unverified`, use one clean integrated worktree and one reusable scratch/DerivedData root. A single verification-and-fix owner runs compilation and the required tests, owns all resulting fixes, and prevents parallel writers from modifying that verification worktree.
- If verification fails, treat compiler/linker failures and required-test failures as `P0`, fix the responsible code/configuration/test, and rerun only after that change. Skip `P1` through `P3`; do not start another implementation or audit loop for them.
- Use deterministic fixture clocks, IDs, responses, and images. Include success, failure, timeout, stale-event, invalid-schema, interruption, and cancellation paths relevant to the task.
- Verify fixture and live separately when a task says both. A live test must fail visibly if live infrastructure fails.
- In final verification, run package/app compilation, focused and full tests, contract/fixture tests, app integration builds, XCUITest, and the named clean-clone/performance/device/live gates. Keep heavy commands single-flight and reuse the one verification scratch/DerivedData root.
- Rerun successful evidence only when the integrated SHA, resolved dependencies, shared project settings, contract, or tests changed; or when evidence is missing/corrupt or there is a concrete reproducibility concern. Delete regenerable verification artifacts after recording final evidence.
- Camera authorization, actual capture, orientation, interruption recovery, LiveKit camera publish, thermal/performance behavior, measurement accuracy, VoiceOver camera operation, and photo export require the physical-device evidence specified in `task.md`.
- Before completion, check that captured source pixels contain no guide/UI overlay, approved garment RGB provenance is preserved, session cleanup occurs, and secrets/user images are absent from logs and artifacts.
- Record completion evidence under the task when completing the work: commit/build, test command and result, separate fixture and live configuration/result/artifact entries, device/iOS/checks/runbook or `not required`, backend version, and any remaining limitation.

## Git and collaboration hygiene

- Preserve existing user changes and unrelated work. Do not use destructive reset or broad cleanup commands.
- Use focused commits. Do not combine source snapshot updates, dependency upgrades, generated project changes, and feature behavior without a stated reason.
- Never push or open external changes unless the user asks. When asked to push, verify local HEAD, upstream HEAD, and a clean worktree afterward.
