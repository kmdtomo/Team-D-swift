#!/usr/bin/env python3
import copy, json, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2] / "Fixtures/MeasurementCorpus"
SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import lint_corpus

class CorpusLintTests(unittest.TestCase):
    def setUp(self): self.manifest = json.loads((ROOT / "corpus-manifest.json").read_text())
    def test_manifest_and_deterministic_images_lint(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / "lint_corpus.py")], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
    def test_adversarial_manifest_mutations_are_rejected(self):
        mutations=[]
        def mutate(fn):
            value=copy.deepcopy(self.manifest); fn(value); mutations.append(value)
        mutate(lambda x: x["cases"][0].update(extra=True))
        mutate(lambda x: x["cases"][0].pop("annotationId"))
        mutate(lambda x: x["cases"][1].update(id=x["cases"][0]["id"]))
        mutate(lambda x: x["cases"][1].update(file=x["cases"][0]["file"]))
        mutate(lambda x: x["cases"][1].update(sha256=x["cases"][0]["sha256"]))
        mutate(lambda x: x["cases"][0].update(sha256="g"*64))
        mutate(lambda x: x["cases"][0].update(expectedCorners=[[900,0],[1,0],[1,1],[0,1]]))
        mutate(lambda x: x["cases"][0].update(expectedCorners=[[680,710],[580,610],[680,610],[580,710]]))
        mutate(lambda x: x["cases"][0].update(renderedScalePxPerCm=19.0))
        mutate(lambda x: x["cases"][0]["markerGeometry"].update(unexpected=1))
        mutate(lambda x: x["cases"][14]["markerGeometry"].update(x=574))
        mutate(lambda x: x["cases"][13]["boundary"].update(sideRatio=.649))
        mutate(lambda x: x["cases"][0].update(failurePair={}))
        mutate(lambda x: x["cases"][16].pop("qualityFlag"))
        mutate(lambda x: x["cases"][17].update(qualityHint="TOO_DARK"))
        def swap_missing_multiple(x):
            missing, multiple = x["cases"][2], x["cases"][3]
            missing["expectedFailure"], multiple["expectedFailure"] = multiple["expectedFailure"], missing["expectedFailure"]
            missing["failurePair"], multiple["failurePair"] = multiple["failurePair"], missing["failurePair"]
        mutate(swap_missing_multiple)
        mutate(lambda x: x["cases"][6].update(expectedFailure="MARKER_MISSING", failurePair={"MARKER_MISSING":True}))
        mutate(lambda x: x["cases"][7].update(garmentMode="low_contrast", expectedFailure="SEGMENTATION_FAILED", failurePair={"SEGMENTATION_FAILED":True}))
        mutate(lambda x: x["cases"][5].update(expectedFailure="MARKER_TOO_SMALL", failurePair={"MARKER_TOO_SMALL":True}))
        for value in mutations:
            with self.assertRaises(ValueError): lint_corpus.validate(value)
    def test_hash_and_physical_log_mutations_are_rejected(self):
        value=copy.deepcopy(self.manifest); value["cases"][0]["sha256"]="0"*64
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError): lint_corpus.lint_render(value,Path(temporary))
        with tempfile.TemporaryDirectory() as temporary:
            log=Path(temporary)/"bad-log.csv"; log.write_text("capture_id,notes\n",encoding="utf-8")
            with self.assertRaises(ValueError): lint_corpus.lint_log(log)
if __name__ == "__main__": unittest.main()
