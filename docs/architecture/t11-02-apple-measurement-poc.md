# T11-02 Apple measurement PoC decision record

- Status: provisional candidate; adoption decision pending
- Date: 2026-09-01
- Lane: D, measurement and image processing
- Frozen input: T11-01 synthetic corpus schema 2 and artifact commits
  `d588e48`, `3f64bb3`, and `187cced`
- Implementation baseline: `4c8eed4` and `e5ea981`
- Frameworks under evaluation: Vision, Core Image, Accelerate, and simd

## Decision

Keep the Apple-framework pipeline as the only implemented T11-02 candidate.
Do not add OpenCV yet, and do not describe the Apple candidate as adopted.
T11-03 may make an adoption decision only after the rights-cleared physical
corpus and the device measurements below exist. The current physical corpus is
0/30 and has no ruler-confirmed 50.0 mm print record, so no accuracy, latency,
memory, or engine-selection result is claimed here.

## Candidate pipeline and coordinate contract

1. Core Image normalizes all eight EXIF orientations to upright pixels.
   Marker corners and proposed endpoints use upright, top-left-origin pixels.
2. Accelerate analyzes a bounded grayscale plane for dark and blur rejection.
3. `VNDetectRectanglesRequest` proposes quadrilaterals. A bounded 320-pixel
   raster path is retained as deterministic evidence and validates the same
   50 mm outer square, 5 mm black frame, and 40 mm white interior.
4. Input corner permutations are canonicalized to
   top-left, top-right, bottom-right, bottom-left. Duplicate, collinear, and
   concave sets are rejected before a projective transform is formed.
5. `VNDetectContoursRequest` proposes the garment foreground. Frame contact,
   insufficient contrast, garment-marker clearance, and endpoint containment
   remain separately observable.
6. `CIPerspectiveCorrection` rectifies the marker to a deterministic square.
   The observed rectified side divided by the known 5.0 cm side yields px/cm.
7. `SIMDProjectiveTransform` provides an independently testable homography for
   later geometry integration; T11-02 does not approve a measurement or drive
   navigation.

The pipeline returns only finite app-owned outcomes. Edge/side-ratio rejection
maps to `MARKER_MISSING` because the frozen finite vocabulary has no separate
skew or edge code. Detector and perspective failures also reject scale rather
than fabricating it.

| Condition | Outcome |
| --- | --- |
| no accepted marker candidate | `MARKER_MISSING` |
| more than one candidate | `MARKER_MULTIPLE` |
| shortest marker side below 80 px | `MARKER_TOO_SMALL` |
| partial double-square evidence | `MARKER_OCCLUDED` |
| garment contour reaches the frame | `GARMENT_OUT_OF_FRAME` |
| garment-marker gap below 24 px | `GARMENT_MARKER_OVERLAP` |
| no usable garment foreground | `SEGMENTATION_FAILED` |
| proposed endpoint outside the accepted contour | `ENDPOINTS_INVALID` |
| dark, blur, or analyzer failure | finite `LocalQualityHint` rejection |

## Frozen synthetic evidence

The deterministic test synthesizes pixels from
`Fixtures/MeasurementCorpus/corpus-manifest.json`; it does not commit an
unlicensed photo. The manifest contains 18 cases: valid and perspective-valid,
all eight finite failures, the 79/80 px, 16/17 px, 0.649/0.650, and 23/24 px
boundaries, plus dark and blur. Successful cases compare canonical corners and
px/cm against their annotations with relative scale error at most 1%.

The focused source is
`Packages/Tests/MeasurementKitTests/AppleMeasurementPipelineTests.swift`. It
also covers all 24 input permutations for a perspective quadrilateral, all
eight EXIF orientations, Core Image output determinism, Vision rectangle and
contour candidates, double-square frame rejection, simd projection,
subsystem-to-finite-failure mapping, and repeat-run outcome reproducibility.

## Raw measurement protocol

Phase 2 must preserve the raw values instead of recording only pass/fail. The
test `testCorpusRecordsRawP95LatencyForOneSecondDeviceGate` attaches one
latency value per synthetic case and nearest-rank p95 to the `.xcresult`; the
one-second assertion is enabled only for a physical iOS target so Simulator or
Mac timing cannot be presented as the baseline-device gate.
`testCorpusRecordsXCTestClockAndMemoryMetrics` records XCTest clock and memory
metrics over the same corpus. Neither test was executed during Phase 1.

For each physical image, record one row with these fields:

| Field | Required value |
| --- | --- |
| input identity | rights-cleared capture ID and SHA-256; never a user image in logs |
| environment | device model, iOS, build SHA, engine revision, thermal state |
| ground truth | ruler-confirmed marker side and annotated TL/TR/BR/BL corners |
| observed result | finite outcome, observed corners, rectified side px, px/cm |
| accuracy | per-corner error, expected px/cm, relative scale error |
| performance | wall-clock milliseconds and XCTest memory metric |
| validity | expected valid/invalid and whether scale was accepted |

Use nearest-rank p95: sort the per-image durations and select
`ceil(0.95 * count)`. Store the complete raw table with the device run artifact;
do not place physical/user images in logs, caches, or test attachments.

## Unexecuted acceptance gates

| Gate | Required | Recorded result |
| --- | ---: | --- |
| rights/PII-cleared physical corpus | at least 30 distributed captures | pending, 0/30 |
| ruler-confirmed marker print | outer side 50.0 mm at 100% | pending |
| valid marker detection | at least 95% | pending |
| invalid scale acceptance | exactly 0 cases | pending |
| px/cm relative error | at most 1% | pending |
| baseline-device latency | p95 at most 1 second | pending |
| baseline-device memory | raw XCTest/device measurement retained and reviewed | pending |
| measurement accuracy | user-corrected length and width each within 1.0 cm | pending, downstream device gate |

Until every gate is measured on the approved physical corpus, the only valid
conclusion is that the Apple candidate and its deterministic test harness are
ready for Phase 2 verification. Fixture evidence cannot select the production
engine or satisfy device acceptance.
