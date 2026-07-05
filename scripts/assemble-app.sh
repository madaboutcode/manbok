#!/usr/bin/env bash
set -euo pipefail

PRODUCT="ManbokApp"
APP_NAME="Manbok"
BUNDLE_ID="ai.manbok.app"
BUILD_DIR="${1:-.build}"
CONFIG="${2:-release}"

BINARY="${BUILD_DIR}/${CONFIG}/${PRODUCT}"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

if [ ! -f "$BINARY" ]; then
  echo "error: binary not found at ${BINARY}" >&2
  echo "  run: swift build -c ${CONFIG} --product ${PRODUCT}" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BINARY" "${MACOS}/${APP_NAME}"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>manbok</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>manbok keeps a rolling audio buffer so you can save what just happened.</string>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
PLIST

ICONS_DIR="Resources/Icons"
if [ -d "$ICONS_DIR" ]; then
  cp "$ICONS_DIR"/ear-*.png "$RESOURCES/" 2>/dev/null || true
  cp "$ICONS_DIR"/manbok.icns "$RESOURCES/" 2>/dev/null || true
fi

codesign --force --sign - "$APP_BUNDLE"

echo "${APP_BUNDLE}"
