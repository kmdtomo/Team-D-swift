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

## Capture 30 or more images

Use the baseline iPhone standard Camera app; no Team-D app, backend, or API is
needed. Put the marker in the lower-right on the same plane as the garment and
at least 30mm from it. Capture the whole garment and marker from overhead.

Record at least 30 photos, covering every matrix cell below at least once and
the `valid` cell at least six times. Spread distance, light tilt, and lighting;
do not turn a failed condition into a valid scale result.

| Condition | Minimum |
| --- | ---: |
| valid: close / slight tilt / bright indoor | 6 |
| valid: medium / overhead / diffuse indoor | 6 |
| valid: far / slight tilt / dim indoor | 6 |
| perspective valid, dark, blur | 3 each |
| missing, multiple, too-small, occluded | 1 each |
| edge 16px and 17px, ratio 0.649 and 0.650, overlap 23px and 24px | 1 each |
| garment out-of-frame, segmentation failure, endpoints invalid | 1 each |

## Annotation and review

For each capture, write a non-identifying capture ID, device/iOS, ruler result,
distance/tilt/light bands, scenario, and privacy/rights checks in the CSV.
Annotate marker corners in top-left, top-right, bottom-right, bottom-left order;
write derived px/cm, garment mask status, failure code (if any), and tape-measure
length/width in the protected evaluation store. Only after review may those
approved, rights-cleared images be stored under the future approved corpus
policy. Keep raw camera photos out of this repository until that approval exists.

The human must retain the completed evidence. T11-01 remains unchecked until
the ruler check and all 30 physical captures are complete.
