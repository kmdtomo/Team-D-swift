# Physical iPhone and demo runbook

## Automatic signing

1. Use an iPhone that supports iOS 18 or later, a data-capable cable or trusted
   wireless connection, and Xcode 26.2 (17C52).
2. In Xcode Settings > Accounts, add the Apple ID authorized for the demo team.
3. Open `TeamD.xcworkspace`, select the `TeamD` app target, open Signing &
   Capabilities, enable Automatically manage signing, and select that team.
4. If `jp.teamd.capture` is unavailable to the team, choose a unique local
   bundle identifier. Signing team and bundle-ID edits are local operator
   settings; do not commit them.
5. Select the connected iPhone as the run destination. Complete Developer Mode
   and trust prompts on the device. Resolve signing diagnostics before
   continuing; never disable signing or add credentials to source.

For deterministic fixture-on-device diagnosis, keep `Debug-Fixture`. For the
shared service path, follow [the live runbook](live.md), locally select
`Debug-Live`, and confirm `Live モード`. A Simulator result cannot satisfy the
physical camera, rotation, interruption, publish, VoiceOver, or save gates.

## Physical-device flow

Record the device model, iOS version, Xcode build, app commit, backend release,
build configuration, and start/end timestamps before interacting with the app.
Then verify in order:

1. Cold launch enters the in-flow permission screen or `front 1/4`, not a home,
   tab, login, or separate tutorial.
2. Permission grant starts one rear-camera session. Permission denial presents
   the documented recovery without losing the four-slot flow.
3. Portrait and every allowed orientation keep the guide aligned while the
   captured original has no guide/UI pixels.
4. Background/foreground and a phone/Control Center-style interruption recover
   without a second capture session or lost accepted slots.
5. In live mode, verify connection, camera publication, camera-only Agent
   subscription, and finite guidance push as four distinct observations.
6. With VoiceOver and maximum Dynamic Type, confirm progress, the active
   instruction, shutter, retry, endpoint editing, image choice, approval, and
   save remain operable.

These observations require a human/device evidence record. This document does
not assert that any T18 device gate has passed.

## Demo preflight

Use this as a go/no-go list. A failed live item makes the live demo `NO-GO`;
switching to a separately labelled fixture demo does not make it live.

- [ ] Commit/build/backend release and fixture-or-live mode are written on the
      operator sheet.
- [ ] The marker was printed at 100%, its outer edge measures 50.0 mm with a
      ruler, its black border measures 5 mm, and it is clean and flat.
- [ ] The T-shirt is a flat short-sleeve crew-neck garment on a plain,
      high-contrast surface; the marker can remain on the same plane at least
      30 mm away from the garment.
- [ ] Shared backend health and sanitized token-contract preflight pass.
- [ ] Backend, LiveKit Agent, AI providers, and required routes report the same
      staged release; the Agent is prewarmed without logging an image.
- [ ] rembg/BiRefNet is prewarmed through the backend-owned path and returns a
      valid mask-only result. The iPhone never calls rembg directly.
- [ ] Background generation is available and prewarmed using text-only allowed
      style input. No product, mask, tag, or measurement image is sent.
- [ ] Room connection, camera publish, camera-only subscribe, and finite push
      are separately observed; no periodic HTTP image polling exists.
- [ ] Photo-library add permission or the approved share/export destination is
      ready, with enough free device storage.
- [ ] A timer and sanitized evidence sheet are ready; screenshots and logs will
      not contain user images, participant tokens, credentials, or internal
      service addresses.

The current audited snapshot cannot check the Agent-push, mask-route, or
background-generation boxes and the Swift live provider is unavailable. Until
the release gates in [the live runbook](live.md) are met, the live demo is
`NO-GO`.

## Capture-to-save checklist

1. Confirm the expected mode badge, connect, publish, subscribe, and receive a
   pushed finite instruction.
2. Capture `front`, `back`, and `tag` in order. For retry/timeout, remain on the
   same slot and verify earlier accepted slots remain.
3. Prepare the back-up T-shirt and 50 mm marker, then capture `measurement` with
   the garment and marker fully visible from overhead.
4. Review all four endpoints, adjust them, confirm values update to 0.1 cm, and
   independently approve length and width. If automatic measurement fails,
   use the explicit retake/manual path; never invent a scale.
5. Confirm background editing remains locked until four images and
   `approved_cv` or `approved_manual` exist.
6. Generate/select a text-only background, obtain a front-only mask, and
   compare original versus composite in the same viewport. Product RGB must
   come only from the original `front`.
7. Select one candidate, then perform the separate approval action. Save only
   that approved front image.
8. End the session. Verify camera/Room/tasks stop and session images, masks,
   assessments, measurements, endpoints, and intermediate outputs are no
   longer accessible.

If any step fails, preserve accepted progress, record the layer and error code,
and use [failure isolation](troubleshooting-and-privacy.md). Never continue a
live checklist using fixture data.

## Evidence boundary

The completed sheet must distinguish automatic-signing success, camera/device
lifecycle, live connectivity, capture, measurement accuracy, background/mask,
pixel provenance, explicit approval/save, privacy cleanup, and any limitation.
Record `not run` for every step after a blocker. A blank checklist or runbook
publication is not second-developer evidence, T18 evidence, or acceptance.
