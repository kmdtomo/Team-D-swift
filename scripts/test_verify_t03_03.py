#!/usr/bin/env python3
"""Adversarial coverage for T03-03's credential scanner."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify_t03_03.py")
SPEC = importlib.util.spec_from_file_location("verify_t03_03", SCRIPT)
verify = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(verify)


class CredentialScanTests(unittest.TestCase):
    def test_allows_documented_synthetic_values(self):
        self.assertEqual(verify.findings("token = synthetic.not-a-secret.signature\nurl = https://backend.example.invalid"), [])

    def test_rejects_config_credential_assignment(self):
        value = "LIVEKIT_API_" + "SECRET = unsafe-value"
        self.assertIn("credential assignment", verify.findings(value))

    def test_rejects_jwt_private_key_and_private_endpoint(self):
        self.assertIn("JWT-shaped token", verify.findings("eyJhbGciOiJIUzI1NiJ9." + "eyJzdWIiOiJ0ZXN0In0.signaturevalue"))
        self.assertIn("private key", verify.findings("-----BEGIN " + "PRIVATE KEY-----"))
        self.assertIn("private endpoint", verify.findings("http://127.0.0." + "1:7000/remove-background"))

    def test_product_scan_recurses_through_bundle_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "TeamD.app"
            resource = bundle / "Frameworks" / "Nested.framework" / "secret.txt"
            resource.parent.mkdir(parents=True)
            resource.write_text("API_" + "KEY=unsafe-value", encoding="utf-8")
            with self.assertRaises(SystemExit):
                verify.check_product(bundle)


if __name__ == "__main__":
    unittest.main()
