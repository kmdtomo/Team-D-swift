# T11-03 Apple/OpenCV iOS measurement-engine decision gate

- Status: blocked; no engine selected
- Date: 2026-09-01
- Lane: D/A
- Start ref: `3630266c3cd13b3cd322c998d7cd563cde50cdbd`
- Upstream implementation: T11-02 `code_ready_unverified` at commits
  `4c8eed4`, `e5ea981`, `2230664`, and `05316bc`
- Required comparison input: the same T11-01 rights/PII-cleared physical
  corpus and ruler-confirmed 50.0 mm marker evidence for both engines

## Decision

No Apple/OpenCV adoption decision is possible from the repository evidence.
The physical corpus log contains 0 of the required 30 captures, has no
ruler-confirmed 50.0 mm marker record, and has no rights, PII, annotation,
accuracy, latency, or memory evidence. Synthetic fixture success must not be
substituted for these physical gates.

OpenCV iOS is therefore not added. No OpenCV wrapper implementation, package,
binary, lockfile entry, OpenCV.js, WASM, Web Worker, or ArUco implementation is
present. The existing Apple-framework code remains a provisional candidate,
not a selected production engine.

## Separable decision implementation

`MeasurementEngineDecision.swift` freezes an engine-neutral finite analysis
contract and an evidence evaluator. The existing Apple PoC conforms directly.
`OpenCVMeasurementEngineWrapping` is a protocol only; it allows the same
contract suite to be applied later without creating or linking a dependency.

The evaluator enforces this order:

1. Reject selection until one rights-cleared, PII-cleared, fully annotated
   corpus has at least 30 captures and a ruler-confirmed 50.0 mm marker.
2. Require complete raw Apple results for that exact corpus: valid detection
   rate at least 95%, invalid scale acceptance exactly 0, maximum px/cm
   relative error at most 1%, baseline-device p95 at most 1 second, shared
   contract success, and reviewed memory evidence.
3. Select Apple and require no OpenCV dependency when Apple passes all gates.
4. Only when Apple fails a gate, require OpenCV results over the same corpus.
   OpenCV must pass every gate, removing all Apple failure indicators.
5. Before OpenCV selection, also require measured binary-size and clean-build
   deltas, pinned artifact source/checksum, license compatibility, NOTICE plan,
   privacy review, and explicit adoption approval.
6. If both engines fail, select neither. Preserve the thresholds and use the
   product-owned retake, user four-point placement, and manual-input fallbacks.

The frozen tuning contract is the T11-02 configuration: known marker side
5.0 cm, minimum marker side 80 px, every corner strictly more than 16 px from
the image edge, minimum side ratio 0.65, garment-marker gap at least 24 px,
and all eight finite failure codes. T11-02 authored deterministic coverage for
the 79/80, 16/17, 0.649/0.650, and 23/24 boundaries. No physical-corpus tuning
result exists, so these values were neither changed nor claimed optimal here.

The build-free JSON record and `scripts/t11_03_decision_gate.py` recompute the
current blockers and ensure an unselected OpenCV dependency or binary has not
entered the package/project graph. It deliberately reports `blocked` with a
successful validation exit code: the record is truthful and internally valid,
but the engine decision itself is not complete.

## Required measurements and currently missing inputs

| Input | Selection requirement | Current evidence |
| --- | --- | --- |
| physical corpus | at least 30 captures across distance, light, and mild tilt | 0/30 |
| rights / PII | every capture cleared | 0/30 |
| marker print | outer side ruler-confirmed at exactly 50.0 mm, 100% print | missing |
| corpus identity | stable fingerprint shared by both engine result sets | missing |
| annotations | expected validity, TL/TR/BR/BL, scale and ground truth complete | missing |
| Apple detection | valid marker detection at least 95% | unmeasured |
| Apple safety | invalid scale acceptance exactly 0 | unmeasured |
| Apple scale | maximum relative px/cm error at most 1% | unmeasured |
| Apple device cost | p95 at most 1 second plus reviewed raw memory evidence | unmeasured |
| OpenCV comparison | required only after an evidenced Apple failure, same corpus | not started |
| binary size | before/after archived app size delta on the same configuration | unmeasured |
| build time | clean-build delta on the same host/configuration, repeated protocol recorded | unmeasured |
| license / NOTICE | pinned artifact license compatibility and distribution notice plan | unreviewed |
| privacy | API/data-flow/privacy-manifest review for the exact artifact | unreviewed |

Binary size, build time, license/NOTICE, privacy, artifact source, and checksum
are intentionally `null`/`pending` in the machine record. Values must not be
filled from memory, a different OpenCV distribution, a Simulator-only run, or
the synthetic corpus.

## Shared contract verification authored for Phase 2

`MeasurementEngineDecisionTests.swift` covers physical-evidence blocking,
inclusive 95%/1%/1-second boundaries, Apple-first selection, same-corpus
enforcement, missing OpenCV cost and approval, legal/privacy disqualification,
OpenCV selection, and the neither-engine fallback. A generic finite-outcome
contract is exercised with Apple and OpenCV-shaped stubs; an actual OpenCV
wrapper must run that same suite only after the Apple failure gate authorizes
the comparison.

`scripts/test_t11_03_decision_gate.py` covers blocker drift, fabricated
selection, and premature OpenCV dependency injection. Both Swift and Python
test code are authored but intentionally not executed in Phase 1.

## Blocker ownership and release condition

- Owner: physical device operator/user for the T11-01 corpus, rights/PII
  attestations, annotations, and ruler/print-scale evidence.
- After that input exists: T11 measurement owner runs the Apple pipeline on
  the corpus and records raw accuracy, latency, and memory evidence.
- Only if Apple misses a fixed criterion: Lane D/A may pin and evaluate one
  OpenCV iOS artifact on the identical corpus and record all dependency costs.
- Release: the machine record contains complete, reviewable inputs and the
  evaluator produces Apple, OpenCV, or product-fallback outcome without a
  blocker. Until then T11-03 remains `[ ]` / `blocked`.

## Deferred gates

No compile, link, Swift test, Xcode build, app launch, fixture execution, or
physical-device measurement was performed. Phase 2 still owns package/app
compilation and the focused/full tests. T11-03 acceptance additionally requires
the physical comparison and the selected-engine remeasurement; downstream
user-corrected ±1.0 cm accuracy remains T18-03.
