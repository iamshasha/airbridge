#!/bin/bash
# Builds AirBridge for a connected iPhone/iPad, installs it, and launches it.
# Usage: scripts/install-ios-device.sh <TEAM_ID> [device-udid]
#
# Free (Personal Team) accounts can't use App Groups, so pass FREE=1 to build without them;
# the share extension then keeps its own identity. Free accounts also allow only 3 sideloaded apps per device.
set -euo pipefail
cd "$(dirname "$0")/../iOS"
TEAM=${1:?team id, e.g. from Xcode › Settings › Accounts}
DEVICE=${2:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i; exit}')}
[ -n "$DEVICE" ] || { echo "No connected device found"; exit 1; }
DD=$(mktemp -d)
EXTRA=()
[ "${FREE:-0}" = 1 ] && EXTRA+=(CODE_SIGN_ENTITLEMENTS=)
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge -destination "id=$DEVICE" -configuration Release \
  -derivedDataPath "$DD" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" "${EXTRA[@]}" build -quiet
xcrun devicectl device install app --device "$DEVICE" "$DD/Build/Products/Release-iphoneos/AirBridge.app"
xcrun devicectl device process launch --device "$DEVICE" app.airbridge.ios || \
  echo "If launch is refused: on the device, Settings › General › VPN & Device Management › trust your developer certificate."
