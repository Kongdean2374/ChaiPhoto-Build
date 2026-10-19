"""Fail closed on unexpected files, source changes, unsafe project hooks or CI refs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
def fail(message):
    raise SystemExit(message)

def verify(project=False):
    os.chdir(ROOT)
    allow = json.loads(Path("build/public-files.json").read_text())
    expected = set(allow["paths"])
    if (ROOT / ".git").exists():
        raw = subprocess.check_output(["git", "ls-files", "--stage", "-z"])
        files = set()
        for record in raw.decode().split("\0"):
            if not record:
                continue
            meta, path = record.split("\t", 1)
            if meta.split()[0] not in {"100644", "100755"}:
                fail("Unsupported git file mode: " + path)
            files.add(path)
    else:
        files = {p.relative_to(ROOT).as_posix() for p in ROOT.rglob("*") if p.is_file()}
    if files != expected:
        fail("Public file allowlist mismatch: " + repr(sorted(files ^ expected)))
    for path in expected:
        p = ROOT / path
        if p.is_symlink() or not p.is_file():
            fail("Invalid public file: " + path)
        if any(part == ".." for part in Path(path).parts):
            fail("Unsafe path")
        data = p.read_bytes()
        if path.endswith(".png"):
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                fail("Invalid icon")
            continue
        text = data.decode("utf-8")
        patterns = [
            r"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----",
            r"\bgh[pousr]_[A-Za-z0-9]{30,}",
            r"\bgithub_pat_[A-Za-z0-9_]{40,}",
            r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
        ]
        for pattern in patterns:
            if re.search(pattern, text):
                fail("Secret marker found in " + path + " (value omitted)")
        if text.startswith("version https://git-lfs.github.com/spec/"):
            fail("LFS inputs are not allowed")
    manifest = json.loads(Path("build/source-manifest.json").read_text())
    if set(manifest["files"]) != {p for p in expected if p.startswith("ChaiPhoto/")}:
        fail("Source manifest membership mismatch")
    for path, digest in manifest["files"].items():
        if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest:
            fail("Approved source content mismatch: " + path)
    config = Path("project.yml").read_text()
    swift = {p for p in manifest["files"] if p.endswith(".swift")}
    source_paths = re.findall(r"^\s+- path: ([^\n]+)$", config, re.M)
    if len(swift) != 21 or set(source_paths) != swift | {
        "ChaiPhoto/PrivacyInfo.xcprivacy", "ChaiPhoto/Assets.xcassets"
    } or len(source_paths) != len(swift) + 2:
        fail("Explicit project source/resource membership mismatch")
    if re.search(r"preBuildScripts|postBuildScripts|preGenCommand|postGenCommand|^\s*packages:", config, re.M):
        fail("Unapproved project execution hook")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        if os.environ.get("GITHUB_REPOSITORY") != "Kongdean2374/ChaiPhoto-Build":
            fail("Unexpected repository")
        if os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
            fail("Only manual dispatch is accepted")
        if os.environ.get("GITHUB_REF") != "refs/heads/main":
            fail("Only main is accepted")
        actual = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        if actual != os.environ.get("GITHUB_SHA") or actual != os.environ.get("EXPECTED_SHA"):
            fail("Dispatched and checked-out SHA must match the confirmed SHA")
    if project:
        data = json.loads(subprocess.check_output([
            "plutil", "-convert", "json", "-o", "-", "ChaiPhoto.xcodeproj/project.pbxproj"
        ], text=True))
        objects = data["objects"]
        source_names, resource_names = [], []
        for obj in objects.values():
            if obj.get("isa") not in {"PBXSourcesBuildPhase", "PBXResourcesBuildPhase"}:
                continue
            out = source_names if obj["isa"] == "PBXSourcesBuildPhase" else resource_names
            for build_ref in obj.get("files", []):
                file_ref = objects[build_ref].get("fileRef")
                if file_ref:
                    ref = objects[file_ref]
                    out.append(Path(ref.get("path", ref.get("name", ""))).name)
        if sorted(source_names) != sorted(Path(p).name for p in swift):
            fail("Generated Xcode source phase mismatch")
        if sorted(resource_names) != ["Assets.xcassets", "PrivacyInfo.xcprivacy"]:
            fail("Generated Xcode resource phase mismatch")
    print(f"Public snapshot verified: {len(expected)} files, {len(swift)} Swift sources")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", action="store_true")
    verify(parser.parse_args().project)
