#!/bin/bash
set -euo pipefail
read -r XCODE_VERSION XCODEGEN_VERSION ZIP_SHA < <(
  python3 -c 'import json; t=json.load(open("build/toolchain.json")); print(t["xcode"],t["xcodegen"],t["xcodegen_zip_sha256"])'
)
export DEVELOPER_DIR="/Applications/Xcode_$XCODE_VERSION.app/Contents/Developer"
if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "::error::The pinned Xcode installation is unavailable."
  xcodebuild -version
  exit 1
fi
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
echo "DEVELOPER_DIR=$DEVELOPER_DIR" >> "$GITHUB_ENV"
TOOL_DIR="$RUNNER_TEMP/xcodegen-$XCODEGEN_VERSION"
mkdir -p "$TOOL_DIR"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
  -o "$TOOL_DIR/xcodegen.zip"
printf '%s  %s\n' "$ZIP_SHA" "$TOOL_DIR/xcodegen.zip" | shasum -a 256 -c -
ditto -xk "$TOOL_DIR/xcodegen.zip" "$TOOL_DIR/extracted"
BIN=$(find "$TOOL_DIR/extracted" -type f -name xcodegen -print -quit)
test -n "$BIN"
chmod u+x "$BIN"
"$BIN" --version | grep -F "$XCODEGEN_VERSION"
dirname "$BIN" >> "$GITHUB_PATH"
