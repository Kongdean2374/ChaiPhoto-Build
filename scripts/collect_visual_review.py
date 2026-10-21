"""Export real xcresult screenshots, including extensionless XCTest attachments.

Only PNG/JPEG image bytes from the isolated synthetic-media simulator are retained.
Test failures are reported in the job log; raw UI hierarchies and recordings are not uploaded.
"""
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys


def collect(bundle, destination):
    summary_error = None
    try:
        summary = subprocess.check_output([
            "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)
        ], text=True)
        result = json.loads(summary)
        fields = ("title", "result", "passedTests", "failedTests", "skippedTests", "testFailures")
        print("XCTest result:", json.dumps({k: result[k] for k in fields if k in result}, ensure_ascii=False))
    except (subprocess.CalledProcessError, OSError, json.JSONDecodeError) as error:
        summary_error = error
        print("XCTest summary unavailable; exporting screenshots independently:", type(error).__name__)
    raw = destination.parent / (destination.name + "-raw")
    raw.mkdir(parents=True, exist_ok=True)
    export_error = None
    try:
        subprocess.run([
            "xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(raw)
        ], check=True)
    except (subprocess.CalledProcessError, OSError) as error:
        export_error = error
        print("XCTest export incomplete; retaining any available screenshots:", type(error).__name__)
    destination.mkdir(parents=True, exist_ok=True)
    # Preserve only a sanitized screenshot name, never raw XCTest metadata.
    names = {}
    manifest = raw / "manifest.json"
    if manifest.is_file():
        try:
            def visit(value):
                if isinstance(value, list):
                    for child in value: visit(child)
                elif isinstance(value, dict):
                    filename = value.get("exportedFileName")
                    label = value.get("suggestedHumanReadableName", value.get("name", ""))
                    if isinstance(filename, str) and isinstance(label, str):
                        match = re.search(r"visual-[A-Za-z0-9_-]+", label)
                        if match: names[Path(filename).name] = match.group(0)
                    for child in value.values():
                        if isinstance(child, (list, dict)): visit(child)
            visit(json.loads(manifest.read_text()))
        except (OSError, ValueError):
            print("Screenshot name map unavailable; keeping original image identifiers")
    count = 0
    for source in sorted(raw.rglob("*")):
        if not source.is_file():
            continue
        with source.open("rb") as stream:
            signature = stream.read(8)
        extension = ".png" if signature == b"\x89PNG\r\n\x1a\n" else ".jpg" if signature.startswith(b"\xff\xd8\xff") else None
        if extension:
            name = source.relative_to(raw).with_suffix("").as_posix().replace("/", "__")
            if source.name in names:
                name = names[source.name] + "__" + name
            target = destination / (name + extension)
            shutil.copyfile(source, target)
            print("Retained simulator screenshot:", target.name)
            count += 1
    print(f"{bundle.name}: {count} real screenshot attachment(s)")
    if summary_error is not None:
        raise RuntimeError("XCTest summary failed; screenshot export was still attempted") from summary_error
    if export_error is not None:
        raise RuntimeError("XCTest export failed; available image attachments were retained") from export_error
    return count


def require_screenshots(count, arguments):
    if "--require-quick" in arguments and count < 10:
        raise SystemExit(f"Quick probes require 10 actual screenshots per flavor; retained {count}")
    if "--require-complete" in arguments:
        plan = json.loads((Path(__file__).resolve().parents[1] / "build/visual-pages.json").read_text())
        expected = plan["legacy_screenshots_per_flavor"] + len(plan["languages"]) * len(plan["profiles"]) * len(plan["pages"])
        if count < expected:
            raise SystemExit(f"Six-language visual review requires {expected} actual screenshots per flavor; retained {count}")
    if "--require-layout" in arguments and count < 9:
        raise SystemExit(f"Selected layout requires 9 actual screenshots per flavor; retained {count}")
    if "--require-focused" in arguments:
        plan = json.loads((Path(__file__).resolve().parents[1] / "build/visual-pages.json").read_text())
        expected = plan["legacy_screenshots_per_flavor"] + len(plan["pages"]) + len(plan["languages"]) * len(plan["profiles"]) * len(plan["focused_pages"])
        if count < expected:
            raise SystemExit(f"Impact acceptance requires {expected} actual screenshots per flavor; retained {count}")


def require_named_pages(destination, arguments):
    """Extra screenshots cannot stand in for a missing affected language/page."""
    if not any(flag in arguments for flag in ("--require-focused", "--require-layout")):
        return
    plan = json.loads((Path(__file__).resolve().parents[1] / "build/visual-pages.json").read_text())
    profiles = [f'{language}-{profile["appearance"]}-{profile["textSize"]}'
                for language in plan["languages"] for profile in plan["profiles"]]
    if "--require-layout" in arguments:
        selected = next((value.split("=", 1)[1] for value in arguments if value.startswith("--layout-profile=")), None)
        if selected not in profiles:
            raise SystemExit("A supported --layout-profile is required")
        profiles = [selected]
    required = {f"visual-l128-focused-{profile}-{page}"
                for profile in profiles for page in plan["focused_pages"]}
    if "--require-focused" in arguments:
        required.update(f'visual-l128-{plan["focused_replay_profile"]}-{page}' for page in plan["pages"])
    # xcresult adds _0_<UUID>__<UUID> after the attachment's hyphenated name.
    actual = {path.stem.split("_", 1)[0] for path in destination.iterdir() if path.is_file()}
    missing = sorted(required - actual)
    if missing:
        raise SystemExit("Missing named current-SHA screenshots: " + ", ".join(missing))


if __name__ == "__main__":
    bundle, destination = map(Path, sys.argv[1:3])
    require_screenshots(collect(bundle, destination), sys.argv[3:])
    require_named_pages(destination, sys.argv[3:])
