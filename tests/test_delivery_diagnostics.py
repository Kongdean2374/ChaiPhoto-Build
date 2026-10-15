"""Synthetic security regression tests; no Apple credentials or network access."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/delivery_diagnostics.py"
spec = importlib.util.spec_from_file_location("diagnostics", SCRIPT)
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class DeliveryDiagnosticsTests(unittest.TestCase):
    def test_shell_failure_keeps_original_exit_without_retry_or_raw_output(self):
        root = SCRIPT.parents[1]
        script = (root / "scripts/sign_upload.sh").read_text()
        for command, stage, status in [("-exportArchive", "export", 70),
                                        ("-project", "archive", 65)]:
            block = re.search(r"^if xcodebuild " + re.escape(command) + r"\b.*?^fi$",
                              script, re.M | re.S)[0]
            with tempfile.TemporaryDirectory() as folder:
                env = dict(os.environ, SIGN_DIR=folder, KEY_PATH="unused", CONFIG="unused",
                           APPLE_TEAM_ID="unused", SIGNING_IDENTITY="unused", PROFILE_NAME="unused",
                           KEYCHAIN_PATH="unused", APP_STORE_CONNECT_KEY_ID="unused",
                           APP_STORE_CONNECT_ISSUER_ID="unused")
                shell = ('set -euo pipefail\nxcodebuild() { printf "%s\\n" '
                         "'HTTP 403 SYNTHETIC_PASSWORD_NEVER_PUBLISH'; return " + str(status) + "; }\n" + block)
                result = subprocess.run(["bash"], input=shell, env=env, cwd=root,
                                        capture_output=True, text=True)
            self.assertEqual(result.returncode, status)
            self.assertNotIn("SYNTHETIC_PASSWORD_NEVER_PUBLISH", result.stdout + result.stderr)
            report = json.loads(result.stdout.splitlines()[-1])
            self.assertEqual(report["stage"], stage)
            self.assertEqual(report["exit_code"], status)
            self.assertEqual(report["http_statuses"], [403])

    def test_known_codes_without_raw_context(self):
        report = diagnostics.summarize(
            'Error Domain=NSURLErrorDomain Code=-1001 UserInfo={email=fixture@example.invalid}\n'
            'ERROR ITMS-90189: bundle version must be higher. HTTP 401\n'
            'Error Domain=UntrustedDomain Code=7654 Secret=SYNTHETIC_PRIVATE_VALUE',
            "export-upload", 70,
        )
        self.assertEqual(report["domain_codes"], [{"domain": "NSURLErrorDomain", "code": -1001}])
        self.assertEqual(report["itms_codes"], ["ITMS-90189"])
        self.assertEqual(report["http_statuses"], [401])
        self.assertIn("duplicate-build", report["signals"])
        rendered = json.dumps(report)
        for forbidden in ["UserInfo", "fixture@", "UntrustedDomain", "7654", "SYNTHETIC_PRIVATE_VALUE"]:
            self.assertNotIn(forbidden, rendered)

    def test_cli_never_prints_raw_secrets_or_paths(self):
        secrets = ["SYNTHETIC_PASSWORD_8q3", "SYNTHETIC_BASE64_ZXhhbXBsZQ==",
                   "SYNTHETIC_TOKEN_9n2", "fixture@example.invalid", "/private/synthetic/team/profile"]
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "private.log"
            log.write_text("\n".join(secrets) + '\n-----BEGIN ' + 'PRIVATE KEY-----\n'
                           'No signing certificate found. Error Domain=IDEDistributionErrorDomain Code=1\n')
            result = subprocess.run([sys.executable, str(SCRIPT), "--stage", "export-upload",
                                     "--exit-code", "70", "--log", str(log)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        for forbidden in secrets + [folder, "PRIVATE KEY"]:
            self.assertNotIn(forbidden, result.stdout + result.stderr)
        report = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(report["exit_code"], 70)
        self.assertEqual(report["stage"], "export-upload")
        self.assertIn("signing", report["signals"])
        self.assertFalse(report["raw_log_published"])

    def test_missing_and_large_log(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "private.log"
            args = [sys.executable, str(SCRIPT), "--stage", "archive", "--exit-code", "65", "--log", str(log)]
            result = subprocess.run(args, capture_output=True, text=True, check=True)
            self.assertFalse(json.loads(result.stdout.splitlines()[-1])["log_readable"])
            log.write_bytes(b"SYNTHETIC_PREFIX" * 600000 + b"\nError Domain=NSOSStatusErrorDomain Code=-25308\n")
            result = subprocess.run(args, capture_output=True, text=True, check=True)
            report = json.loads(result.stdout.splitlines()[-1])
            self.assertEqual(report["domain_codes"], [{"domain": "NSOSStatusErrorDomain", "code": -25308}])
            self.assertNotIn("SYNTHETIC_PREFIX", result.stdout)


if __name__ == "__main__":
    unittest.main()
