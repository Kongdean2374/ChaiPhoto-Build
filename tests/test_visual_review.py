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
    def export_step(self, succeeded, fail_first=False, scope="full"):
        workflow = (ROOT / ".github/workflows/validate-snapshot.yml").read_text()
        step = workflow.split("      - name: Export actual simulator screenshot attachments\n", 1)[1]
        step = step.split("      - name:", 1)[0].split("        run: |\n", 1)[1]
        shell = "\n".join(line[10:] for line in step.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "bin").mkdir()
            for flavor in ("Release-TestFlight", "Release-AppStore"):
                if scope != "layout": (base / f"quick-{flavor}.xcresult").mkdir()
                if scope != "quick":
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
                   "STUB_LOG": str(log), "FAIL_FIRST": str(fail_first).lower(), "VALIDATION_SCOPE": scope, "LAYOUT_PROFILE": "fr-dark-extra"}
            # /bin/bash is Bash 3.2 on the macOS runner. Exercise the failure branch,
            # which previously aborted on an empty array under nounset.
            # The workflow assigns each flavor its own runner. Execute the real
            # shell for each independent job, even if the first one fails.
            results = []
            for flavor in ("Release-TestFlight", "Release-AppStore"):
                results.append(subprocess.run(["/bin/bash", "-c", shell],
                                              env={**env, "VALIDATION_FLAVOR": flavor},
                                              capture_output=True, text=True))
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            per_flavor = 2 if scope in ("full", "focused") else 1
            self.assertEqual(len(calls), 2 * per_flavor, "\n".join(r.stderr for r in results))
            self.assertIn("Release-TestFlight", calls[0][1])
            self.assertIn("Release-AppStore", calls[per_flavor][1])
            self.assertEqual([r.returncode for r in results], [int(fail_first), 0],
                             "\n".join(r.stderr for r in results))
            for call in calls:
                flags = (["--require-quick"] if "quick-Release" in call[1] else
                         ["--require-layout", "--layout-profile=fr-dark-extra"] if scope == "layout" else
                         ["--require-focused"] if scope == "focused" else ["--require-complete"])
                self.assertEqual(call[3:], flags if succeeded else [])

    def test_quick_success_exports_quick_evidence_without_a_full_matrix_bundle(self):
        self.export_step(True, scope="quick")

    def test_quick_completeness_rejects_partial_images(self):
        with self.assertRaisesRegex(SystemExit, "require 10 actual"):
            COLLECTOR.require_screenshots(9, ["--require-quick"])
        COLLECTOR.require_screenshots(10, ["--require-quick"])

    def test_new_scopes_export_their_actual_evidence(self):
        self.export_step(True, scope="layout")
        self.export_step(True, scope="focused")
        self.export_step(False, scope="layout")
        self.export_step(False, scope="focused")

    def test_focused_count_and_exact_names_cannot_hide_missing_french_pages(self):
        with self.assertRaisesRegex(SystemExit, "requires 155 actual"):
            COLLECTOR.require_screenshots(154, ["--require-focused"])
        COLLECTOR.require_screenshots(155, ["--require-focused"])
        plan = json.loads((ROOT / "build/visual-pages.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            for language in plan["languages"]:
                for profile in plan["profiles"]:
                    name = f'{language}-{profile["appearance"]}-{profile["textSize"]}'
                    for page in plan["focused_pages"]:
                        (destination / f"visual-l128-focused-{name}-{page}_0_ACTUAL-ID__exported.png").touch()
            for page in plan["pages"]:
                (destination / f'visual-l128-{plan["focused_replay_profile"]}-{page}_0_ID__exported.png').touch()
            COLLECTOR.require_named_pages(destination, ["--require-focused"])
            missing = destination / 'visual-l128-fr-dark-extra-23-information_0_ID__exported.png'
            missing.rename(destination / 'visual-l128-fr-dark-extra-22-diagnostics-safety_1_OTHER__exported.png')
            with self.assertRaisesRegex(SystemExit, "fr-dark-extra-23-information"):
                COLLECTOR.require_named_pages(destination, ["--require-focused"])

    def test_selected_layout_requires_all_nine_named_pages_and_a_valid_profile(self):
        plan = json.loads((ROOT / "build/visual-pages.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            args = ["--require-layout", "--layout-profile=es-dark-extra"]
            for page in plan["focused_pages"]:
                (destination / f"visual-l128-focused-es-dark-extra-{page}_0_ID__exported.png").touch()
            COLLECTOR.require_named_pages(destination, args)
            with self.assertRaisesRegex(SystemExit, "supported --layout-profile"):
                COLLECTOR.require_named_pages(destination, ["--require-layout", "--layout-profile=unsupported"])
            (destination / 'visual-l128-focused-es-dark-extra-37-video_0_ID__exported.png').unlink()
            with self.assertRaisesRegex(SystemExit, "37-video"):
                COLLECTOR.require_named_pages(destination, args)

    def test_full_completeness_still_rejects_partial_matrix(self):
        with self.assertRaisesRegex(SystemExit, "requires 476 actual"):
            COLLECTOR.require_screenshots(475, ["--require-complete"])
        COLLECTOR.require_screenshots(476, ["--require-complete"])

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


class TouchExtentPrecisionTests(unittest.TestCase):
    """Exercise the exact finite Double comparison and constants in the Swift helper.

    This is an offline numerical boundary check, not execution of Swift/XCTest.
    """
    @classmethod
    def setUpClass(cls):
        import math
        import re
        source = (ROOT / "TestsUI/LocalizationFlowTests.swift").read_text()
        helper = source.split("    private func assertMinimumTouchExtent(", 1)[1].split("    private func clearDiagnosticsCentre(", 1)[0]
        cls.minimum = float(re.search(r"let minimum: CGFloat = ([0-9]+)", helper).group(1))
        cls.steps = int(re.search(r"let epsilon = minimum[.]ulp \* ([0-9]+)", helper).group(1))
        cls.epsilon = math.ulp(cls.minimum) * cls.steps
        # Fail if the native predicate stops matching the expression exercised here.
        if "XCTAssertTrue(extent.isFinite && extent >= minimum - epsilon," not in helper:
            raise AssertionError("The Swift boundary predicate changed; review the numerical regression")

    def accepted(self, extent):
        import math
        return math.isfinite(extent) and extent >= self.minimum - self.epsilon

    def test_nominal_44_and_observed_one_ulp_error_pass(self):
        import math
        self.assertEqual(self.minimum, 44.0)
        for value in (44.0, 43.99999999999999, math.nextafter(44.0, -math.inf), 45.0):
            with self.subTest(value=value): self.assertTrue(self.accepted(value))

    def test_four_ulp_budget_is_tiny_and_the_fifth_step_fails(self):
        import math
        self.assertEqual(self.steps, 4)
        self.assertEqual(self.epsilon, 2.842170943040401e-14)
        value = self.minimum
        for _ in range(4): value = math.nextafter(value, -math.inf)
        self.assertTrue(self.accepted(value))
        self.assertFalse(self.accepted(math.nextafter(value, -math.inf)))

    def test_materially_smaller_and_nonfinite_extents_fail(self):
        import math
        for value in (43.9999999999999, 43.999999, 43.999, 43.9, 43.0, 0.0, -1.0, math.nan, math.inf, -math.inf):
            with self.subTest(value=value): self.assertFalse(self.accepted(value))


class ValidationStageTests(unittest.TestCase):
    """Execute the real Bash orchestration; stubs model tools, not App/UI results."""
    def scenario(self, scope, fail_quick=False, profile="fr-dark-extra", segment=False):
        workflow = (ROOT / ".github/workflows/validate-snapshot.yml").read_text()
        step = workflow.split("      - name: Run targeted navigation then requested acceptance suite\n", 1)[1]
        step = step.split("      - name:", 1)[0].split("        run: |\n", 1)[1]
        shell = "\n".join(line[10:] for line in step.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = root / "bin"
            binaries.mkdir()
            log = root / "commands.jsonl"
            stub = f"#!{sys.executable}\n" + '''import json,os,pathlib,sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['COMMAND_LOG'],'a') as stream: stream.write(json.dumps([name,args])+'\\n')
if name=='xcrun':
    if args[:3]==['simctl','list','runtimes']:
        print(json.dumps({'runtimes':[{'identifier':'ci-runtime','isAvailable':True,'name':'iOS CI'}]}))
    elif args[:3]==['simctl','list','devicetypes']:
        print(json.dumps({'devicetypes':[{'identifier':'ci-se','name':'iPhone SE (3rd generation)'}]}))
    elif args[:2]==['simctl','create']:
        print('quick-device' if 'quick' in args[2] else 'full-device')
elif name=='swift':
    pathlib.Path(args[-1]).write_bytes(b'CI orchestration fixture, not a playable movie')
elif name=='xcodebuild':
    if '-resultBundlePath' in args: pathlib.Path(args[args.index('-resultBundlePath')+1]).mkdir()
    if os.environ['FAIL_QUICK']=='true' and any(a.startswith('-only-testing:') for a in args): sys.exit(65)
'''
            for name in ["xcrun", "xcodebuild", "swift", "xcodegen"]:
                path = binaries / name
                path.write_text(stub)
                path.chmod(0o755)
            env = {**os.environ, "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                   "RUNNER_TEMP": str(root), "GITHUB_STEP_SUMMARY": str(root / "summary.txt"),
                   "VALIDATION_FLAVOR": "Release-TestFlight", "VALIDATION_SCOPE": scope,
                   "COMMAND_LOG": str(log), "FAIL_QUICK": str(fail_quick).lower(), "LAYOUT_PROFILE": profile,
                   "LAYOUT_SEGMENT": str(segment).lower()}
            result = subprocess.run(["/bin/bash", "-c", shell], cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
            commands = [json.loads(line) for line in log.read_text().splitlines()]
            return result, commands

    def test_quick_scope_never_starts_the_full_suite(self):
        result, commands = self.scenario("quick")
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [args for name, args in commands if name == "xcodebuild"]
        self.assertEqual(len(builds), 1)
        self.assertIn("-only-testing:ChaiPhotoUITests/LocalizationFlowTests/testNavigationQuick", builds[0])
        self.assertIn("480", builds[0])
        imports = [args for name, args in commands if name == "xcrun" and args[:2] == ["simctl", "addmedia"]]
        self.assertEqual(len(imports), 1)
        self.assertEqual(len([p for p in imports[0][3:] if p.endswith(".png")]), 10,
                         "The ninth-decision reproduction must not depend on bundled Photos samples")

    def test_a_quick_failure_blocks_full_and_still_shuts_down_simulator(self):
        result, commands = self.scenario("full", fail_quick=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len([args for name, args in commands if name == "xcodebuild"]), 1)
        self.assertTrue(any(name == "xcrun" and args[:2] == ["simctl", "shutdown"] for name, args in commands))

    def test_full_reuses_products_but_creates_a_fresh_simulator_after_quick(self):
        result, commands = self.scenario("full")
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [args for name, args in commands if name == "xcodebuild"]
        self.assertEqual(len(builds), 2)
        self.assertIn("test-without-building", builds[1])
        self.assertIn("-skip-testing:ChaiPhotoUITests/LocalizationFlowTests/testNavigationQuick", builds[1])
        self.assertIn("900", builds[1])
        destinations = [args[args.index("-destination") + 1] for args in builds]
        self.assertNotEqual(destinations[0], destinations[1])


    def test_layout_scope_builds_only_selected_profile_and_units(self):
        result, commands = self.scenario("layout", profile="es-dark-extra")
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [args for name, args in commands if name == "xcodebuild"]
        self.assertEqual(len(builds), 1)
        self.assertIn("test", builds[0])
        self.assertIn("-only-testing:ChaiPhotoTests", builds[0])
        self.assertIn("-only-testing:ChaiPhotoUITests/LocalizationFlowTests/testLayout04esDarkLarge", builds[0])
        self.assertNotIn("-only-testing:ChaiPhotoUITests/LocalizationFlowTests/testNavigationQuick", builds[0])

    def test_focused_preserves_smoke_and_missing_profile_without_repeating_all_matrix_profiles(self):
        result, commands = self.scenario("focused")
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [args for name, args in commands if name == "xcodebuild"]
        self.assertEqual(len(builds), 2)
        self.assertIn("test-without-building", builds[1])
        self.assertIn("-only-testing:ChaiPhotoTests", builds[1])
        self.assertIn("-only-testing:ChaiPhotoUITests/LaunchFlowTests", builds[1])
        matrix = [x for x in builds[1] if "/testMatrix" in x]
        layouts = [x for x in builds[1] if "/testLayout" in x]
        self.assertEqual(matrix, ["-only-testing:ChaiPhotoUITests/LocalizationFlowTests/testMatrix05frDarkLarge"])
        self.assertEqual(len(layouts), 12)
        self.assertIn("-only-testing:ChaiPhotoUITests/LocalizationFlowTests/testManualLanguageChangePreservesPendingItemsAndCurrentPhoto", builds[0])
        self.assertIn("-only-testing:ChaiPhotoUITests/LocalizationFlowTests/testDiagnosticsPresentationQuick", builds[0])


class SegmentedLayoutTests(unittest.TestCase):
    """Execute workflow planner and Bash routing, not native App/UI validation."""
    def plan(self, profiles, flavor="both", scope="layout_batch", sha=None):
        workflow = (ROOT / ".github/workflows/validate-snapshot.yml").read_text()
        step = workflow.split("      - name: Validate and expand requested layout segments\n", 1)[1]
        step = step.split("  validate:", 1)[0].split("        run: |\n", 1)[1]
        shell = "\n".join(line[10:] for line in step.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            env = {**os.environ, "GITHUB_OUTPUT": str(output), "GITHUB_SHA": "a" * 40,
                   "EXPECTED_SHA": sha if sha is not None else "a" * 40,
                   "VALIDATION_SCOPE": scope, "REQUESTED_PROFILES": json.dumps(profiles),
                   "REQUESTED_FLAVOR": flavor}
            result = subprocess.run(["/bin/bash", "-c", shell], env=env, text=True, capture_output=True)
            matrix = json.loads(output.read_text().strip().removeprefix("matrix=")) if output.exists() else None
            return result, matrix

    def test_missing_eleven_profiles_expand_to_independent_jobs_without_french_dark(self):
        plan = json.loads((ROOT / "build/visual-pages.json").read_text())
        profiles = [f'{language}-{p["appearance"]}-{p["textSize"]}'
                    for language in plan["languages"] for p in plan["profiles"]
                    if f'{language}-{p["appearance"]}-{p["textSize"]}' != "fr-dark-extra"]
        result, matrix = self.plan(profiles)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(matrix["include"]), 22)
        self.assertEqual(sum(j["regressions"] for j in matrix["include"]), 1)
        self.assertTrue(matrix["include"][0]["regressions"])
        self.assertEqual({(j["flavor"], j["profile"]) for j in matrix["include"]},
                         {(f, p) for f in ["Release-TestFlight", "Release-AppStore"] for p in profiles})

    def test_only_one_failed_profile_and_flavor_can_be_retried(self):
        result, matrix = self.plan(["es-dark-extra"], "Release-AppStore")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(matrix, {"include": [{"flavor": "Release-AppStore", "profile": "es-dark-extra", "regressions": True}]})

    def test_invalid_empty_duplicate_or_injected_requests_fail_before_mac_jobs(self):
        for profiles in [[], ["en-light-standard"] * 2, ["unknown"], [None], [1], {},
                         ["$(touch /tmp/not-executed)"], ["en-light-standard"] * 13]:
            with self.subTest(profiles=profiles):
                result, matrix = self.plan(profiles)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(matrix)
        for kwargs in [{"flavor": "unknown"}, {"sha": "b" * 40}, {"sha": "bad"}, {"scope": "unknown"}]:
            result, matrix = self.plan(["en-light-standard"], **kwargs)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(matrix)

    def test_old_scopes_keep_exactly_two_original_flavor_jobs(self):
        for scope in ("quick", "layout", "focused", "full"):
            result, matrix = self.plan([], scope=scope)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(matrix, {"include": [{"flavor": f, "profile": "selected", "regressions": True}
                                                 for f in ["Release-TestFlight", "Release-AppStore"]]})

    def test_segment_runs_only_selected_nine_page_ui_without_probes_or_full_matrix(self):
        result, commands = ValidationStageTests().scenario("layout", profile="ja-dark-extra", segment=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [args for name, args in commands if name == "xcodebuild"]
        self.assertEqual(len(builds), 1)
        selected = [a for a in builds[0] if a.startswith("-only-testing:")]
        self.assertEqual(selected, ["-only-testing:ChaiPhotoUITests/LocalizationFlowTests/testLayout03jaDarkLarge"])
        self.assertFalse(any("screenshot" in args for name, args in commands if name == "xcrun"))

    def test_failed_segment_captures_current_synthetic_frame_then_shuts_down(self):
        result, commands = ValidationStageTests().scenario("layout", fail_quick=True, segment=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        xcrun = [args for name, args in commands if name == "xcrun"]
        shot = next(i for i, args in enumerate(xcrun) if args[:2] == ["simctl", "io"])
        shutdown = next(i for i, args in enumerate(xcrun) if args[:2] == ["simctl", "shutdown"])
        self.assertLess(shot, shutdown)
        self.assertIn("visual-l128-segment-interrupted-fr-dark-extra.png", xcrun[shot][-1])

    def test_interrupted_export_keeps_fallback_image_and_reports_failure(self):
        workflow = (ROOT / ".github/workflows/validate-snapshot.yml").read_text()
        step = workflow.split("      - name: Export actual simulator screenshot attachments\n", 1)[1]
        step = step.split("      - name:", 1)[0].split("        run: |\n", 1)[1]
        shell = "\n".join(line[10:] for line in step.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            binaries = base / "bin"
            binaries.mkdir()
            # Simulated tool output for orchestration only, never visual acceptance.
            (binaries / "xcrun").write_text(f"#!{sys.executable}\n" +
                "import pathlib,sys\nassert sys.argv[1:5]==['simctl','io','synthetic-device','screenshot']\n" +
                "pathlib.Path(sys.argv[-1]).write_bytes(bytes.fromhex('89504e470d0a1a0a'))\n")
            (binaries / "python3").write_text("#!/bin/bash\nexit 1\n")
            for binary in binaries.iterdir(): binary.chmod(0o755)
            (base / "visual-device-id").write_text("synthetic-device\n")
            (base / "test-Release-AppStore.xcresult").mkdir()
            env = {**os.environ, "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                   "RUNNER_TEMP": str(base), "VALIDATION_FLAVOR": "Release-AppStore",
                   "VALIDATION_SCOPE": "layout", "LAYOUT_SEGMENT": "true",
                   "LAYOUT_PROFILE": "fr-dark-extra", "TESTS_SUCCEEDED": "false"}
            result = subprocess.run(["/bin/bash", "-c", shell], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            images = list((base / "visual-review/Release-AppStore").iterdir())
            self.assertEqual([p.name for p in images], ["visual-l128-segment-interrupted-fr-dark-extra.png"])
            self.assertEqual(images[0].read_bytes(), b"\x89PNG\r\n\x1a\n")

    def test_each_segment_has_reserved_export_upload_time_and_distinct_artifact(self):
        workflow = (ROOT / ".github/workflows/validate-snapshot.yml").read_text()
        self.assertIn("inputs.validation_scope == 'layout_batch' && 18", workflow)
        self.assertIn("inputs.validation_scope == 'layout_batch' && 40", workflow)
        self.assertIn("fail-fast: false", workflow)
        self.assertIn("max-parallel: 2", workflow)
        self.assertIn("name: visual-review-${{ github.sha }}-${{ matrix.flavor }}-${{ matrix.profile }}", workflow)
        export = workflow.split("      - name: Export actual simulator screenshot attachments\n", 1)[1].split("      - name:", 1)[0]
        upload = workflow.split("      - name: Retain synthetic simulator screenshots only\n", 1)[1]
        for step in (export, upload): self.assertIn("if: always()", step)
        self.assertIn("timeout-minutes: 4", export)
        self.assertIn("timeout-minutes: 3", upload)
        self.assertIn("visual-device-id", export)
        self.assertNotIn(".xcresult", upload)
        self.assertNotIn("*.mp4", upload)


class PhotosConsentSetupContractTests(unittest.TestCase):
    """Offline source contracts, not a replacement for native delayed-sheet UI validation."""
    def setUp(self):
        self.source = (ROOT / "TestsUI/LocalizationFlowTests.swift").read_text()
        self.setup = self.source.split("override func setUpWithError() throws {", 1)[1].split("override func tearDownWithError", 1)[0]

    def test_delayed_sheet_is_polled_inside_same_bounded_marker_wait(self):
        loop = self.setup.split("while ProcessInfo.processInfo.systemUptime < deadline {", 1)[1].split("XCTAssertTrue(fullAccess.exists", 1)[0]
        self.assertIn("let deadline = ProcessInfo.processInfo.systemUptime + 20", self.setup)
        self.assertLess(loop.index("if fullAccess.exists"), loop.index("grant(springboard.alerts.firstMatch)"))
        self.assertLess(loop.index("grant(app.alerts.firstMatch)"), loop.index("if fullAccess.exists", loop.index("grant(app.alerts.firstMatch)")))
        self.assertIn("deadline - ProcessInfo.processInfo.systemUptime", loop)
        self.assertIn("timeout: min(0.5, remaining)", loop)
        self.assertNotIn("timeout: 3", self.setup)
        self.assertNotIn('"photo-access-full").waitForExistence(timeout: 10)', self.setup)

    def test_only_identified_photos_dialog_with_unique_full_access_button_is_tapped_once(self):
        grant = self.setup.split("func grant(_ alert: XCUIElement) -> Bool {", 1)[1].split("photosMonitor =", 1)[0]
        self.assertIn("guard alert.exists else { return false }", grant)
        self.assertIn("guard titleMatches && identifiesApp && buttons.count == 1 else { return false }", grant)
        self.assertIn("guard button.isHittable else { return false }", grant)
        self.assertLess(grant.index("if consentTapped { return true }"), grant.index("button.tap()"))
        self.assertLess(grant.index("consentTapped = true"), grant.index("button.tap()"))
        self.assertEqual(grant.count(".tap()"), 1)
        self.assertIn("Photo Library", self.setup)
        self.assertIn("ChaiPhoto", grant)
        # No fallback first-button / generic alert acknowledgement.
        self.assertNotIn("alert.buttons.firstMatch.tap()", self.setup)

    def test_request_is_inside_state_loop_after_full_access_and_alert_checks(self):
        loop = self.setup.split("while ProcessInfo.processInfo.systemUptime < deadline {", 1)[1].split("XCTAssertTrue(fullAccess.exists", 1)[0]
        guard = loop.index("if !requestAttempted && !consentTapped")
        for check in ["if fullAccess.exists", "grant(springboard.alerts.firstMatch)", "grant(app.alerts.firstMatch)"]:
            self.assertLess(loop.index(check), guard)
        self.assertIn("!springboard.alerts.firstMatch.exists && !app.alerts.firstMatch.exists", loop)
        self.assertIn("request.exists && request.isHittable", loop)
        self.assertNotIn("requestedAccess", self.setup)

    def test_request_event_has_stable_app_anchor_and_cannot_requery_disappearing_button(self):
        loop = self.setup.split("while ProcessInfo.processInfo.systemUptime < deadline {", 1)[1].split("XCTAssertTrue(fullAccess.exists", 1)[0]
        self.assertIn("app.coordinate(withNormalizedOffset: .zero)", loop)
        self.assertIn("point.x - appFrame.minX", loop)
        self.assertIn("point.y - appFrame.minY", loop)
        self.assertIn('XCTAssertFalse(guide.frame.contains(point), "Request tap must never advance the guide")', loop)
        self.assertNotIn("request.tap()", self.setup)
        self.assertNotIn("request.coordinate(", self.setup)
        self.assertNotIn('app.buttons["photo-access-button"].tap()', self.setup)
        self.assertLess(loop.index("requestAttempted = true"), loop.index("app.coordinate("))
        self.assertEqual(loop.count(".tap()"), 1)
        # Recheck independently completed authorization after frame sampling, before the sole event.
        self.assertIn("if fullAccess.exists { break }\n                    requestAttempted = true", loop)

    def test_real_authorization_guide_and_media_postconditions_and_screenshot_remain(self):
        self.assertIn('let fullAccess = element(app, "photo-access-full")', self.setup)
        self.assertIn("XCTAssertTrue(fullAccess.exists", self.setup)
        self.assertIn('XCTAssertFalse(element(app, "guide-next").exists', self.setup)
        self.assertIn('app.buttons["photo-mark-delete"].waitForExistence(timeout: 12)', self.setup)
        self.assertIn('attachment.name = "visual-l128-setup-full-access"', self.setup)
        self.assertIn("attachment.lifetime = .keepAlways", self.setup)


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

    def test_named_screenshots_do_not_copy_raw_manifest_or_hierarchy(self):
        (self.raw / "manifest.json").write_text(json.dumps([{"attachments": [{
            "exportedFileName": "extensionless-image",
            "suggestedHumanReadableName": "visual-l128-fr-dark-extra-14-review-bottom"
        }], "private-hierarchy": "must not be copied"}]))
        with patch.object(COLLECTOR.subprocess, "check_output", return_value='{"result":"Passed"}'), \
             patch.object(COLLECTOR.subprocess, "run"):
            self.assertEqual(COLLECTOR.collect(self.bundle, self.output), 2)
        self.assertFalse((self.output / "manifest.json").exists())
        self.assertTrue((self.output / "visual-l128-fr-dark-extra-14-review-bottom__extensionless-image.png").exists())

    def test_plan_covers_six_languages_two_profiles_and_every_named_matrix_page(self):
        import re
        plan = json.loads((ROOT / "build/visual-pages.json").read_text())
        self.assertEqual(set(plan["languages"]), {"zh-Hant", "zh-Hans", "en", "ja", "es", "fr"})
        self.assertEqual(plan["maximum_width_points"], 375)
        self.assertEqual({p["appearance"] for p in plan["profiles"]}, {"light", "dark"})
        self.assertEqual({p["textSize"] for p in plan["profiles"]}, {"standard", "extra"})
        source = (ROOT / "TestsUI/LocalizationFlowTests.swift").read_text()
        self.assertEqual(set(plan["pages"]), set(re.findall(r'"(\d\d-[a-z-]+)"', source)))
        self.assertEqual(len(plan["pages"]), 39)
        profiles = re.findall(r'func testMatrix\w+\(\) \{ runProfile\(code: "([^"]+)", theme: "([^"]+)", size: "([^"]+)"\)', source)
        self.assertEqual(len(profiles), 12)
        self.assertEqual(set(profiles), {(language, p["appearance"], p["textSize"])
                                        for language in plan["languages"] for p in plan["profiles"]})
        focused = re.findall(r'func testLayout\w+\(\) \{ runLayoutProfile\(code: "([^"]+)", theme: "([^"]+)", size: "([^"]+)"\)', source)
        self.assertEqual(len(focused), 12)
        self.assertEqual(set(focused), set(profiles))
        body = source.split("    private func runLayoutProfile(", 1)[1].split("    func testManualLanguageChange", 1)[0]
        self.assertEqual(set(re.findall(r'"(\d\d-[a-z-]+)"', body)), set(plan["focused_pages"]))


if __name__ == "__main__":
    unittest.main()
