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


if __name__ == "__main__":
    unittest.main()
