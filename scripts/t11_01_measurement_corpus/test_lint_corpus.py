#!/usr/bin/env python3
import subprocess
import sys
import unittest
import copy
import json
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2] / "Fixtures/MeasurementCorpus"
SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import lint_corpus


class CorpusLintTests(unittest.TestCase):
    def test_manifest_and_deterministic_images_lint(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / "lint_corpus.py")], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("deterministic synthetic cases", result.stdout)

    def test_negative_manifest_mutations_are_rejected(self):
        manifest = json.loads((ROOT / "corpus-manifest.json").read_text())
        mutations = []
        unknown = copy.deepcopy(manifest); unknown["cases"][0]["expectedFailure"] = "UNKNOWN"; mutations.append(unknown)
        corner = copy.deepcopy(manifest); corner["cases"][0]["expectedCorners"][0] = [-1, 0]; mutations.append(corner)
        ground_truth = copy.deepcopy(manifest); del ground_truth["cases"][0]["expectedMeasurementsCm"]; mutations.append(ground_truth)
        coverage = copy.deepcopy(manifest); coverage["cases"][0]["failurePair"] = {}; mutations.append(coverage)
        boundary = copy.deepcopy(manifest); boundary["cases"][14]["boundary"]["garmentMarkerGapPx"] = 99; mutations.append(boundary)
        for mutated in mutations:
            with self.assertRaises(ValueError):
                lint_corpus.validate(mutated)
        hash_drift = copy.deepcopy(manifest); hash_drift["cases"][0]["sha256"] = "0" * 64
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                lint_corpus.lint_render(hash_drift, Path(temporary))


if __name__ == "__main__":
    unittest.main()
