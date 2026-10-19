"""Build parity is not a channel selector; both channels share Apple's sequence."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'resolve_version.py'
spec = importlib.util.spec_from_file_location('shared_build_resolver', SCRIPT)
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)

class SharedBuildTests(unittest.TestCase):
    def resolve(self, flavor, build, check_only=True):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            try:
                os.chdir(directory)
                project = Path('project.yml')
                project.write_text('    MARKETING_VERSION: "1.2.7"\n    CURRENT_PROJECT_VERSION: "31"\n')
                with patch.dict(os.environ, {'RELEASE_FLAVOR': flavor, 'RELEASE_BUILD_NUMBER': build}, clear=True), contextlib.redirect_stdout(io.StringIO()):
                    result = resolver.resolve(check_only=check_only)
                return result, project.read_text()
            finally:
                os.chdir(previous)

    def test_both_channels_accept_both_parities(self):
        for flavor in ['testflight', 'appstore']:
            for build in ['67', '68']:
                with self.subTest(flavor=flavor, build=build):
                    self.assertEqual(self.resolve(flavor, build)[0], ('1.2.7', build))

    def test_invalid_builds_and_flavors_still_stop(self):
        for value in ['', '0', '-1', '01', '1.2', '10000', '67;echo unsafe']:
            with self.subTest(value=value), self.assertRaises(SystemExit):
                self.resolve('testflight', value)
        with self.assertRaises(SystemExit):
            self.resolve('unknown', '67')

    def test_check_only_does_not_mutate_and_resolve_preserves_marketing(self):
        self.assertIn('CURRENT_PROJECT_VERSION: "31"', self.resolve('testflight', '67')[1])
        result, text = self.resolve('testflight', '67', check_only=False)
        self.assertEqual(result, ('1.2.7', '67'))
        self.assertIn('CURRENT_PROJECT_VERSION: "67"', text)
        self.assertIn('MARKETING_VERSION: "1.2.7"', text)
