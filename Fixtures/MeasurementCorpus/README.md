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

The generator is standard-library-only.  The manifest pins each generated
SHA-256, expected marker corners, scale, garment mask expectation, real-world
measurement expectation, and expected finite failure.  The physical corpus is
not represented by substitute fixture images: collect it with the runbook and
record only non-identifying conditions in `physical-corpus-log.csv`.

No ArUco, OpenCV, Web asset, source-Web binary, personal image, or secret is
used by this corpus.
