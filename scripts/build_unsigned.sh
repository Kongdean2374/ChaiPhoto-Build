#!/bin/bash
set -euo pipefail
python3 scripts/verify_public_tree.py
python3 scripts/resolve_version.py
xcodegen generate
python3 scripts/verify_public_tree.py --project
xcodebuild -project ChaiPhoto.xcodeproj -scheme ChaiPhoto \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$RUNNER_TEMP/ChaiPhoto-DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' clean build
APP="$RUNNER_TEMP/ChaiPhoto-DerivedData/Build/Products/Release-iphoneos/ChaiPhoto.app"
test -d "$APP"
python3 scripts/validate_release.py "$APP" --flavor unsigned
VERSION=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' "$APP/Info.plist")
OUT="$RUNNER_TEMP/ChaiPhoto-unsigned"
mkdir -p "$OUT/Payload"
ditto "$APP" "$OUT/Payload/ChaiPhoto.app"
IPA="$OUT/ChaiPhoto-$VERSION-$RELEASE_BUILD_NUMBER-unsigned.ipa"
(cd "$OUT" && zip -qry "$IPA" Payload)
python3 scripts/validate_release.py "$APP" --flavor unsigned --ipa "$IPA"
TAG="unsigned-v$VERSION-b$RELEASE_BUILD_NUMBER-${GITHUB_SHA:0:12}"
echo "IPA_PATH=$IPA" >> "$GITHUB_ENV"
echo "RELEASE_TAG=$TAG" >> "$GITHUB_ENV"
