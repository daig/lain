#!/bin/zsh
# Build, install and launch LainClient on a connected iPad, streaming its console here.
# The iPad must be unlocked; watch it for first-run popups (trust, developer app).
#   Scripts/ipad.sh              # first connected iPad
#   Scripts/ipad.sh <device>     # devicectl identifier or name
#   Scripts/ipad.sh --no-build   # install and launch the last build
set -euo pipefail
cd "${0:A:h}/.."

BUNDLE_ID=sub.dev.lain.client
build=1
[[ "${1:-}" == "--no-build" ]] && { build=0; shift; }

# First physical iPad that devicectl can reach (paired, connected), unless one was given.
first_ipad() {
  local json; json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1
  python3 - "$json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and hw.get("deviceType") == "iPad" and conn.get("tunnelState") == "connected":
        print(hw["udid"]); break
PY
  rm -f "$json"
}
device="${1:-$(first_ipad)}"
[[ -n "$device" ]] || { echo "No connected iPad (pair it, enable Developer Mode, unlock it)."; exit 1; }

[[ -d lain.xcodeproj ]] || Scripts/bootstrap.sh
if (( build )); then
  mkdir -p build/logs
  xcodebuild -project lain.xcodeproj -scheme LainClient -configuration Debug -destination "id=$device" \
    -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
    >build/logs/ipad-build.log 2>&1 || { grep -E "error:" build/logs/ipad-build.log | head -20; exit 1; }
fi
app=build/DerivedData/Build/Products/Debug-iphoneos/LainClient.app
xcrun devicectl device install app --device "$device" "$app"
xcrun devicectl device process launch --device "$device" --terminate-existing --console "$BUNDLE_ID"
