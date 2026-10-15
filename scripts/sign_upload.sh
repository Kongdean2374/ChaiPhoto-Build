#!/bin/bash
# This script is called only by a manually approved environment job.
set -euo pipefail
umask 077
STAGE="validate credentials"
SIGN_DIR=$(mktemp -d "$RUNNER_TEMP/chaiphoto-signing.XXXXXX")
KEYCHAIN_PATH="$SIGN_DIR/signing.keychain-db"
SEARCH_LIST_CHANGED=0
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
  ORIGINAL_KEYCHAINS+=("$keychain")
done < <(security list-keychains -d user | python3 -c 'import sys,shlex; print("\n".join(shlex.split(sys.stdin.read())))')
PROFILE_INSTALLED_PATH=""
LEGACY_PROFILE_INSTALLED_PATH=""
cleanup() {
  result=$?
  trap - EXIT
  set +e
  if [ "$SEARCH_LIST_CHANGED" -eq 1 ]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1
  fi
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1
  [ -z "$PROFILE_INSTALLED_PATH" ] || rm -f "$PROFILE_INSTALLED_PATH"
  [ -z "$LEGACY_PROFILE_INSTALLED_PATH" ] || rm -f "$LEGACY_PROFILE_INSTALLED_PATH"
  rm -rf "$SIGN_DIR"
  if [ "$result" -ne 0 ]; then
    echo "::error::Signed delivery failed during: $STAGE (exit=$result). Raw signing logs are not published."
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
for name in APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_API_KEY_P8 \
  APPLE_TEAM_ID BUILD_CERTIFICATE_BASE64 P12_PASSWORD PROVISIONING_PROFILE_BASE64; do
  if [ -z "${!name:-}" ]; then
    echo "::error::Environment configuration missing: $name"
    exit 1
  fi
done
if [[ ! "$APP_STORE_CONNECT_KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "::error::App Store Connect key identifier has an invalid format."
  exit 1
fi
python3 scripts/resolve_version.py
xcodegen generate
python3 scripts/verify_public_tree.py --project
# Match the key filename used by the existing successful delivery workflow.
mkdir -p "$SIGN_DIR/private_keys"
KEY_PATH="$SIGN_DIR/private_keys/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
printf '%s' "$APP_STORE_CONNECT_API_KEY_P8" > "$KEY_PATH"
printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 -D > "$SIGN_DIR/distribution.p12"
printf '%s' "$PROVISIONING_PROFILE_BASE64" | base64 -D > "$SIGN_DIR/profile.mobileprovision"
chmod 600 "$KEY_PATH" "$SIGN_DIR/distribution.p12" "$SIGN_DIR/profile.mobileprovision"
unset APP_STORE_CONNECT_API_KEY_P8 BUILD_CERTIFICATE_BASE64 PROVISIONING_PROFILE_BASE64
STAGE="Apple app and build preflight"
python3 scripts/release_preflight.py --key-path "$KEY_PATH"
STAGE="distribution keychain preparation"
KEYCHAIN_PASSWORD=$(openssl rand -hex 32)
echo "::add-mask::$KEYCHAIN_PASSWORD"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" > "$SIGN_DIR/keychain.log" 2>&1
security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH" >> "$SIGN_DIR/keychain.log" 2>&1
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >> "$SIGN_DIR/keychain.log" 2>&1
security list-keychains -d user -s "$KEYCHAIN_PATH" "${ORIGINAL_KEYCHAINS[@]}" >> "$SIGN_DIR/keychain.log" 2>&1
SEARCH_LIST_CHANGED=1
security import "$SIGN_DIR/distribution.p12" -P "$P12_PASSWORD" -A -t cert -f pkcs12 \
  -k "$KEYCHAIN_PATH" >> "$SIGN_DIR/keychain.log" 2>&1
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH" >> "$SIGN_DIR/keychain.log" 2>&1
unset P12_PASSWORD KEYCHAIN_PASSWORD
SIGNING_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | awk '/Apple Distribution/ {print $2; exit}')
if [ -z "$SIGNING_IDENTITY" ]; then
  echo "::error::No usable Apple Distribution identity"
  exit 1
fi
security cms -D -i "$SIGN_DIR/profile.mobileprovision" > "$SIGN_DIR/profile.plist"
PROFILE_NAME=$(PROFILE_PLIST="$SIGN_DIR/profile.plist" python3 - <<'PY'
import datetime, os, plistlib
with open(os.environ["PROFILE_PLIST"], "rb") as f:
    profile = plistlib.load(f)
team = os.environ["APPLE_TEAM_ID"]
assert profile["TeamIdentifier"] == [team], "Profile team mismatch"
assert profile["Entitlements"]["application-identifier"] == team + ".tw.chai2374.ChaiPhoto", "Profile app mismatch"
assert not profile["Entitlements"].get("get-task-allow"), "Development profile is not accepted"
assert not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"), "App Store profile required"
assert profile["ExpirationDate"] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), "Profile expired"
print(profile["Name"])
PY
)
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$SIGN_DIR/profile.plist")
echo "::add-mask::$PROFILE_NAME"
echo "::add-mask::$PROFILE_UUID"
PROFILE_INSTALLED_PATH="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
LEGACY_PROFILE_INSTALLED_PATH="$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
mkdir -p "$(dirname "$PROFILE_INSTALLED_PATH")" "$(dirname "$LEGACY_PROFILE_INSTALLED_PATH")"
cp "$SIGN_DIR/profile.mobileprovision" "$PROFILE_INSTALLED_PATH"
cp "$SIGN_DIR/profile.mobileprovision" "$LEGACY_PROFILE_INSTALLED_PATH"
case "$RELEASE_FLAVOR" in
  testflight) CONFIG="Release-TestFlight";;
  appstore) CONFIG="Release-AppStore";;
  *) exit 1;;
esac
STAGE="signed device archive"
if xcodebuild -project ChaiPhoto.xcodeproj -scheme ChaiPhoto -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' -archivePath "$SIGN_DIR/ChaiPhoto.xcarchive" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN_PATH" archive > "$SIGN_DIR/archive.log" 2>&1; then
  echo "Delivery stage archive completed (exit=0)."
else
  result=$?
  python3 scripts/delivery_diagnostics.py --stage archive --exit-code "$result" \
    --log "$SIGN_DIR/archive.log" || echo "::error::Safe archive diagnostic unavailable."
  exit "$result"
fi
APP="$SIGN_DIR/ChaiPhoto.xcarchive/Products/Applications/ChaiPhoto.app"
STAGE="archive metadata and flavor validation"
python3 scripts/validate_release.py "$APP" --flavor "$RELEASE_FLAVOR"
EXPORT_PLIST="$SIGN_DIR/ExportOptions.plist" PROFILE_NAME="$PROFILE_NAME" SIGNING_IDENTITY="$SIGNING_IDENTITY" python3 - <<'PY'
import os, plistlib
with open(os.environ["EXPORT_PLIST"], "wb") as f:
    plistlib.dump({
        "method": "app-store-connect", "destination": "export", "signingStyle": "manual",
        "signingCertificate": os.environ["SIGNING_IDENTITY"],
        "provisioningProfiles": {"tw.chai2374.ChaiPhoto": os.environ["PROFILE_NAME"]},
        "teamID": os.environ["APPLE_TEAM_ID"], "uploadSymbols": True,
        "manageAppVersionAndBuildNumber": False
    }, f)
PY
STAGE="local App Store IPA export"
echo "Delivery stage export started (local manual signing; no upload)."
if xcodebuild -exportArchive -archivePath "$SIGN_DIR/ChaiPhoto.xcarchive" \
  -exportOptionsPlist "$SIGN_DIR/ExportOptions.plist" -exportPath "$SIGN_DIR/export" \
  > "$SIGN_DIR/export.log" 2>&1; then
  echo "Delivery stage export completed (exit=0)."
else
  result=$?
  python3 scripts/delivery_diagnostics.py --stage export --exit-code "$result" \
    --log "$SIGN_DIR/export.log" || echo "::error::Safe export diagnostic unavailable."
  exit "$result"
fi
STAGE="exported IPA validation and Apple upload"
python3 scripts/upload_delivery.py --work-dir "$SIGN_DIR"
echo "Apple upload command completed. Processing, testing availability, review and release require Apple confirmation."
{
  echo "ChaiPhoto $RELEASE_FLAVOR upload command completed."
  echo "Public source commit: $GITHUB_SHA"
  echo "Build: $RELEASE_BUILD_NUMBER"
  echo "No signed IPA, archive or raw signing log was published."
} >> "$GITHUB_STEP_SUMMARY"
