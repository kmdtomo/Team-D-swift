# T11-01 measurement corpus

This directory is the text-only, iOS-owned corpus definition for the T11
Apple-framework measurement gate.  It intentionally contains no PNG files:
`Fixtures/asset-manifest.json` remains the closed T01-02 inventory and its
binary policy remains authoritative.

Generate the deterministic synthetic inputs into a disposable directory:

```sh
python3 scripts/t11_01_measurement_corpus/generate_synthetic.py --output /tmp/teamd-t11-01
python3 scripts/t11_01_measurement_corpus/lint_corpus.py --render-dir /tmp/teamd-t11-01
```

The generator is standard-library-only. The manifest pins each generated
SHA-256, rendered marker corners, candidate and accepted scale, mask
polygon/status, endpoint annotations, derived cm values, local quality hints,
and expected finite failure. The synthetic garment's derivable measurements
are 21.5cm by 22.0cm at 20px/cm, rather than unfounded 70/52 labels.
Perspective
cases record **rectified** px/cm: the scale after the four annotated corners
are perspective-corrected, not an axis-aligned source-pixel measurement.
Edge-margin and aspect-ratio rejections map compatibly to `MARKER_MISSING`
with the explicit reason `no valid marker candidate accepted`; this does not
add a production failure enum. Dark and blur are local-quality annotations,
not successful scale results. The physical corpus is
not represented by substitute fixture images: collect it with the runbook and
record only non-identifying conditions in `physical-corpus-log.csv`. The
required physical gate is >=30 reviewed captures plus the ruler check; its
optional 10-case failure/boundary comparison set is additional evidence only.

No ArUco, OpenCV, Web asset, source-Web binary, personal image, or secret is
used by this corpus.
