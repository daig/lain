#!/bin/zsh
# Install the lain host as a login service (§5.7): a Release build copied to /Applications/LainHost.app,
# whose bundled LaunchAgent (Start at Login) launchd runs at login and restarts after a crash.
#   Scripts/install-host.sh              # build, install or update, (re)start the agent
#   Scripts/install-host.sh --uninstall  # unregister the agent, quit, remove the app
# Grants (Screen Recording, Accessibility) carry over: they follow the signature, not the path.
set -euo pipefail
cd "${0:A:h}/.."

APP=/Applications/LainHost.app
LABEL=sub.dev.lain.host.agent
TARGET="gui/$(id -u)/$LABEL"

stop_dev_copies() {
  # Hosts started from build folders would fight the installed one for the iPad.
  pkill -f "/Build/Products/[^/]*/LainHost.app/Contents/MacOS/LainHost" 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
  [[ -d "$APP" ]] && "$APP/Contents/MacOS/LainHost" --unregister-agent || true
  launchctl bootout "$TARGET" 2>/dev/null || true
  pkill -f "$APP/Contents/MacOS/LainHost" 2>/dev/null || true
  rm -rf "$APP"
  echo "Uninstalled."
  exit 0
fi

[[ -d lain.xcodeproj ]] || Scripts/bootstrap.sh
mkdir -p build/logs
echo "==> building Release"
xcodebuild -project lain.xcodeproj -scheme LainHost -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build >build/logs/install-host.log 2>&1 ||
  { grep -E "error:" build/logs/install-host.log | head -20; echo "build failed (build/logs/install-host.log)"; exit 1; }
SRC=build/DerivedData/Build/Products/Release/LainHost.app

echo "==> installing $APP"
stop_dev_copies
ditto "$SRC" "/Applications/.LainHost.app.new"
[[ -d "$APP" ]] && mv "$APP" "/Applications/.LainHost.app.old"
mv "/Applications/.LainHost.app.new" "$APP"
rm -rf "/Applications/.LainHost.app.old"

if launchctl print "$TARGET" >/dev/null 2>&1; then
  echo "==> restarting the agent on the new build"
  launchctl kickstart -k "$TARGET"
else
  echo "==> starting (registers Start at Login if needed)"
  pkill -f "$APP/Contents/MacOS/LainHost" 2>/dev/null || true   # an old non-agent copy
  sleep 1
  open "$APP"
fi
sleep 3
if launchctl print "$TARGET" 2>/dev/null | grep -q "state = running"; then
  echo "Installed; the agent is running (launchd restarts it after a crash; Quit keeps it quit)."
else
  echo "Installed, but the agent isn't running yet. If macOS asked, allow lain in"
  echo "System Settings › General › Login Items, or pick Start at Login in the lain menu."
fi
