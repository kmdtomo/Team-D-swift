#!/usr/bin/env python3
import copy, csv, hashlib, json, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2] / "Fixtures/MeasurementCorpus"
SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import lint_corpus

class CorpusLintTests(unittest.TestCase):
    def setUp(self): self.manifest = json.loads((ROOT / "corpus-manifest.json").read_text())

    def write_csv(self, path, columns, rows):
        with path.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=columns)
            writer.writeheader(); writer.writerows(rows)

    def physical_fixture(self, directory):
        root = Path(directory) / "external-evidence"
        (root / "captures").mkdir(parents=True)
        (root / "ruler").mkdir()
        ruler = root / "ruler" / "ruler-check.pdf"
        ruler.write_bytes(b"%PDF-1.4\nT11-01 ruler evidence\n")
        marker_log = Path(directory) / "marker-log.csv"
        marker_rows = [{
            "marker_print_id": "marker-print-a",
            "marker_pdf_sha256": self.manifest["artifacts"][0]["sha256"],
            "print_scale_percent": "100",
            "ruler_measurement_mm": "50.0",
            "evidence_path": "ruler/ruler-check.pdf",
            "evidence_sha256": hashlib.sha256(ruler.read_bytes()).hexdigest(),
            "rights_checked": "true",
            "rights_basis": "first-party-capture",
            "pii_checked": "true",
            "review_complete": "true",
            "notes": "test-only synthetic evidence bytes",
        }]
        self.write_csv(marker_log, lint_corpus.MARKER_LOG_COLUMNS, marker_rows)
        conditions = (
            [("valid", "close", "slight", "bright-indoor")] * 6
            + [("valid", "medium", "overhead", "diffuse-indoor")] * 6
            + [("valid", "far", "slight", "dim-indoor")] * 6
            + [("perspective-valid", "medium", "slight", "diffuse-indoor")] * 4
            + [("dark", "far", "overhead", "dim-indoor")] * 4
            + [("blur", "close", "slight", "bright-indoor")] * 4
        )
        capture_rows = []
        for number, (scenario, distance, tilt, lighting) in enumerate(conditions, 1):
            photo = root / "captures" / f"capture-{number:02d}.jpg"
            photo.write_bytes(b"\xff\xd8\xff" + f"t11-01-{number:02d}".encode())
            capture_rows.append({
                "capture_id": f"physical-{number:03d}",
                "image_path": f"captures/capture-{number:02d}.jpg",
                "image_sha256": hashlib.sha256(photo.read_bytes()).hexdigest(),
                "marker_print_id": "marker-print-a",
                "device_model": "iPhone 15 Pro",
                "ios_version": "18.5",
                "distance_band": distance,
                "tilt_band": tilt,
                "lighting_band": lighting,
                "scenario": scenario,
                "expected_failure": "",
                "observed_failure": "",
                "corners_tl_tr_br_bl": "[[10,10],[110,10],[110,110],[10,110]]",
                "scale_px_per_cm": "20.0",
                "mask_status": "quality_rejected" if scenario in {"dark", "blur"} else "garment_complete",
                "measurement_endpoints": '{"lengthStart":[20,20],"lengthEnd":[20,400],"widthStart":[20,100],"widthEnd":[300,100]}',
                "length_cm": "60.0",
                "width_cm": "45.0",
                "rights_checked": "true",
                "rights_basis": "first-party-capture",
                "pii_checked": "true",
                "annotation_complete": "true",
                "notes": "test-only synthetic external file",
            })
        capture_log = Path(directory) / "capture-log.csv"
        self.write_csv(capture_log, lint_corpus.LOG_COLUMNS, capture_rows)
        return root, marker_log, marker_rows, capture_log, capture_rows
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

    def test_empty_physical_logs_are_explicitly_blocked(self):
        summary = lint_corpus.lint_log()
        self.assertEqual(summary["status"], "blocked")
        self.assertEqual(summary["reviewedCoreCaptures"], 0)
        self.assertEqual(summary["reviewedMarkerPrints"], 0)
        self.assertTrue(any("30" in blocker for blocker in summary["blockers"]))

    def test_complete_external_physical_gate_is_hash_verified(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, marker_log, _, capture_log, _ = self.physical_fixture(temporary)
            summary = lint_corpus.lint_log(capture_log, marker_log, root)
            self.assertEqual(summary["status"], "ready")
            self.assertEqual(summary["reviewedCoreCaptures"], 30)
            self.assertEqual(summary["fileVerifiedCaptures"], 30)
            self.assertEqual(summary["fileVerifiedMarkerPrints"], 1)
            self.assertEqual(summary["blockers"], [])

    def test_unreviewed_rights_and_tampered_external_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, marker_log, _, capture_log, capture_rows = self.physical_fixture(temporary)
            capture_rows[0]["rights_checked"] = "false"
            self.write_csv(capture_log, lint_corpus.LOG_COLUMNS, capture_rows)
            with self.assertRaisesRegex(ValueError, "rights_checked"):
                lint_corpus.lint_log(capture_log, marker_log, root)
            capture_rows[0]["rights_checked"] = "true"
            self.write_csv(capture_log, lint_corpus.LOG_COLUMNS, capture_rows)
            (root / capture_rows[0]["image_path"]).write_bytes(b"\xff\xd8\xfftampered")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                lint_corpus.lint_log(capture_log, marker_log, root)

    def test_repository_cannot_be_used_as_the_physical_evidence_root(self):
        with self.assertRaisesRegex(ValueError, "outside the repository"):
            lint_corpus.verified_external_file(lint_corpus.REPO, Path("capture.jpg"), "0" * 64, "test")
if __name__ == "__main__": unittest.main()
