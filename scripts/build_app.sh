#!/bin/bash
# Builds "ELC Responsive.app" into ./build using Swift Package Manager.
# Requires Xcode (or the Xcode command line tools) on macOS 13+.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/ELC Responsive.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ELCResponsive" "$APP/Contents/MacOS/ELC Responsive"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Neural genre/mood model (MusiCNN, ISC license) + notices
mkdir -p "$APP/Contents/Resources/Models"
cp Resources/Models/musicnn_msd.bin Resources/Models/musicnn_msd.json Resources/Models/LICENSE-musicnn.md "$APP/Contents/Resources/Models/"

# App icon (generated from scripts/make_icon.swift if available)
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif command -v iconutil >/dev/null 2>&1; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  if swift scripts/make_icon.swift "$ICONSET" >/dev/null 2>&1; then
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || true
  fi
fi

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Built: $APP"
