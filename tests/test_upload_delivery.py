"""Offline tests: structured receipts, false successes and private-output isolation."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import types
import unittest
import zipfile
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("upload_delivery", SCRIPTS / "upload_delivery.py")
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class UploadDeliveryTests(unittest.TestCase):
    def test_unsafe_export_stops_before_validation_or_upload(self):
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder);(work / "export").mkdir()
            with zipfile.ZipFile(work / "export/app.ipa", "w") as archive:
                archive.writestr("../outside", "SYNTHETIC_DATA")
            with patch.object(delivery.subprocess, "run") as run:
                with self.assertRaises(ValueError):delivery.private_ipa(work)
                run.assert_not_called()
            self.assertFalse((work / "outside").exists())

    def test_receipt_requires_explicit_success_and_no_errors(self):
        good = plistlib.dumps({"success-message": "No errors uploading private-name.ipa"})
        self.assertEqual(delivery.apple_result(b"tool prefix\n" + good), (True, []))
        for raw in [b"", b"UPLOAD SUCCEEDED", b"<plist>broken</plist>", plistlib.dumps({})]:
            self.assertEqual(delivery.apple_result(raw), (False, []))
        bad = plistlib.dumps({"success-message": "ignored", "product-errors": [
            {"code": -19209, "message": "SYNTHETIC_PRIVATE_MESSAGE"},
            {"code": "SYNTHETIC_PASSWORD"}, {"code": "90189"},
        ]})
        self.assertEqual(delivery.apple_result(bad), (False, [-19209, 90189]))

    def test_one_upload_and_zero_exit_errors_do_not_pass(self):
        cases = [
            (0, {"success-message": "No errors uploading private-app.ipa"}, True),
            (0, {"product-errors": [{"code": -19209, "message": "SYNTHETIC_PRIVATE_MESSAGE"}]}, False),
            (0, {}, False),
            (1, {"success-message": "not sufficient"}, False),
        ]
        for status, receipt, success in cases:
            with tempfile.TemporaryDirectory() as folder:
                work = Path(folder);(work / "private_keys").mkdir()
                (work / "private_keys/AuthKey_ABCDEFGHIJ.p8").write_text("SYNTHETIC_KEY_CONTENT")
                calls = []
                def fake_run(args, **kwargs):
                    calls.append(args)
                    self.assertEqual(args[:3], ["xcrun", "altool", "--upload-app"])
                    self.assertIn("--apiKey", args);self.assertIn("--apiIssuer", args)
                    self.assertEqual(args[-2:], ["--output-format", "xml"])
                    self.assertEqual(kwargs["cwd"], work)
                    self.assertNotIn("SYNTHETIC_KEY_CONTENT", " ".join(args))
                    self.assertNotIn("P12_PASSWORD", kwargs["env"])
                    self.assertEqual(kwargs["env"]["API_PRIVATE_KEYS_DIR"], str(work / "private_keys"))
                    kwargs["stdout"].write(plistlib.dumps(receipt))
                    kwargs["stderr"].write(b"HTTP 403 SYNTHETIC_TOKEN fixture@example.invalid /private/profile")
                    return types.SimpleNamespace(returncode=status)
                out = io.StringIO()
                with patch.dict(os.environ, APP_STORE_CONNECT_KEY_ID="ABCDEFGHIJ",
                                APP_STORE_CONNECT_ISSUER_ID="11111111-2222-3333-4444-555555555555",
                                P12_PASSWORD="SYNTHETIC_PASSWORD"), \
                     patch.object(delivery.subprocess, "run", fake_run), contextlib.redirect_stdout(out):
                    result = delivery.upload(work, work / "private-app.ipa")
                self.assertEqual(result == 0, success)
                self.assertEqual(len(calls), 1)
                for value in [folder, "private-app.ipa", "SYNTHETIC", "fixture@", "/private/profile"]:
                    self.assertNotIn(value, out.getvalue())
                if not success:
                    report = json.loads(out.getvalue().splitlines()[-1])
                    self.assertEqual(report["stage"], "apple-upload")
                    self.assertEqual(report["reported_exit_code"], status)
                    if "product-errors" in receipt:self.assertEqual(report["apple_error_codes"], [-19209])

    def test_no_key_stops_before_network(self):
        with tempfile.TemporaryDirectory() as folder, \
             patch.dict(os.environ, APP_STORE_CONNECT_KEY_ID="ABCDEFGHIJ",
                        APP_STORE_CONNECT_ISSUER_ID="11111111-2222-3333-4444-555555555555"), \
             patch.object(delivery.subprocess, "run") as run:
            with self.assertRaises(ValueError):delivery.upload(Path(folder), Path(folder) / "app.ipa")
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
