"""Read Apple build metadata after environment approval; never log JWTs or API bodies."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from resolve_version import resolve

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

def check(key_path):
    _, build = resolve(check_only=True)
    token = make_token(key_path)
    base = "https://api.appstoreconnect.apple.com/v1/"
    query = urllib.parse.urlencode({"filter[bundleId]": "tw.chai2374.ChaiPhoto", "limit": 2})
    apps = get(base + "apps?" + query, token).get("data", [])
    if len(apps) != 1:
        raise SystemExit("Expected exactly one existing ChaiPhoto Apple app")
    query = urllib.parse.urlencode({"filter[app]": apps[0]["id"], "limit": 200,
                                  "fields[builds]": "version,processingState"})
    url = base + "builds?" + query
    highest = 0
    for _ in range(10):
        response = get(url, token)
        for item in response.get("data", []):
            version = item["attributes"]["version"]
            if not version.isdigit():
                raise SystemExit("Non-integer Apple build history requires manual review")
            highest = max(highest, int(version))
        url = response.get("links", {}).get("next")
        if not url:
            break
    else:
        raise SystemExit("Apple build history exceeds bounded check; manual review required")
    if int(build) <= highest:
        raise SystemExit("Build must exceed the existing Apple build sequence")
    print("Existing Apple app and build sequence verified; cross-repository coordination still required")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-path", type=Path, required=True)
    check(parser.parse_args().key_path)
