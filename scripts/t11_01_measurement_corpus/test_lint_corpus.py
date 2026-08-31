#!/usr/bin/env python3
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2] / "Fixtures/MeasurementCorpus"
SCRIPTS = Path(__file__).resolve().parent


class CorpusLintTests(unittest.TestCase):
    def test_manifest_and_deterministic_images_lint(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / "lint_corpus.py")], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("deterministic synthetic cases", result.stdout)


if __name__ == "__main__":
    unittest.main()
