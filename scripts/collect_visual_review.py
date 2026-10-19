"""Export real xcresult screenshots, including extensionless XCTest attachments.

Only PNG/JPEG image bytes from the isolated synthetic-media simulator are retained.
Test failures are reported in the job log; raw UI hierarchies and recordings are not uploaded.
"""
import json
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
    count = 0
    for source in sorted(raw.rglob("*")):
        if not source.is_file():
            continue
        with source.open("rb") as stream:
            signature = stream.read(8)
        extension = ".png" if signature == b"\x89PNG\r\n\x1a\n" else ".jpg" if signature.startswith(b"\xff\xd8\xff") else None
        if extension:
            name = source.relative_to(raw).with_suffix("").as_posix().replace("/", "__")
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


if __name__ == "__main__":
    bundle, destination = map(Path, sys.argv[1:3])
    count = collect(bundle, destination)
    if "--require-complete" in sys.argv[3:] and count < 8:
        raise SystemExit("Visual review requires all eight real app screenshots per flavor")
