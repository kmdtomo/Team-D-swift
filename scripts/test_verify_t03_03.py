#!/usr/bin/env python3
"""Adversarial coverage for T03-03's credential scanner."""

import importlib.util
import plistlib
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

    def test_rejects_swift_and_json_credential_literals(self):
        swift = "let api" + "Key = \"unsafe-value\""
        captured = "let to" + "ken = \"unsafe-value\""
        json = "{\"to" + "ken\": \"unsafe-value\"}"
        self.assertIn("credential assignment", verify.findings(swift))
        self.assertIn("credential assignment", verify.findings(captured))
        self.assertIn("credential assignment", verify.findings(json))

    def test_rejects_rembg_assignments_in_each_text_format(self):
        xcconfig = "RE" + "MBG_INTERNAL_URL = http://masker.invalid:7000"
        swift = "let rem" + "bgURL = \"https://masker.invalid\""
        json = "{\"rem" + "bgPort\": \"7000\"}"
        self.assertIn("rembg internal assignment", verify.findings(xcconfig))
        self.assertIn("rembg internal assignment", verify.findings(swift))
        self.assertIn("rembg internal assignment", verify.findings(json))

    def test_requires_an_exclusive_build_mode_guard(self):
        self.assertTrue(verify.has_exact_mode_guards("#if TEAM_D_FIXTURE && TEAM_D_LIVE\n#elseif TEAM_D_FIXTURE\n#elseif TEAM_D_LIVE\n#error(\"bad\")"))
        self.assertFalse(verify.has_exact_mode_guards("#if TEAM_D_FIXTURE\n#else\n#endif"))

    def test_rejects_target_configuration_miswiring(self):
        valid = """
A000000000000000000000B1 /* Debug-Live */ = {isa = XCBuildConfiguration; baseConfigurationReference = A00000000000000000000015 /* Debug-Live.xcconfig */; buildSettings = { GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = App/Info.plist; }; name = \"Debug-Live\"; };
A000000000000000000000B2 /* Release */ = {isa = XCBuildConfiguration; baseConfigurationReference = A00000000000000000000016 /* Release.xcconfig */; buildSettings = { GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = App/Info.plist; }; name = Release; };
A000000000000000000000B3 /* Debug-Fixture */ = {isa = XCBuildConfiguration; baseConfigurationReference = A00000000000000000000014 /* Debug-Fixture.xcconfig */; buildSettings = { GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = App/Info.plist; }; name = \"Debug-Fixture\"; };
"""
        self.assertEqual(verify.target_configuration_mapping(valid)["Debug-Fixture"], "Debug-Fixture.xcconfig")
        self.assertEqual(verify.target_configuration_mapping(valid.replace("00014", "00015")), {})

    def test_rejects_missing_configuration_from_any_target_list(self):
        valid = "\n".join(
            f"A000000000000000000000{list_id} list; buildConfigurations = (A000000000000000000000{prefix}1 /* Debug-Live */, A000000000000000000000{prefix}3 /* Debug-Fixture */, A000000000000000000000{prefix}2 /* Release */);"
            for list_id, prefix in (("70", "A"), ("71", "B"), ("72", "C"), ("73", "D"))
        )
        self.assertTrue(verify.all_configuration_lists_are_exact(valid))
        self.assertFalse(verify.all_configuration_lists_are_exact(valid.replace("A000000000000000000000C3", "")))

    def test_rejects_jwt_private_key_and_private_endpoint(self):
        self.assertIn("JWT-shaped token", verify.findings("eyJhbGciOiJIUzI1NiJ9." + "eyJzdWIiOiJ0ZXN0In0.signaturevalue"))
        self.assertIn("private key", verify.findings("-----BEGIN " + "PRIVATE KEY-----"))
        self.assertIn("private endpoint", verify.findings("http://127.0.0." + "1:7000/remove-background"))

    def test_rejects_rfc1918_and_ipv6_loopback_endpoints(self):
        for endpoint in ("http://10.0.0." + "1", "https://172.16.0." + "1", "wss://192.168.1." + "1:7880", "https://[::" + "1]:443"):
            self.assertIn("private endpoint", verify.findings(endpoint))

    def test_product_scan_recurses_through_bundle_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "TeamD.app"
            resource = bundle / "Frameworks" / "Nested.framework" / "secret.txt"
            resource.parent.mkdir(parents=True)
            resource.write_text("API_" + "KEY=unsafe-value", encoding="utf-8")
            with self.assertRaises(SystemExit):
                verify.check_product(bundle)

    def test_binary_fixture_is_scanned_with_strings(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary) / "fixture.bin"
            fixture.write_bytes(b"\0\x01API_" + b"KEY=unsafe-value\0")
            self.assertIn("credential assignment", verify.findings(verify.scanned_file_content(fixture)))

    def test_product_info_requires_mode_and_public_urls(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "TeamD.app"
            bundle.mkdir()
            (bundle / "Info.plist").write_bytes(plistlib.dumps({
                "TeamDMode": "fixture",
                "TeamDBackendBaseURL": "https://backend.example.invalid",
                "TeamDLiveKitURL": "wss://livekit.example.invalid",
            }))
            verify.check_product(bundle, "fixture")
            self.assertRaises(SystemExit, verify.check_product, bundle, "live")

    def test_rejects_sensitive_and_rembg_plist_keys_recursively(self):
        with self.assertRaises(SystemExit):
            verify.check_plist(Path("Info.plist"), {"Nested": {"rem" + "bgInternalURL": "http://masker" + ".invalid:7000"}})
        with self.assertRaises(SystemExit):
            verify.check_plist(Path("Info.plist"), {"api" + "Key": "unsafe-value"})

    def test_rejects_embedded_binary_plist_key_variants(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "TeamD.app"
            resource = bundle / "Frameworks" / "Nested.framework" / "Config.plist"
            resource.parent.mkdir(parents=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({
                "TeamDMode": "fixture",
                "TeamDBackendBaseURL": "https://backend.example.invalid",
                "TeamDLiveKitURL": "wss://livekit.example.invalid",
            }, fmt=plistlib.FMT_BINARY))
            resource.write_bytes(plistlib.dumps({"api" + "-key": "unsafe-value"}, fmt=plistlib.FMT_BINARY))
            with self.assertRaises(SystemExit):
                verify.check_product(bundle, "fixture")


if __name__ == "__main__":
    unittest.main()
