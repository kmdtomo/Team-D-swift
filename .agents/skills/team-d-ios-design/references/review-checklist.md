# Native iPhone design review checklist

Report actionable findings only. Distinguish a requirement violation from optional polish, and cite the affected requirement and task ID.

## Flow and state

- The current shot and total progress are understandable at a glance.
- Front, back, tag, measurement, review, editing, approval, and recovery have explicit states.
- Exactly one actionable instruction wins when several observations coexist.
- Stale or noisy observations cannot flicker or rewind the UI.
- Manual capture works outside `READY`.
- Retakes, reconnects, and provider failures retain accepted shots and measurement edits.
- Busy, timeout, schema error, retry, interrupted, reconnecting, disconnected, and fallback states have deterministic fixtures.

## Camera and coordinates

- The live image remains visible and dominant.
- Guide geometry matches the current shot and does not track content.
- Persistent controls do not move with message length or state changes.
- Text and guide contrast works over white, black, and patterned garments/backgrounds.
- Preview, photo output, local analyzer, LiveKit publish, and overlay use one documented orientation/coordinate contract.
- Captured source images contain no overlay pixels.

## Copy and accessibility

- The main message contains one concrete Japanese action and no score, confidence, model, or diagnostic jargon.
- Error text says what happened, what was retained, and how to continue.
- Critical content survives maximum accessibility Dynamic Type without blocking the guide or shutter.
- Interactive hit areas are at least 44 by 44 points and meaning is not color-only.
- VoiceOver order is progress, stable instruction, connection state, then primary controls.
- Guidance announcements occur on stable changes rather than frames or packets.
- Measurement endpoints and image selection work without drag or swipe-only interaction.
- Reduce Motion and increased-contrast settings preserve equivalent meaning.

## Permission and recovery

- Camera permission is requested in context and all authorization states are represented.
- Denial offers Settings and native photo selection without losing the four-slot model.
- Background/foreground, system interruption, runtime error, and reconnect preserve current progress.
- Fixture is visibly labeled and a live failure never becomes fixture success.

## Measurement and editing

- Preparation explains marker dimensions, print scale, same-plane placement, garment orientation, and full-frame requirements.
- Missing, duplicate, small, cropped, distorted, or overlapping marker states give one recovery action.
- Computed and manual measurements begin unapproved; any edit clears approval.
- Invalid endpoints block approval with an explanation; range warnings require reconfirmation.
- Four images plus approved measurement are required before editing.
- Original and composite use equivalent framing, start without approval, and require explicit final confirmation.
- Invalid mask output cannot be selected, and garment RGB comes from original front pixels.

## Evidence gate

- SwiftUI preview/fixture evidence covers the state and accessibility matrix.
- Focused Swift Testing/XCTest covers selection, timing, approval reset, and guards.
- XCUITest covers the complete fixture flow and major recovery paths.
- Physical-device evidence covers camera, permission, safe areas, supported rotation, interruption, VoiceOver, Dynamic Type, live disconnect, and overlay-free source capture.
