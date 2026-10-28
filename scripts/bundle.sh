#!/bin/bash
# Builds AirBridge.app (release) into ./build and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product AirBridge
APP=build/AirBridge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AirBridge "$APP/Contents/MacOS/AirBridge"
# SwiftPM records the deployment target (14.0) as the linked SDK version, and macOS only gives
# Liquid Glass (sidebar, title bar, toolbar) to apps built against the macOS 26+ SDK. Record the real SDK.
vtool -set-build-version macos 14.0 "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/AirBridge" "$APP/Contents/MacOS/AirBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# App icon: render, then build every size macOS wants into an .icns.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png" --mac
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
