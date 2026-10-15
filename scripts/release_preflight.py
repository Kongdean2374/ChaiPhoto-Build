"""Read Apple build metadata after environment approval; never log JWTs or API bodies."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from resolve_version import resolve

APPROVED_STATES = {
    "ACCEPTED", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE", "PENDING_CONTRACT",
    "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION",
    "READY_FOR_SALE", "READY_FOR_DISTRIBUTION",
    "PREORDER_READY_FOR_SALE", "PREORDER_READY_FOR_DISTRIBUTION",
    "DEVELOPER_REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_DISTRIBUTION",
    "REMOVED_FROM_SALE", "REMOVED_FROM_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION",
    "WAITING_FOR_EXPORT_COMPLIANCE",
}
OPEN_STATES = {
    "PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW",
    "INVALID_BINARY", "METADATA_REJECTED", "REJECTED", "DEVELOPER_REJECTED",
}


def numeric_version(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise SystemExit("Unrecognized Apple marketing version; manual review required")
    parts = tuple(int(p) for p in value.split("."))
    return parts + (0,) * (3 - len(parts))


def attributes(item):
    if not isinstance(item, dict) or not isinstance(item.get("attributes"), dict):
        raise SystemExit("Invalid Apple version metadata; upload stopped")
    return item["attributes"]


def approved_floor(versions):
    approved = []
    for item in versions:
        attr = attributes(item)
        if attr.get("platform") != "IOS":
            raise SystemExit("Unexpected Apple version platform; upload stopped")
        version = numeric_version(attr.get("versionString"))
        state = attr.get("appVersionState") or attr.get("appStoreState")
        if state in APPROVED_STATES:
            approved.append(version)
        elif state not in OPEN_STATES:
            raise SystemExit("Unrecognized Apple approval state; manual review required")
    if not approved:
        raise SystemExit("No approved iOS version found for this released app; manual review required")
    return max(approved)


def check_marketing_version(version, versions):
    floor = approved_floor(versions)
    if numeric_version(version) <= floor:
        raise SystemExit("Marketing version must exceed the latest Apple-approved iOS version; its release train is closed")

def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

def der_signature(raw):
    def tlv(offset, tag):
        if offset >= len(raw) or raw[offset] != tag:
            raise ValueError("Invalid ES256 signature")
        n, pos = raw[offset + 1], offset + 2
        if n & 128:
            count = n & 127
            if not 1 <= count <= 2:
                raise ValueError("Invalid signature length")
            n = int.from_bytes(raw[pos:pos + count], "big")
            pos += count
        end = pos + n
        if end > len(raw):
            raise ValueError("Invalid signature")
        return pos, end
    start, end = tlv(0, 0x30)
    r_start, r_end = tlv(start, 0x02)
    s_start, s_end = tlv(r_end, 0x02)
    if end != len(raw) or s_end != end:
        raise ValueError("Invalid signature structure")
    return (int.from_bytes(raw[r_start:r_end], "big").to_bytes(32, "big")
            + int.from_bytes(raw[s_start:s_end], "big").to_bytes(32, "big"))

def make_token(key_path):
    now = int(time.time())
    header = {"alg": "ES256", "kid": os.environ["APP_STORE_CONNECT_KEY_ID"], "typ": "JWT"}
    claims = {"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"],
              "iat": now - 5, "exp": now + 600, "aud": "appstoreconnect-v1"}
    message = (b64(json.dumps(header, separators=(",", ":")).encode()) + "."
               + b64(json.dumps(claims, separators=(",", ":")).encode())).encode()
    result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_path)],
                            input=message, capture_output=True)
    if result.returncode:
        raise SystemExit("App Store Connect JWT signing failed (details withheld)")
    token = message.decode() + "." + b64(der_signature(result.stdout))
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print("::add-mask::" + token, flush=True)
    return token

def get(url, token):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com":
        raise SystemExit("Unexpected Apple pagination endpoint")
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Apple metadata check failed: HTTP {error.code}; verify key permissions")
    except (urllib.error.URLError, TimeoutError):
        raise SystemExit("Apple metadata check unavailable; upload stopped")

def records(url, token):
    for _ in range(10):
        response = get(url, token)
        if not isinstance(response, dict) or not isinstance(response.get("data"), list):
            raise SystemExit("Incomplete Apple metadata; upload stopped")
        yield from response["data"]
        links = response.get("links") or {}
        if not isinstance(links, dict):
            raise SystemExit("Invalid Apple pagination metadata; upload stopped")
        url = links.get("next")
        if not url:
            return
    raise SystemExit("Apple metadata exceeds bounded check; manual review required")


def check(key_path):
    version, build = resolve(check_only=True)
    token = make_token(key_path)
    base = "https://api.appstoreconnect.apple.com/v1/"
    query = urllib.parse.urlencode({"filter[bundleId]": "tw.chai2374.ChaiPhoto", "limit": 2})
    apps = get(base + "apps?" + query, token).get("data", [])
    if len(apps) != 1:
        raise SystemExit("Expected exactly one existing ChaiPhoto Apple app")
    query = urllib.parse.urlencode({"filter[platform]": "IOS", "limit": 200})
    versions = list(records(base + "apps/" + urllib.parse.quote(apps[0]["id"], safe="")
                           + "/appStoreVersions?" + query, token))
    check_marketing_version(version, versions)
    query = urllib.parse.urlencode({"filter[app]": apps[0]["id"], "limit": 200,
                                  "fields[builds]": "version,processingState"})
    highest = 0
    for item in records(base + "builds?" + query, token):
        number = attributes(item).get("version")
        if not isinstance(number, str) or not re.fullmatch(r"[0-9]+", number):
            raise SystemExit("Non-integer Apple build history requires manual review")
        highest = max(highest, int(number))
    if int(build) <= highest:
        raise SystemExit("Build must exceed the existing Apple build sequence")
    print("Apple marketing version and build sequence verified before compilation; cross-repository coordination still required")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-path", type=Path, required=True)
    check(parser.parse_args().key_path)
