#!/bin/zsh
# Build, install and launch LainClient on a connected iPad, streaming its console here.
# The iPad must be unlocked; watch it for first-run popups (trust, developer app).
#   Scripts/ipad.sh                 # first connected iPad: build, install, launch with the console
#   Scripts/ipad.sh <device>        # this iPad: its UDID (a devicectl name works too when nothing is built)
#   Scripts/ipad.sh --no-build      # install and launch the last build
#   Scripts/ipad.sh --build-only    # build for the iPad; nothing installed
#   Scripts/ipad.sh --install-only  # install the last build without launching it
#   Scripts/ipad.sh --launch-only   # launch the installed app
#   Scripts/ipad.sh --no-console    # launch without streaming the console (returns once lain is launched)
# Options combine, in any order, with a device.
set -euo pipefail
self=${0:A}
cd "${0:A:h}/.."

BUNDLE_ID=sub.dev.lain.client
APP=build/DerivedData/Build/Products/Debug-iphoneos/LainClient.app

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$self"; }
bad_usage() { print -u2 "ipad.sh: $1"; usage >&2; exit 2; }

build=1 install=1 launch=1 console=1 device=
for arg; do
  case $arg in
    --no-build) build=0 ;;
    --build-only) install=0 launch=0 ;;
    --install-only) build=0 launch=0 ;;
    --launch-only) build=0 install=0 ;;
    --no-console) console=0 ;;
    -h|--help) usage; exit 0 ;;
    -*) bad_usage "unknown option $arg" ;;
    *) [[ -z $device ]] || bad_usage "two devices: $device and $arg"; device=$arg ;;
  esac
done
(( build || install || launch )) || bad_usage "those options leave nothing to do"

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
device="${device:-$(first_ipad)}"
[[ -n "$device" ]] || { echo "No connected iPad (pair it, enable Developer Mode, unlock it)."; exit 1; }

if (( build )); then
  Scripts/bootstrap.sh --if-stale
  mkdir -p build/logs
  echo "==> building LainClient (Debug) for $device"
  xcodebuild -project lain.xcodeproj -scheme LainClient -configuration Debug -destination "id=$device" \
    -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
    >build/logs/ipad-build.log 2>&1 ||
    { grep -E "error:" build/logs/ipad-build.log | head -20 || true; echo "build failed (build/logs/ipad-build.log)"; exit 1; }
fi
if (( install )); then
  [[ -d $APP ]] || { echo "No build at $APP: build it first (Scripts/ipad.sh --build-only)."; exit 1; }
  xcrun devicectl device install app --device "$device" "$APP"
fi
if (( launch )); then
  launch_options=(--terminate-existing)
  if (( console )); then launch_options+=(--console); fi
  xcrun devicectl device process launch --device "$device" $launch_options "$BUNDLE_ID"
fi
