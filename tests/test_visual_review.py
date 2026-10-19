"""Regress the CI failure-evidence path without Photos access or private media."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("visual_collector", ROOT / "scripts/collect_visual_review.py")
COLLECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COLLECTOR)


class VisualEvidenceTests(unittest.TestCase):
    def export_step(self, succeeded, fail_first=False):
        workflow = (ROOT / ".github/workflows/validate-snapshot.yml").read_text()
        step = workflow.split("      - name: Export actual simulator screenshot attachments\n", 1)[1]
        step = step.split("      - name:", 1)[0].split("        run: |\n", 1)[1]
        shell = "\n".join(line[10:] for line in step.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "bin").mkdir()
            for flavor in ("Release-TestFlight", "Release-AppStore"):
                (base / f"test-{flavor}.xcresult").mkdir()
            stub = base / "bin/python3"
            stub.write_text(f"#!{sys.executable}\n" +
                            "import json,os,sys\n" +
                            "with open(os.environ['STUB_LOG'],'a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')\n" +
                            "sys.exit(1 if os.environ['FAIL_FIRST']=='true' and 'TestFlight' in sys.argv[2] else 0)\n")
            stub.chmod(0o755)
            log = base / "calls.jsonl"
            env = {**os.environ, "RUNNER_TEMP": str(base), "TESTS_SUCCEEDED": str(succeeded).lower(),
                   "PATH": str(base / "bin") + os.pathsep + os.environ["PATH"],
                   "STUB_LOG": str(log), "FAIL_FIRST": str(fail_first).lower()}
            # /bin/bash is Bash 3.2 on the macOS runner. Exercise the failure branch,
            # which previously aborted on an empty array under nounset.
            result = subprocess.run(["/bin/bash", "-c", shell], env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(len(calls), 2, result.stderr)
            self.assertIn("Release-TestFlight", calls[0][1])
            self.assertIn("Release-AppStore", calls[1][1])
            self.assertEqual(result.returncode, int(fail_first), result.stderr)
            for call in calls:
                self.assertEqual(call[3:], ["--require-complete"] if succeeded else [])

    def test_failed_tests_still_export_both_flavors_without_optional_arguments(self):
        self.export_step(False)

    def test_success_requires_complete_screenshots(self):
        self.export_step(True)

    def test_first_export_failure_does_not_skip_second_flavor(self):
        self.export_step(False, fail_first=True)

    def test_summary_failure_still_retains_extensionless_images_only(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            output = base / "Release-TestFlight"
            raw = base / "Release-TestFlight-raw"
            raw.mkdir()
            (raw / "screenshot").write_bytes(b"\x89PNG\r\n\x1a\nsynthetic test bytes")
            (raw / "jpeg").write_bytes(b"\xff\xd8\xffsynthetic test bytes")
            (raw / "hierarchy.txt").write_text("Do not upload UI hierarchies")
            (raw / "recording.mp4").write_bytes(b"Do not upload recordings")
            with patch.object(COLLECTOR.subprocess, "check_output", return_value="invalid json"), \
                    patch.object(COLLECTOR.subprocess, "run"):
                with self.assertRaisesRegex(RuntimeError, "screenshot export was still attempted"):
                    COLLECTOR.collect(base / "test.xcresult", output)
            self.assertEqual(sorted(p.name for p in output.iterdir()), ["jpeg.jpg", "screenshot.png"])


class AdditionalVisualEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "synthetic.xcresult"
        self.output = self.root / "Release-TestFlight"
        self.raw = self.root / "Release-TestFlight-raw"
        self.raw.mkdir()
        (self.raw / "extensionless-image").write_bytes(b"\x89PNG\r\n\x1a\nsynthetic image bytes")
        (self.raw / "nested").mkdir()
        (self.raw / "nested" / "extensionless-jpeg").write_bytes(b"\xff\xd8\xffsynthetic image bytes")
        (self.raw / "hierarchy.txt").write_text("Do not upload raw UI hierarchy")
        (self.raw / "recording.mp4").write_bytes(b"Do not upload screen recordings")

    def assert_images_only(self):
        self.assertEqual(sorted(p.name for p in self.output.iterdir()), [
            "extensionless-image.png", "nested__extensionless-jpeg.jpg"
        ])
        self.assertEqual((self.output / "extensionless-image.png").read_bytes(),
                         (self.raw / "extensionless-image").read_bytes())

    def test_extensionless_and_nested_images_are_retained_without_raw_attachments(self):
        with patch.object(COLLECTOR.subprocess, "check_output", return_value=json.dumps({"result": "Failed"})), \
             patch.object(COLLECTOR.subprocess, "run"):
            self.assertEqual(COLLECTOR.collect(self.bundle, self.output), 2)
        self.assert_images_only()

    def test_summary_failure_does_not_prevent_export_or_image_retention(self):
        with patch.object(COLLECTOR.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "summary")), \
             patch.object(COLLECTOR.subprocess, "run") as export:
            with self.assertRaisesRegex(RuntimeError, "summary failed"):
                COLLECTOR.collect(self.bundle, self.output)
            export.assert_called_once()
        self.assert_images_only()

    def test_partial_export_failure_still_retains_available_images(self):
        with patch.object(COLLECTOR.subprocess, "check_output", return_value="{}"), \
             patch.object(COLLECTOR.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "export")):
            with self.assertRaisesRegex(RuntimeError, "export failed"):
                COLLECTOR.collect(self.bundle, self.output)
        self.assert_images_only()


if __name__ == "__main__":
    unittest.main()
