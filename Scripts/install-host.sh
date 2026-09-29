#!/bin/zsh
# Install the lain host as a login service (§5.7): a Release build copied to /Applications/LainHost.app,
# whose bundled LaunchAgent (Start at Login) launchd runs at login and restarts after a crash.
#   Scripts/install-host.sh               # build, install or update, (re)start the agent
#   Scripts/install-host.sh --build-only  # build only: nothing installed, the running agent untouched
#   Scripts/install-host.sh --no-build    # install the last Release build (e.g. after --build-only)
#   Scripts/install-host.sh --no-wait     # don't wait to report whether the agent came up (for update-all.sh)
#   Scripts/install-host.sh --stage       # copy the last Release build next to the app and check it; nothing
#                                         # running changes (update-all.sh, before the screen goes dark)
#   Scripts/install-host.sh --swap-staged # the staged copy becomes the app (two renames); the agent restarts
#                                         # (update-all.sh, after the iPad app); takes --no-wait
#   Scripts/install-host.sh --uninstall   # unregister the agent, quit, remove the app
# Grants (Screen Recording, Accessibility) carry over: they follow the signature, not the path.
# Restarting the agent ends the iPad session; after a protocol change it stays down until the iPad app is
# updated too, so on a headless Mac use Scripts/update-all.sh, which updates both back to back.
set -euo pipefail
self=${0:A}
cd "${0:A:h}/.."

APP=/Applications/LainHost.app
NEW=/Applications/.LainHost.app.new
OLD=/Applications/.LainHost.app.old
SRC=build/DerivedData/Build/Products/Release/LainHost.app
LABEL=sub.dev.lain.host.agent
TARGET="gui/$(id -u)/$LABEL"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$self"; }
bad_usage() { print -u2 "install-host.sh: $1"; usage >&2; exit 2; }

build=1 install=1 wait=1 uninstall=0 only_stage=0 only_swap=0
for arg; do
  case $arg in
    --build-only) install=0 ;;
    --no-build) build=0 ;;
    --no-wait) wait=0 ;;
    --stage) only_stage=1 ;;
    --swap-staged) only_swap=1 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) usage; exit 0 ;;
    *) bad_usage "unknown argument $arg" ;;
  esac
done
(( ! uninstall || $# == 1 )) || bad_usage "--uninstall takes no other options"
(( ! only_stage || $# == 1 )) || bad_usage "--stage takes no other options"
(( ! only_swap || $# == 1 + ! wait )) || bad_usage "--swap-staged takes no other options but --no-wait"
(( build || install )) || bad_usage "--build-only and --no-build leave nothing to do"

stop_dev_copies() {
  # Hosts started from build folders would fight the installed one for the iPad.
  pkill -f "/Build/Products/[^/]*/LainHost.app/Contents/MacOS/LainHost" 2>/dev/null || true
}

# stage_copy: the copy that becomes the app, made and checked while nothing running changes, so whatever can
# fail for want of space or permissions, or for a bad copy, fails here.
stage_copy() {
  [[ -d $SRC ]] || { echo "No Release build at $SRC: build it first (Scripts/install-host.sh --build-only)."; exit 1; }
  echo "==> copying the build to $NEW"
  # Rerunnable: an interrupted install may have left the app moved aside, or a partial copy.
  [[ ! -d "$APP" && -d "$OLD" ]] && mv "$OLD" "$APP"
  rm -rf "$NEW" "$OLD"
  if ! ditto "$SRC" "$NEW" || ! codesign --verify --deep --strict "$NEW"; then
    rm -rf "$NEW"
    echo "Couldn't stage the build at $NEW (see above); the installed app is unchanged."
    exit 1
  fi
}

# swap_in: the staged copy becomes the app and the agent restarts on it; only renames come before the restart.
swap_in() {
  [[ -d $NEW ]] || { echo "Nothing staged at $NEW: run Scripts/install-host.sh --stage first."; exit 1; }
  echo "==> installing $APP"
  stop_dev_copies
  [[ -d "$APP" ]] && mv "$APP" "$OLD"
  mv "$NEW" "$APP"
  if launchctl print "$TARGET" >/dev/null 2>&1; then
    echo "==> restarting the agent on the new build"
    launchctl kickstart -k "$TARGET"
  else
    echo "==> starting (registers Start at Login if needed)"
    pkill -f "$APP/Contents/MacOS/LainHost" 2>/dev/null || true   # an old non-agent copy
    sleep 1
    open "$APP"
  fi
  # Only now, and best effort: a leftover must not keep the new build from starting.
  rm -rf "$OLD" || echo "(couldn't remove $OLD; the next install removes it)"
}

if (( uninstall )); then
  [[ -d "$APP" ]] && "$APP/Contents/MacOS/LainHost" --unregister-agent || true
  launchctl bootout "$TARGET" 2>/dev/null || true
  pkill -f "$APP/Contents/MacOS/LainHost" 2>/dev/null || true
  rm -rf "$APP" "$NEW" "$OLD"
  echo "Uninstalled."
  exit 0
fi

if (( build && ! only_stage && ! only_swap )); then
  Scripts/bootstrap.sh --if-stale
  mkdir -p build/logs
  echo "==> building Release"
  xcodebuild -project lain.xcodeproj -scheme LainHost -configuration Release -destination "generic/platform=macOS" \
    -derivedDataPath build/DerivedData -allowProvisioningUpdates build >build/logs/install-host.log 2>&1 ||
    { grep -E "error:" build/logs/install-host.log | head -20 || true; echo "build failed (build/logs/install-host.log)"; exit 1; }
fi
if (( ! install )); then
  echo "Built $SRC (not installed)."
  exit 0
fi
if (( ! only_swap )); then stage_copy; fi
if (( only_stage )); then
  echo "Staged (the installed app is unchanged until --swap-staged)."
  exit 0
fi
swap_in

if (( ! wait )); then
  echo "Installed; the agent is starting."
  exit 0
fi
sleep 3
if [[ "$(launchctl print "$TARGET" 2>/dev/null)" == *"state = running"* ]]; then
  echo "Installed; the agent is running (launchd restarts it after a crash; Quit keeps it quit)."
else
  echo "Installed, but the agent isn't running yet. If macOS asked, allow lain in"
  echo "System Settings › General › Login Items, or pick Start at Login in the lain menu."
fi
