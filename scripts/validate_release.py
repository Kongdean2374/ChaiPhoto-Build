"""Validate a real device app and its public unsigned IPA without third-party packages."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import zipfile
from resolve_version import resolve

def validate(app, flavor):
    version, build = resolve(check_only=True)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    required = {
        "CFBundleIdentifier": "tw.chai2374.ChaiPhoto",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "UIDeviceFamily": [1],
        "CADisableMinimumFrameDurationOnPhone": True,
    }
    for key, value in required.items():
        if info.get(key) != value:
            raise SystemExit("App metadata mismatch: " + key)
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"] or info.get("DTPlatformName") != "iphoneos":
        raise SystemExit("Not an iPhoneOS device app")
    if not info.get("NSPhotoLibraryUsageDescription"):
        raise SystemExit("Missing Photos permission description")
    name = info.get("CFBundleExecutable", "")
    if not name or Path(name).name != name:
        raise SystemExit("Invalid executable name")
    binary = app / name
    arches = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True).strip()
    if arches != "arm64":
        raise SystemExit("Expected a device ARM64 executable")
    raw = binary.read_bytes()
    if raw[:4] != b"\xcf\xfa\xed\xfe" or len(raw) < 32:
        raise SystemExit("Expected a 64-bit Mach-O executable")
    header = struct.unpack_from("<8I", raw)
    if header[1] != 0x0100000c or header[3] != 2:
        raise SystemExit("Expected an ARM64 Mach-O executable")
    offset, platforms = 32, []
    for _ in range(header[4]):
        command, size = struct.unpack_from("<II", raw, offset)
        if size < 8 or offset + size > len(raw):
            raise SystemExit("Invalid Mach-O load command")
        if command == 0x32:
            platforms.append(struct.unpack_from("<I", raw, offset + 8)[0])
        offset += size
    if platforms != [2]:
        raise SystemExit("Executable must target iOS, not the simulator")
    privacy = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
    if not any(t.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults"
               and "CA92.1" in t.get("NSPrivacyAccessedAPITypeReasons", [])
               for t in privacy.get("NSPrivacyAccessedAPITypes", [])):
        raise SystemExit("Missing expected privacy manifest")
    if not (app / "Assets.car").is_file():
        raise SystemExit("Missing compiled asset catalog")
    if flavor == "unsigned" and ((app / "embedded.mobileprovision").exists() or (app / "_CodeSignature").exists()):
        raise SystemExit("Unsigned app contains signing material")
    for p in app.rglob("*"):
        if p.is_file() and (p.suffix in {".p8", ".p12"} or ".keychain" in p.name):
            raise SystemExit("Credential file inside app")
        if flavor == "appstore" and p.is_file():
            content = p.read_bytes()
            if any(s in content for s in [
                b"testflight.apple.com/join", b"Public TestFlight beta",
                b"A new ChaiPhoto beta is available", b"free public beta"
            ]):
                raise SystemExit("App Store app contains Beta distribution content")
    print(f"Validated iPhoneOS ARM64 {flavor} app: {version} ({build})")
    return version, build

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--flavor", required=True, choices=["unsigned", "testflight", "appstore"])
    parser.add_argument("--ipa", type=Path)
    args = parser.parse_args()
    version, build = validate(args.app, args.flavor)
    if args.ipa:
        with zipfile.ZipFile(args.ipa) as archive:
            if archive.testzip():
                raise SystemExit("IPA ZIP corruption")
            names = archive.namelist()
            if any(not n.startswith("Payload/") or ".." in Path(n).parts for n in names):
                raise SystemExit("Invalid IPA layout")
            if f"Payload/ChaiPhoto.app/{args.app.name.removesuffix('.app')}" not in names:
                raise SystemExit("IPA executable missing")
            if "Payload/ChaiPhoto.app/Info.plist" not in names:
                raise SystemExit("IPA metadata missing")
        digest = hashlib.sha256(args.ipa.read_bytes()).hexdigest()
        args.ipa.with_suffix(".ipa.sha256").write_text(f"{digest}  {args.ipa.name}\n")
        summary = {
            "version": version, "build": build, "flavor": args.flavor,
            "commit": os.environ["GITHUB_SHA"], "run_id": os.environ["GITHUB_RUN_ID"],
            "ipa": args.ipa.name, "bytes": args.ipa.stat().st_size, "sha256": digest,
            "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
            "xcodegen": subprocess.check_output(["xcodegen", "--version"], text=True).strip(),
        }
        args.ipa.with_suffix(".build-info.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary))
