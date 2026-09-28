#!/bin/zsh
# Build, install and launch Input Lab on a connected iPad, streaming its log to this terminal.
#   ./run.sh            # first available iPad
#   ./run.sh <device>   # devicectl identifier or name
#   ./run.sh pull       # copy Documents/inputlab.log from the iPad into ./logs/
set -euo pipefail
cd "${0:A:h}"
# Device registration in the developer account happens automatically on first build.

mode=run
[[ "${1:-}" == "pull" ]] && { mode=pull; shift; }

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

if [[ "${mode:-}" == "pull" ]]; then
  mkdir -p logs
  out="logs/inputlab-$(date +%Y%m%d-%H%M%S).log"
  xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
    --domain-identifier com.dai.lain.inputlab --source Documents/inputlab.log --destination "$out"
  echo "Saved $out"
  exit 0
fi

[[ -d InputLab.xcodeproj ]] || xcodegen generate
xcodebuild -project InputLab.xcodeproj -scheme InputLab -configuration Debug \
  -destination "id=$device" -derivedDataPath build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build | grep -E "error|BUILD" || true
app=build/Build/Products/Debug-iphoneos/InputLab.app
xcrun devicectl device install app --device "$device" "$app"
xcrun devicectl device process launch --device "$device" --terminate-existing --console com.dai.lain.inputlab
