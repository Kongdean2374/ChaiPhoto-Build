"""Validate the private exported IPA, then upload once with Apple's bundled altool.

Only structured codes and fixed labels leave this module. All original output is
captured beneath the signing directory, which sign_upload.sh deletes on exit.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile
from delivery_diagnostics import MAX_LOG_BYTES, summarize


def tail(path):
    with path.open("rb") as stream:
        size = stream.seek(0, 2)
        stream.seek(max(0, size - MAX_LOG_BYTES))
        return stream.read(MAX_LOG_BYTES)


def apple_result(raw):
    """Recognize a success receipt; zero process status alone is insufficient."""
    start = raw.rfind(b"<?xml")
    if start < 0:
        return False, []
    end = raw.find(b"</plist>", start)
    if end < 0:
        return False, []
    try:
        data = plistlib.loads(raw[start:end + len(b"</plist>")])
    except Exception:
        return False, []
    if not isinstance(data, dict):
        return False, []
    errors = data.get("product-errors", [])
    if not isinstance(errors, list):
        return False, []
    codes = set()
    for error in errors:
        if not isinstance(error, dict):
            continue
        code = error.get("code")
        if type(code) in {str, int} and re.fullmatch(r"-?[0-9]{1,6}", str(code)):
            codes.add(int(code))
    # Never return or print the success message: it can contain filenames.
    return bool(isinstance(data.get("success-message"), str) and data["success-message"] and not errors), sorted(codes)[:20]


def private_ipa(work_dir):
    candidates = list((work_dir / "export").glob("*.ipa"))
    if len(candidates) != 1 or candidates[0].is_symlink():
        raise ValueError("Expected one private export")
    ipa = candidates[0]
    dest = work_dir / "ipa-verification"
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip():
            raise ValueError("Corrupt IPA")
        for entry in archive.infolist():
            path = Path(entry.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename:
                raise ValueError("Unsafe IPA path")
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError("Unexpected IPA symlink")
        archive.extractall(dest)
    app = dest / "Payload/ChaiPhoto.app"
    # The same device/flavor/version checks apply to the actual exported binary.
    # Suppress all nested diagnostics; exceptions are classified by the caller.
    result = subprocess.run([
        sys.executable, str(Path(__file__).with_name("validate_release.py")), str(app),
        "--flavor", os.environ["RELEASE_FLAVOR"],
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError("Exported app validation failed")
    return ipa


def upload(work_dir, ipa):
    key_id = os.environ["APP_STORE_CONNECT_KEY_ID"]
    issuer = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    if not re.fullmatch(r"[A-Z0-9]{10}", key_id) or not re.fullmatch(r"[A-Fa-f0-9-]{36}", issuer):
        raise ValueError("Invalid authentication identifiers")
    # Apple's documented key discovery uses AuthKey_<ID>.p8 in private_keys.
    key = work_dir / "private_keys" / ("AuthKey_" + key_id + ".p8")
    if not key.is_file() or key.is_symlink():
        raise ValueError("Missing existing private key")
    child_env = dict(os.environ)
    for name in ("APP_STORE_CONNECT_API_KEY_P8", "BUILD_CERTIFICATE_BASE64",
                 "PROVISIONING_PROFILE_BASE64", "P12_PASSWORD", "KEYCHAIN_PASSWORD"):
        child_env.pop(name, None)
    child_env["API_PRIVATE_KEYS_DIR"] = str(key.parent)
    response = work_dir / "apple-response.plist"
    log = work_dir / "apple-upload.log"
    with response.open("wb") as stdout, log.open("wb") as stderr:
        result = subprocess.run([
            "xcrun", "altool", "--upload-app", "--type", "ios", "--file", str(ipa),
            "--apiKey", key_id, "--apiIssuer", issuer, "--output-format", "xml",
        ], cwd=work_dir, env=child_env, stdout=stdout, stderr=stderr)
    raw = tail(response)
    receipt, codes = apple_result(raw)
    if result.returncode == 0 and receipt:
        print("Delivery stage apple-upload completed (exit=0; structured receipt verified).")
        return 0
    status = result.returncode if 1 <= result.returncode <= 255 else 1
    text = raw.decode("utf-8", errors="replace") + "\n" + tail(log).decode("utf-8", errors="replace")
    report = summarize(text, "apple-upload", status)
    report.update(apple_error_codes=codes, success_receipt_verified=receipt,
                  reported_exit_code=result.returncode if 0 <= result.returncode <= 255 else None)
    print("::error::Apple delivery failed or was not confirmed; no automatic retry.")
    print(json.dumps(report, sort_keys=True))
    return status


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-dir", type=Path, required=True)
    work_dir = parser.parse_args().work_dir.resolve()
    stage = "ipa-validation"
    try:
        ipa = private_ipa(work_dir)
        print("Delivery stage ipa-validation completed (exit=0).")
        stage = "apple-upload"
        print("Delivery stage apple-upload started (one attempt; API-key authentication).", flush=True)
        return upload(work_dir, ipa)
    except (Exception, SystemExit):
        print("::error::Delivery stopped; private exception details withheld.")
        print(json.dumps({"stage": stage, "exit_code": 1, "raw_log_published": False,
                          "signals": ["local-validation-or-tool-invocation"]}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
