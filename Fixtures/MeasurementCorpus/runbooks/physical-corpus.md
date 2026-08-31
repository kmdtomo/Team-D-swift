# T11-01 physical measurement corpus runbook

## Preconditions

1. Print `output/pdf/t11-01-50mm-marker.pdf` with printer scaling disabled
   (100% / Actual Size). Do not use "Fit", "Shrink", or borderless expansion.
2. With a physical ruler, measure the **outer black square**. Record `50.0mm`
   (within printer/ruler resolution) in
   `scripts/t11_01_measurement_corpus/physical-corpus-log.csv`. A failed
   ruler check invalidates every capture from that print.
3. Use a generic demo T-shirt only. Remove people, faces, names, addresses,
   labels containing personal data, serial numbers, screens, mail, and any
   third-party copyrighted image from the scene. Confirm both columns in the
   log before copying an image into an approved physical corpus location.

## Required core gate: 30 physical captures

Use the baseline iPhone standard Camera app; no Team-D app, backend, or API is
needed. Put the marker in the lower-right on the same plane as the garment and
at least 30mm from it. Capture the whole garment and marker from overhead.

T11-01's required physical gate is **at least 30 reviewed captures**. The
core matrix below is exactly 30 and focuses on the required distribution of
distance, tilt, and lighting. Do not count a single photo in more than one row.
Spread conditions; never turn a failed condition into a valid scale result.

| Condition | Minimum |
| --- | ---: |
| valid: close / slight tilt / bright indoor | 6 |
| valid: medium / overhead / diffuse indoor | 6 |
| valid: far / slight tilt / dim indoor | 6 |
| perspective-valid / dark / blur comparison | 4 each |

The following 10 failure/boundary comparison captures are **optional
additional evidence**, not a requirement that overrides the task's >=30 gate:
missing, multiple, too-small, occluded; edge 16px; ratio 0.649; overlap 23px;
garment out-of-frame; segmentation failure; and endpoints invalid. They may be
collected after the 30-core gate as availability permits, with each scenario
recorded separately.

## Annotation and review

For each capture, write the image path/hash, non-identifying capture ID,
device/iOS, ruler result, distance/tilt/light bands, scenario, expected and
observed failure, marker corners in top-left/top-right/bottom-right/bottom-left
order, derived px/cm, mask status, measurement endpoints, tape-measure
length/width, rights/PII checks, and annotation-complete flag in the CSV.
Only after review may approved, rights-cleared images be stored under the future
approved corpus policy. Keep raw camera photos out of this repository until
that approval exists.

The human must retain the completed evidence. Current blocker: **0/30** core
captures and no ruler confirmation are recorded. T11-01 may meet its approved
physical gate once the ruler check and 30 reviewed core captures are complete;
the optional additional comparisons are not required for that decision.
