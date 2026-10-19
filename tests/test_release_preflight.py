"""Offline Apple metadata fixtures; no credentials, builds or network requests."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("release_preflight", SCRIPTS / "release_preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


def version(value="1.2.5", state="READY_FOR_DISTRIBUTION", legacy=False):
    return {"attributes": {"versionString": value, "platform": "IOS",
                           "appStoreState" if legacy else "appVersionState": state}}


class ReleasePreflightTests(unittest.TestCase):
    def run_check(self, marketing, build="58", versions=None, highest="51"):
        responses = [
            {"data": [{"id": "fixture-app"}]},
            {"data": versions if versions is not None else [version()]},
            {"data": [{"attributes": {"version": highest}}]},
        ]
        output = io.StringIO()
        with patch.object(preflight, "resolve", return_value=(marketing, build)), \
             patch.object(preflight, "make_token", return_value="SYNTHETIC_TOKEN_NEVER_PRINT"), \
             patch.object(preflight, "get", side_effect=responses) as get, \
             contextlib.redirect_stdout(output):
            preflight.check(Path("not-a-real-key"))
        self.assertEqual(get.call_count, 3)
        self.assertNotIn("SYNTHETIC_TOKEN", output.getvalue())
        self.assertIn("/appStoreVersions?", get.call_args_list[1].args[0])
        self.assertIn("filter%5Bplatform%5D=IOS", get.call_args_list[1].args[0])

    def test_126_build58_after_approved125(self):
        self.run_check("1.2.6")

    def test_build_increase_cannot_reopen_approved_train(self):
        with self.assertRaisesRegex(SystemExit, "Marketing version"):
            self.run_check("1.2.5", "9998")
        with self.assertRaisesRegex(SystemExit, "Marketing version"):
            self.run_check("1.2.4")

    def test_higher_approved_version_blocks_candidate(self):
        with self.assertRaisesRegex(SystemExit, "Marketing version"):
            self.run_check("1.2.6", versions=[version(), version("1.2.7")])

    def test_current_and_legacy_pending_or_removed_states(self):
        for state, legacy in [("READY_FOR_SALE", True), ("PENDING_DEVELOPER_RELEASE", False),
                              ("DEVELOPER_REMOVED_FROM_DISTRIBUTION", False)]:
            with self.subTest(state=state):
                with self.assertRaisesRegex(SystemExit, "Marketing version"):
                    self.run_check("1.2.5", versions=[version(state=state, legacy=legacy)])

    def test_numeric_order_and_open_draft(self):
        self.assertEqual(preflight.numeric_version("1.2"), preflight.numeric_version("1.2.0"))
        floor = preflight.approved_floor([version("1.2.9"), version("1.2.10")])
        self.assertEqual(floor, (1, 2, 10))
        self.run_check("1.2.6", versions=[version(), version("1.3.0", "PREPARE_FOR_SUBMISSION")])

    def test_used_or_lower_build_still_stops(self):
        for highest in ["58", "60"]:
            with self.assertRaisesRegex(SystemExit, "Build must exceed"):
                self.run_check("1.2.6", highest=highest)

    def test_shared_sequence_allows_67_after_66_but_rejects_a_collision(self):
        self.run_check("1.2.7", build="67", highest="66")
        for highest in ["67", "68"]:
            with self.subTest(highest=highest), self.assertRaisesRegex(SystemExit, "Build must exceed"):
                self.run_check("1.2.7", build="67", highest=highest)

    def test_unknown_or_incomplete_metadata_stops_without_echo(self):
        for rows in [[], [version(state="SYNTHETIC_PRIVATE_STATE")],
                     [version("SYNTHETIC_PRIVATE_VERSION")], [{"attributes": {}}]]:
            with self.assertRaises(SystemExit) as caught:
                self.run_check("1.2.6", versions=rows)
            self.assertNotIn("SYNTHETIC_PRIVATE", str(caught.exception))

    def test_pagination_does_not_hide_a_higher_approved_version(self):
        next_url = "https://api.appstoreconnect.apple.com/v1/apps/fixture/appStoreVersions?cursor=2"
        responses = [{"data": [{"id": "fixture-app"}]},
                     {"data": [version()], "links": {"next": next_url}},
                     {"data": [version("1.2.7")]}]
        with patch.object(preflight, "resolve", return_value=("1.2.6", "58")), \
             patch.object(preflight, "make_token", return_value="synthetic"), \
             patch.object(preflight, "get", side_effect=responses) as get:
            with self.assertRaisesRegex(SystemExit, "Marketing version"):
                preflight.check(Path("unused"))
            self.assertEqual(get.call_count, 3)
            self.assertEqual(get.call_args.args[0], next_url)

    def test_inaccessible_or_excessive_metadata_stops(self):
        with patch.object(preflight, "get", side_effect=SystemExit("Apple metadata check failed: HTTP 403")):
            with self.assertRaisesRegex(SystemExit, "HTTP 403"):
                list(preflight.records("https://api.appstoreconnect.apple.com/v1/test", "synthetic"))
        with patch.object(preflight, "get", return_value={"data": [], "links": {"next": "same"}}) as get:
            with self.assertRaisesRegex(SystemExit, "bounded check"):
                list(preflight.records("same", "synthetic"))
            self.assertEqual(get.call_count, 10)

    def test_preflight_precedes_signing_and_compilation(self):
        script = (SCRIPTS / "sign_upload.sh").read_text()
        check = script.index("python3 scripts/release_preflight.py")
        self.assertLess(check, script.index("security create-keychain"))
        self.assertLess(check, script.index("if xcodebuild -project"))


if __name__ == "__main__":
    unittest.main()
