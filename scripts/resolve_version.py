"""Validate explicit build inputs; repository run numbers never allocate Apple builds."""
import argparse
import os
from pathlib import Path
import re

def resolve(check_only=False):
    text = Path("project.yml").read_text()
    version = re.search(r'^\s+MARKETING_VERSION: "(\d+\.\d+\.\d+)"$', text, re.M)
    if not version:
        raise SystemExit("Invalid marketing version configuration")
    build = os.environ.get("RELEASE_BUILD_NUMBER", "")
    if not re.fullmatch(r"[1-9][0-9]{0,3}", build):
        raise SystemExit("Build number must be an integer from 1 to 9999")
    flavor = os.environ.get("RELEASE_FLAVOR", "unsigned")
    if flavor not in {"unsigned", "testflight", "appstore"}:
        raise SystemExit("Invalid release flavor")
    if not check_only:
        result, count = re.subn(r'(^\s+CURRENT_PROJECT_VERSION: )"\d+"$',
                               lambda m: m[1] + '"' + build + '"', text, flags=re.M)
        if count != 1:
            raise SystemExit("Expected exactly one build setting")
        Path("project.yml").write_text(result)
    print(f"Validated {flavor}: {version[1]} ({build})")
    return version[1], build

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-only", action="store_true")
    resolve(parser.parse_args().check_only)
