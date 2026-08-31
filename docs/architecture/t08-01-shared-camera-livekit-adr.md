# T08-01: single camera owner with app-produced LiveKit frames

- Status: `code_ready_unverified` (2026-08-31)
- Decision: one Team-D-owned `AVCaptureSession` is the only camera owner. Its
  video output supplies preview, local analysis, high-resolution photo output,
  and a capacity-one LiveKit publishing bridge. LiveKit must not use its camera
  capturer or discover an `AVCaptureDevice`.

## SDK evidence

- Confirmed: 2026-08-31.
- Fixed integration candidate: LiveKit Swift SDK `2.16.0`, installed with SPM as
  `.package(name: "LiveKit", url: "https://github.com/livekit/client-sdk-swift.git", .upToNextMajor("2.16.0"))`.
- Official package/API evidence: the [LiveKit Swift README](https://github.com/livekit/client-sdk-swift/blob/main/README.md)
  documents that SPM declaration; the official SDK repository is
  [livekit/client-sdk-swift](https://github.com/livekit/client-sdk-swift). Its
  published custom-frame path is `LocalVideoTrack.createBufferTrack`, cast to
  `BufferCapturer`, then `capture(CMSampleBuffer)`; this is also reproduced in
  the official LiveKit organization issue discussion [#843](https://github.com/livekit/client-sdk-android/issues/843).
- The repository currently has no LiveKit package dependency. T08-01 therefore
  does **not** modify `Packages/Package.swift`, `Package.resolved`, project, or
  scheme files. `#if canImport(LiveKit)` isolates the SDK type names. Absent SDK
  integration yields `unavailableSDK`, never fixture publish success.

## Frame and lifecycle boundary

1. T05's sole `AVCaptureVideoDataOutput` emits `AnalysisSample` from the same
   session that owns preview and `AVCapturePhotoOutput`.
2. `AppProducedCaptureSampleAdapter` derives dimensions, monotonic sequence,
   timestamp, and explicit rotation metadata from that output. It does not
   create a session or mutate pixel bytes.
3. `LatestAppProducedFramePublisher` accepts only the latest pending frame,
   permits one `publish` at a time, drops stale/replaced frames, and invalidates
   late work using a lifecycle generation on stop. A rejected transport handoff
   records `lastFailedSequence`/`publishFailureCount` and never advances
   `lastPublishedSequence`; T08-02 must use that observable failure for its
   connection state rather than treating it as a frame publish.
4. This spike does **not** yet provide an operational SDK handoff: its generic
   coordinator carries frame metadata only, while the SDK overload requires the
   original `CMSampleBuffer`. T08-02 must create/publish the buffer track after
   Room join, extend the capture boundary with a lossless timed sample wrapper,
   and wire that payload through the coordinator. Until then, the generic SDK
   publisher throws `unavailableSDK`; no local/live fallback is implied here.

## Required Phase 2 / device gates

- Add the SPM dependency and lock it through the Lane A owner; compile against
  the exact resolved `2.16.x` version and replace the currently explicit
  unavailable handoff with the SDK's `BufferCapturer.capture(CMSampleBuffer)`.
- Ensure T05 forwards the original `CMSampleBuffer` (or a lossless timed wrapper)
  instead of constructing a second capture session. Apply its capture rotation
  before handing the sample to LiveKit, and validate resolution/rotation on a
  real device.
- In live mode, publish for five minutes while taking several photos; record
  stop/restart behavior, thermal state, memory, and no-double-session evidence.
- Run the authored fake publisher ordering, cancellation, and drop tests only
  in the dedicated Phase 2 verification worktree.
