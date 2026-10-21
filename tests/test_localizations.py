"""Resource/schema checks only. Runtime and rendered acceptance run on macOS CI."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("localization_audit", ROOT / "scripts/check_localizations.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class LocalizationResourcesTests(unittest.TestCase):
    def test_every_production_message_has_six_native_resources_with_matching_arguments(self):
        self.assertGreaterEqual(AUDIT.verify(ROOT), 373)

    def test_english_spanish_french_singular_and_safety_meaning_are_present(self):
        for language, singular in [("en", "Delete %lld item"), ("es", "Borrar %lld elemento"), ("fr", "Supprimer %lld élément")]:
            folder = ROOT / "ChaiPhoto/Localization" / (language + ".lproj")
            plurals = plistlib.loads((folder / "Localizable.stringsdict").read_bytes())
            entry = plurals["Delete %lld items || 刪除 %lld 項"]["count"]
            self.assertEqual(entry["one"], singular)
            self.assertNotEqual(entry["one"], entry["other"])
            self.assertEqual(entry["NSStringFormatValueTypeKey"], "lld")
        english = AUDIT.load_strings(ROOT / "ChaiPhoto/Localization/en.lproj/Localizable.strings")
        self.assertIn("actual recovered space may differ", english["Size is estimated from currently readable local resources; actual recovered space may differ. || 容量只依目前可讀取的本機資源估算，實際釋放空間可能不同。"])
        self.assertTrue(any("red asks iOS to confirm deletion" in value for value in english.values()))

    def test_a_missing_translation_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "ChaiPhoto", root / "ChaiPhoto")
            path = root / "ChaiPhoto/Localization/fr.lproj/Localizable.strings"
            lines = path.read_text().splitlines()
            path.write_text("\n".join(lines[:1] + lines[2:]) + "\n")
            with self.assertRaisesRegex(ValueError, "coverage mismatch"):
                AUDIT.verify(root)

    def test_wrong_format_type_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "ChaiPhoto", root / "ChaiPhoto")
            path = root / "ChaiPhoto/Localization/es.lproj/Localizable.stringsdict"
            data = plistlib.loads(path.read_bytes())
            data["Delete %lld items || 刪除 %lld 項"]["count"]["other"] = "Borrar %@ elementos"
            path.write_bytes(plistlib.dumps(data))
            with self.assertRaisesRegex(ValueError, "wrong format arguments"):
                AUDIT.verify(root)


class FlavorArchiveResourcesTests(unittest.TestCase):
    """Offline archive-input and finished-app guard fixtures; not a native archive."""
    @classmethod
    def setUpClass(cls):
        import sys
        sys.path.insert(0, str(ROOT / "scripts"))
        import prepare_release_resources
        import validate_release
        cls.packaging = prepare_release_resources
        cls.release = validate_release

    def fixture(self, base):
        root = base / "reviewed"
        root.mkdir()
        shutil.copytree(ROOT / "ChaiPhoto", root / "ChaiPhoto")
        (root / "ChaiPhoto.xcodeproj").mkdir()
        (root / "ChaiPhoto.xcodeproj/project.pbxproj").write_text("SYNTHETIC_PROJECT_FOR_COPY_TEST_ONLY")
        (root / "unrelated-private-note.txt").write_text("MUST_NOT_BE_STAGED")
        return root

    def snapshot(self, root):
        return {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*") if p.is_file()}

    def test_appstore_removes_only_nine_beta_keys_and_preserves_all_other_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory);root = self.fixture(base);stage = base / "appstore"
            before = self.snapshot(root)
            self.packaging.stage(root, stage, "appstore")
            for code in self.packaging.LANGUAGES:
                relative = f"ChaiPhoto/Localization/{code}.lproj/Localizable.strings"
                original = AUDIT.load_strings(root / relative)
                actual = AUDIT.load_strings(stage / relative)
                self.assertEqual(set(original) - set(actual), self.packaging.BETA_ONLY_KEYS)
                self.assertEqual(actual, {k: v for k, v in original.items() if k not in self.packaging.BETA_ONLY_KEYS})
                # Every retained entry/comment/blank line is copied verbatim, not retranslated/reserialized.
                removed = 0
                kept = []
                for line in before[relative].splitlines(keepends=True):
                    if line.lstrip().startswith(b'"') and json.JSONDecoder().raw_decode(line.lstrip().decode())[0] in self.packaging.BETA_ONLY_KEYS:
                        removed += 1
                    else: kept.append(line)
                self.assertEqual(removed, 9)
                self.assertEqual((stage / relative).read_bytes(), b''.join(kept))
            for path, data in self.snapshot(stage).items():
                if not path.endswith("/Localizable.strings"): self.assertEqual(data, before[path], path)
            self.assertEqual(before, self.snapshot(root), "Reviewed checkout must remain unmodified")
            self.assertFalse((stage / "unrelated-private-note.txt").exists())

    def test_testflight_archive_inputs_keep_every_original_byte_including_beta(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory);root = self.fixture(base);stage = base / "testflight"
            self.packaging.stage(root, stage, "testflight")
            expected = self.snapshot(root)
            expected.pop("unrelated-private-note.txt")
            self.assertEqual(self.snapshot(stage), expected)
            for code in self.packaging.LANGUAGES:
                strings = AUDIT.load_strings(stage / f"ChaiPhoto/Localization/{code}.lproj/Localizable.strings")
                self.assertTrue(self.packaging.BETA_ONLY_KEYS <= strings.keys())

    def test_removed_keys_are_exactly_the_testflight_only_swift_inventory(self):
        # Evaluate only the two existing flavor directives. Unknown directives
        # deliberately fail this test instead of guessing a compiler branch.
        def select(source, enabled):
            stack = [];active = True;result = []
            for line in source.splitlines(keepends=True):
                directive = line.strip()
                if directive.startswith("#if "):
                    condition = directive[4:]
                    self.assertIn(condition, ["CHAIPHOTO_APPSTORE", "CHAIPHOTO_TESTFLIGHT"])
                    matched = condition == enabled
                    stack.append((active, matched));active = active and matched
                elif directive.startswith("#elseif "):
                    condition = directive[8:]
                    self.assertIn(condition, ["CHAIPHOTO_APPSTORE", "CHAIPHOTO_TESTFLIGHT"])
                    parent, taken = stack[-1];matched = condition == enabled
                    active = parent and not taken and matched;stack[-1] = (parent, taken or matched)
                elif directive == "#else":
                    parent, taken = stack[-1];active = parent and not taken;stack[-1] = (parent, True)
                elif directive == "#endif": active = stack.pop()[0]
                elif active: result.append(line)
            self.assertEqual(stack, [])
            return ''.join(result)
        inventories = {}
        with tempfile.TemporaryDirectory() as directory:
            for flavor, flag in [("appstore", "CHAIPHOTO_APPSTORE"), ("testflight", "CHAIPHOTO_TESTFLIGHT")]:
                root = Path(directory) / flavor;(root / "ChaiPhoto").mkdir(parents=True)
                for source in (ROOT / "ChaiPhoto").glob("*.swift"):
                    (root / "ChaiPhoto" / source.name).write_text(select(source.read_text(), flag))
                inventories[flavor] = AUDIT.inventory(root)
        self.assertEqual(inventories["testflight"] - inventories["appstore"], self.packaging.BETA_ONLY_KEYS)
        self.assertTrue(self.packaging.BETA_ONLY_KEYS.isdisjoint(inventories["appstore"]))

    def app_fixture(self, stage, app):
        import struct
        app.mkdir()
        for folder in (stage / "ChaiPhoto/Localization").glob("*.lproj"):
            shutil.copytree(folder, app / folder.name)
            # Exercise the existing whole-app guard on native binary-plist resource bytes too.
            strings = app / folder.name / "Localizable.strings"
            strings.write_bytes(plistlib.dumps(AUDIT.load_strings(strings), fmt=plistlib.FMT_BINARY))
        shutil.copyfile(stage / "ChaiPhoto/PrivacyInfo.xcprivacy", app / "PrivacyInfo.xcprivacy")
        info = {"CFBundleIdentifier": "tw.chai2374.ChaiPhoto", "CFBundleShortVersionString": "1.2.8",
                "CFBundleVersion": "70", "UIDeviceFamily": [1], "CADisableMinimumFrameDurationOnPhone": True,
                "CFBundleSupportedPlatforms": ["iPhoneOS"], "DTPlatformName": "iphoneos",
                "CFBundleExecutable": "ChaiPhoto", "NSPhotoLibraryUsageDescription": "Synthetic permission purpose"}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        (app / "ChaiPhoto").write_bytes(struct.pack("<8I", 0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0)
                                       + struct.pack("<6I", 0x32, 24, 2, 0, 0, 0))
        (app / "Assets.car").write_bytes(b"SYNTHETIC_ASSET_CATALOG_FIXTURE")

    def test_existing_whole_app_guard_accepts_filtered_store_and_original_testflight(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory);root = self.fixture(base)
            for flavor in ["appstore", "testflight"]:
                stage = base / flavor;self.packaging.stage(root, stage, flavor)
                app = base / (flavor + ".app");self.app_fixture(stage, app)
                with patch.object(self.release, "resolve", return_value=("1.2.8", "70")), \
                     patch.object(self.release.subprocess, "check_output", return_value="arm64"):
                    self.assertEqual(self.release.validate(app, flavor), ("1.2.8", "70"))
                    if flavor == "testflight":
                        with self.assertRaisesRegex(SystemExit, "contains Beta distribution content"):
                            self.release.validate(app, "appstore")
                    else:
                        (app / "unrelated-resource.dat").write_bytes(b"Public TestFlight beta")
                        with self.assertRaisesRegex(SystemExit, "contains Beta distribution content"):
                            self.release.validate(app, "appstore")

    def test_staging_rejects_unknown_flavor_or_existing_or_checkout_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory);root = self.fixture(base)
            for destination, flavor in [(base / "unused", "unknown"), (root, "appstore"),
                                        (root / "nested", "appstore"), (base, "appstore")]:
                with self.assertRaises(ValueError): self.packaging.stage(root, destination, flavor)
            source = root / "ChaiPhoto/Localization/en.lproj/Localizable.strings"
            original = source.read_text();source.write_text(original.replace('"Public TestFlight beta || TestFlight 公開測試"', '"Unexpected key"'))
            with self.assertRaisesRegex(ValueError, "Missing expected Beta-only"):
                self.packaging.stage(root, base / "invalid", "appstore")
            self.assertFalse((base / "invalid").exists())

    def test_signing_stages_only_store_after_source_verification_and_before_archive(self):
        script = (ROOT / "scripts/sign_upload.sh").read_text()
        stage = script.index("python3 scripts/prepare_release_resources.py")
        self.assertLess(script.index("python3 scripts/verify_public_tree.py --project"), stage)
        self.assertLess(script.index("python3 scripts/release_preflight.py"), stage)
        self.assertLess(script.index('if [ "$RELEASE_FLAVOR" = appstore ]; then'), stage)
        self.assertLess(stage, script.index('if xcodebuild -project "$ARCHIVE_PROJECT"'))
        self.assertIn('ARCHIVE_PROJECT="ChaiPhoto.xcodeproj"', script)
        self.assertIn('ARCHIVE_PROJECT="$SIGN_DIR/archive-inputs/ChaiPhoto.xcodeproj"', script)
        self.assertIn('python3 scripts/validate_release.py "$APP" --flavor "$RELEASE_FLAVOR"', script)


if __name__ == "__main__":
    unittest.main()
