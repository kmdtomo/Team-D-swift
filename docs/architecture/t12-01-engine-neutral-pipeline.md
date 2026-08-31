# T12-01 engine-neutral measurement geometry pipeline

- Status: separable core implemented; selected-engine integration blocked
- Date: 2026-09-01
- Lane: D, measurement and image processing
- Upstream source: `3630266c3cd13b3cd322c998d7cd563cde50cdbd`
- Engine-neutral production/test candidate: `8437d12`
- Stable input contract: T11-02 `code_ready_unverified` types and PoC record
- Engine decision: not made; T11-03 still requires physical evidence

## Fixed work boundary

This slice owns only the T12-01 pipeline, its focused test code, and this
record. It does not edit `task.md`, `Package.swift`, the Xcode project,
dependency locks, shared schemas, or T11-03 decision/harness files. It does not
select Apple frameworks or OpenCV and does not add an image-engine dependency.

T11-02 is a stable start dependency because it supplies upright top-left pixel
coordinates, canonical marker quadrilaterals, marker evidence, image quality,
and finite measurement failures. T11-03 is an integration dependency because
the production adapter cannot be selected before the required physical-corpus
comparison. The physical corpus and baseline-device run are acceptance
dependencies, not fixture substitutes.

## Implemented engine-neutral contract

`MeasurementGeometryPipeline` owns the following sequence:

1. ask the injected engine adapter for an upright image;
2. reject dark or blurry images with finite local-quality codes;
3. obtain marker evidence and enforce product thresholds itself;
4. obtain and validate an in-memory garment mask and whole-garment contour;
5. enforce garment-to-marker polygon clearance;
6. calculate a Double-precision homography from the validated marker;
7. derive a corrected full-plane output extent and inverse transform;
8. ask the adapter to rasterize the image and mask with that transform;
9. verify corrected image/mask dimensions and in-frame garment coverage;
10. expose px/cm only in the success result.

The adapter cannot lower or bypass the following fixed gates:

| Condition | Pipeline result |
| --- | --- |
| marker shortest side 79 px | `MARKER_TOO_SMALL`, no output |
| marker shortest side 80 px | accepted by this gate |
| any corner 16 px from an image edge | `MARKER_MISSING`, no output |
| every corner 17 px or farther from an image edge | accepted by this gate |
| shortest/longest side 0.649 | `MARKER_MISSING`, no output |
| shortest/longest side 0.650 | accepted by this gate |
| garment-marker gap 23 px | `GARMENT_MARKER_OVERLAP`, no output |
| garment-marker gap 24 px | accepted by this gate |
| garment touches the source or corrected frame | `GARMENT_OUT_OF_FRAME` |
| missing/unusable mask | `SEGMENTATION_FAILED` |
| dark/blur input | `TOO_DARK` / `TOO_BLURRY`, no output |

The known marker side remains exactly 5.0 cm. Scale is the corrected marker
side divided by 5.0 and is checked for positivity and finiteness. Failures are
finite app-owned values and never carry a corrected image, scale, or cm value.
The public transform maps arbitrary Double source points into corrected pixels
and provides its checked inverse for round trips.

Cancellation uses an injected checkpoint contract. The production checker
observes `Task` cancellation before and between normalization, quality,
marker, mask, geometry, and rasterization stages. A synchronous framework call
must remain bounded by its selected adapter; cancellation is guaranteed at the
next stage boundary and cannot publish a partial result.

## Focused test code authored for Phase 2

`Packages/Tests/MeasurementKitTests/MeasurementGeometryPipelineTests.swift`
contains source for:

- 79/80 px, 16/17 px, 0.649/0.650, and 23/24 px exact boundaries;
- whole-garment-in-frame, dark, blur, missing/multiple/occluded marker, and
  unavailable segmentation failures;
- all 24 marker-corner permutations;
- Double forward/inverse homography round trip and degenerate rejection;
- known 5.0 cm marker scale and coupled corrected image/mask dimensions;
- wrong renderer dimensions and every adapter-stage error;
- deterministic cancellation before later stages execute;
- explicit absence of scale/corrected output on every invalid result.

These tests were authored but not run in Phase 1. No `swift build`,
`swift test`, `xcodebuild`, XCUITest, app launch, compile, or link command was
used.

## Objective blocker and release condition

T12-01 cannot be checked as `code_ready_unverified` yet because its stated full
production scope is “the selected engine,” and there is no evidence-backed
selection or production adapter. The blocker owner is T11-03 Lane D/A plus the
physical-device operator. Release requires:

1. rights/PII-cleared physical corpus of at least 30 distributed iPhone
   captures and ruler-confirmed 50.0 mm print evidence from T11-01;
2. the same-corpus and baseline-device T11-02 metrics required by the gate;
3. T11-03 ADR selecting Apple only if all criteria pass, or comparing OpenCV on
   the same corpus only after a measured Apple failure;
4. a selected-engine adapter implementing
   `MeasurementGeometryPipelineEngine`, dependency binding, and the same
   focused contract suite;
5. Phase 2 package/app compile, focused/full tests, fixture/live integration,
   and physical distance/tilt scale-repeatability evidence.

Until those conditions exist, this commit is a bounded partial production/test
candidate. It does not claim an engine, a successful build/test, device
accuracy, live readiness, or final acceptance.
