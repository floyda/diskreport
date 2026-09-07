#!/bin/sh
# Assembles build/DiskReport.app from the release build. Ad-hoc signed; no Dock icon (LSUIElement).
set -eu
cd "$(dirname "$0")/.."
BIN="$(swift build -c release --show-bin-path)"
APP="build/DiskReport.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DiskReport" "$APP/Contents/MacOS/DiskReport"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
echo "bundled $APP"
