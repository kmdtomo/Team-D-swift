---
name: team-d-ios-design
description: "Design or review Team-D's native iPhone garment-capture experience in SwiftUI. Use for camera screens, fixed 2D guides, Japanese guidance, permissions, recovery, measurement editing, image comparison, accessibility, previews, and physical-device visual QA; not for React/Web, ARKit, 3D AR, or backend design."
---

# Team-D Native iPhone Design

Design the interface as a calm camera coach: keep the live garment visible, present one useful next action, preserve progress, and leave acceptance to the user and app-owned state.

## Before design work

1. Read `requirements.md`, especially R1-R9 and the affected acceptance IDs.
2. Read the relevant `task.md` tasks, fixture/live mode, and physical-device gate.
3. For a design or implementation review, also read [references/review-checklist.md](references/review-checklist.md).
4. For implementation, refactoring, or task completion, also use the delivery skill and enforce every predecessor before changing code.

Do not change product behavior inside a design task. If a design requires a new flow, permission, persistence rule, fallback, or contract, route it through the product-requirements workflow first.

## Native boundary

- Use SwiftUI semantics and Apple platform conventions. Do not port CSS values, browser safe-area code, `object-fit` transforms, Storybook assumptions, Canvas, or Web accessibility APIs.
- Use an `AVCaptureVideoPreviewLayer` bridge for the live image and its coordinate conversion. Fixed guides may change by shot but never track content in 3D.
- Do not introduce ARKit, scanning lines, surveillance styling, automatic capture, proprietary Mercari icons, or claims of an official Mercari UI kit.
- Use semantic text styles, colors, materials, controls, and SF Symbols where appropriate. Avoid scattering raw visual values or encoding meaning in color alone.

## Camera composition

Keep five stable layers:

1. full-bleed live camera as the working surface;
2. a thin, low-obstruction fixed guide;
3. one short actionable Japanese instruction;
4. persistent shot name and `n/4` progress;
5. stationary back, recovery, shutter, and any camera controls the current requirements and implementation actually provide.

The preview may extend behind safe areas, but text and controls must avoid the notch, Dynamic Island, and home indicator. Transient guidance must not move progress or the shutter. Never burn guides, messages, or controls into captured pixels.

Use `front/back` garment safe frames, a `tag` rectangle, and a `measurement` garment frame plus lower-right 50mm marker frame. On orientation changes, recompute preview and guide transforms and invalidate stale stability observations; do not invent support for orientations the project has not selected.

## Navigation model

- Make the camera capture flow the app root. On cold launch, show the in-flow camera permission state when needed; otherwise show `front 1/4` immediately.
- Do not add a home screen, feature list, dashboard, tab/sidebar shell, login gate, or separate tutorial before capture.
- Treat measurement preparation, measurement review, background editing, comparison, approval, and export as ordered states of the same capture session, not independent destinations in a general app hierarchy.
- Use a sheet, full-screen cover, or navigation destination only when the current state needs dedicated space. Returning must restore the same session and accepted slots rather than escape to an unrelated root.

## Guidance and copy

- Display one primary issue after priority and stability selection. Prefer physical actions such as `少し離してください` over diagnoses such as `距離不足です`.
- Convert finite codes into app-owned localized copy. Never display model prose, provider names, confidence percentages, or debug geometry.
- `READY` reassures; it does not enable capture. Keep the shutter accessible outside `READY` unless a capture is already in flight or the camera is technically unavailable.
- Acknowledge a resolved issue briefly, but let a newly confirmed higher-priority issue win.
- Debounce and deduplicate guidance by time, session, shot, sequence, and expiry. Do not animate or announce every frame.
- Do not promise tap-to-focus, torch behavior, import, or another action until that action exists and is reachable.

## Permissions, interruption, and mode

- Ask for camera permission in context with a specific usage description. Represent `notDetermined`, `authorized`, `denied`, and `restricted` separately.
- On denial, offer Settings and native photo selection. Call it `写真から選ぶ`, not upload, and route selected images through the same slot and validation rules.
- Keep current step and accepted slots through backgrounding, system interruption, runtime error, reconnect, and provider failure.
- Show connection state separately from image-quality guidance. During reconnect/disconnect, retain the fixed guide, local checks, shutter, and accepted progress.
- Mark fixture builds visibly as `テストデータ`. Never make fixture look live or replace a live error with fixture success.
- Error copy states what happened, what remains safe, and the next available action without exposing secrets or provider internals.

## Accessibility

- Target at least 44 by 44 points for interactive hit areas, with enough separation to prevent accidental actions.
- Use Dynamic Type and semantic styles. At the largest accessibility sizes, reflow or scroll secondary content; do not shrink or truncate the primary instruction, progress, or shutter into unusability.
- Hide the moving preview and decorative guide from VoiceOver. Expose structured progress, one stable instruction, connection status, and labeled controls in a deliberate order.
- Announce only stable state changes. The VoiceOver shutter must work outside `READY`.
- Give measurement endpoints a large hit area plus VoiceOver adjustable actions or explicit fine-adjust buttons; dragging cannot be the only input.
- After endpoint/manual-value changes, announce the new 0.1cm value and that approval returned to pending.
- Support Reduce Motion, Increase Contrast, Differentiate Without Color, Voice Control, and Switch Control without losing core actions.

## Measurement and final approval

- Separate marker preparation, capture, analysis, endpoint editing, warning, manual fallback, and approval states.
- Present computed measurements as editable proposals, initially unapproved. Editing clears prior approval.
- Disable approval for invalid endpoints and explain the correction. Out-of-range values require an explicit second confirmation, not silent rejection or acceptance.
- Distinguish manual and CV results, and require the retained fourth image in both paths.
- Compare original and composite with equivalent framing. Start with no approved selection, expose named original/composite choices, and require a separate `この画像を使う` confirmation.
- Never offer an invalid-mask composite as an approvable choice.

## Verification

Use deterministic SwiftUI previews/fixture hosts for every meaningful normal, loading, retry, disconnected, fallback, approval, and error state. Test a narrow supported iPhone, a Dynamic Island device, normal and maximum Dynamic Type, reduced motion/high contrast, long Japanese copy, and bright/dark/busy camera imagery.

Treat words such as calm, dominant, stable, and readable as design intent rather than standalone pass/fail claims. Tie acceptance to named view-state fixtures, the review checklist, screenshot/accessibility artifacts, configured contrast checks where available, and the physical-device matrix.

Preview and Simulator evidence are not sufficient for camera design completion. Verify permission, safe areas, supported rotation, interruptions, one-handed non-READY capture, VoiceOver order and endpoint adjustment, maximum Dynamic Type, real-image contrast, live disconnect behavior, and overlay-free captured pixels on a supported iPhone.

When the user asks only for design exploration or review, do not infer permission to modify implementation files.

## Apple references

Use current Apple documentation as the platform authority when native behavior changes:

- [Human Interface Guidelines: Design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles)
- [Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Human Interface Guidelines: Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy)
- [AVFoundation: Setting up a capture session](https://developer.apple.com/documentation/avfoundation/setting-up-a-capture-session)
- [SwiftUI: Accessibility fundamentals](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals)
