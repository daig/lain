#!/bin/zsh
# Install a development build of the lain host on this Mac, from the working tree as it is (uncommitted changes
# and all), without publishing anything: the testing counterpart of Scripts/release-mac-host.sh.
#
# The build is signed the way a release is: a Release archive exported with Developer ID
# (Scripts/release/ExportOptions-DeveloperID.plist). It is not notarized, not put in a disk image and not
# uploaded. The signature is the point: macOS ties the login agent's registration and the permissions (Screen
# Recording, Accessibility) to the app's signature, and the host on a Mac is normally installed from a release's
# disk image. Replacing that with a build signed with Apple Development (what this script did before releases
# existed) left the login agent unable to start (launchd: "spawn failed", EX_CONFIG) and the Screen Recording
# grant stuck. So this script:
#   - signs with Developer ID, and refuses to install over a host that is signed differently;
#   - leaves no second LainHost.app with that signature on the Mac (the export and the archive are removed once
#     the copy is staged, the old app once the new one runs);
#   - keeps the old app until the new one's agent is running, and puts it back if it isn't.
#
#   Scripts/install-host.sh               # build, install or update, (re)start the agent, check that it runs
#   Scripts/install-host.sh --build-only  # build only: nothing installed, the running agent untouched
#   Scripts/install-host.sh --no-build    # install the last build (e.g. after --build-only)
#   Scripts/install-host.sh --no-wait     # don't wait to see whether the agent came up (for update-all.sh);
#                                         # the old app is then removed without that check
#   Scripts/install-host.sh --stage       # copy the last build next to the app and check it; nothing running
#                                         # changes (update-all.sh, before the screen goes dark)
#   Scripts/install-host.sh --swap-staged # the staged copy becomes the app (two renames); the agent restarts
#                                         # (update-all.sh, after the iPad app); takes --no-wait
#   Scripts/install-host.sh --uninstall   # unregister the agent, quit, remove the app
# The version is the installed host's (else the newest mac-host-v* tag's), and the build number is
# <commits>.<yymmdd>.<hhmm>: above that commit's release, below the next commit's, and plainly not a release.
# Needs what a release needs (RELEASING.md): the team's Developer ID certificate, local or cloud-managed.
# Restarting the agent ends the iPad session for a moment. Since protocol v3 the iPad app may be one
# version behind (ARCHITECTURE §7.5, D31): the session comes back at its version. Further behind (or a
# v1–v2 app) it stays down until the iPad app is updated too: on a headless Mac use Scripts/update-all.sh.
set -euo pipefail
self=${0:A}
cd "${0:A:h}/.."

APP=/Applications/LainHost.app
NEW=/Applications/.LainHost.app.new
OLD=/Applications/.LainHost.app.old
OUT=build/dev-host
ARCHIVE=$OUT/LainHost.xcarchive
EXPORT=$OUT/export
SRC=$EXPORT/LainHost.app
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

# signer <app>: who signed it, as "<leaf certificate> / <team>" ("Developer ID Application: … / 8DWR7MSCR6").
# The login agent and the permissions follow this.
signer() {
  local details
  details=$(codesign -dvv "$1" 2>&1) || true
  print -r -- "$(print -r -- "$details" | sed -n 's/^Authority=//p' | head -1) / $(print -r -- "$details" | sed -n 's/^TeamIdentifier=//p' | head -1)"
}

# describe <app>: its version and build, where plutil can read them.
describe() {
  command -v plutil >/dev/null 2>&1 || return 0
  local v b
  v=$(plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2>/dev/null) || return 0
  b=$(plutil -extract CFBundleVersion raw -o - "$1/Contents/Info.plist" 2>/dev/null) || return 0
  print -r -- "$v ($b)"
}

# build_host: a Release archive of the working tree, exported with Developer ID, as a release is.
build_host() {
  Scripts/bootstrap.sh --if-stale
  mkdir -p build/logs
  rm -rf "$ARCHIVE" "$EXPORT"
  local commits version build_number
  commits=$(git rev-list --count HEAD 2>/dev/null) || commits=0
  # The installed host's version, so that a development build never reads as an older lain than the one it
  # replaces; without one, the last release tagged here.
  version=
  if [[ -d "$APP" ]] && command -v plutil >/dev/null 2>&1; then
    version=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null) || version=
  fi
  [[ -n $version ]] || version=$(git describe --tags --match 'mac-host-v*' --abbrev=0 2>/dev/null | sed 's/^mac-host-v//') || true
  [[ $version =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || version=0.0
  build_number="$commits.$(date +%y%m%d).$(date +%H%M)"
  echo "==> building Release $version ($build_number) from the working tree"
  xcodebuild -project lain.xcodeproj -scheme LainHost -configuration Release -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE" -derivedDataPath build/DerivedData -allowProvisioningUpdates \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" archive >build/logs/install-host.log 2>&1 ||
    { grep -E "error:" build/logs/install-host.log | head -20 || true; echo "build failed (build/logs/install-host.log)"; exit 1; }
  echo "==> exporting with Developer ID"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -allowProvisioningUpdates \
    -exportOptionsPlist Scripts/release/ExportOptions-DeveloperID.plist >build/logs/install-host-export.log 2>&1 ||
    { grep -E "error:" build/logs/install-host-export.log | head -20 || true
      echo "export failed (build/logs/install-host-export.log): is there a Developer ID Application certificate?" \
        "(Xcode › Settings › Accounts › Manage Certificates)"; rm -rf "$ARCHIVE" "$EXPORT"; exit 1; }
  rm -rf "$ARCHIVE"   # only the export is needed from here
  if ! codesign --verify --deep --strict "$SRC" || [[ "$(signer "$SRC")" != "Developer ID Application"* ]]; then
    echo "The export isn't a valid Developer ID build (signed by: $(signer "$SRC")); nothing is installed."
    rm -rf "$EXPORT"
    exit 1
  fi
}

# stage_copy: the copy that becomes the app, made and checked while nothing running changes, so whatever can
# fail for want of space or permissions, for a bad copy or for the wrong signature, fails here.
stage_copy() {
  [[ -d $SRC ]] || { echo "No Release build at $SRC: build it first (Scripts/install-host.sh --build-only)."; exit 1; }
  # Rerunnable: an interrupted install may have left the app moved aside, or a partial copy.
  [[ ! -d "$APP" && -d "$OLD" ]] && mv "$OLD" "$APP"
  rm -rf "$NEW" "$OLD"
  # Look before overwriting: what is installed, and whether this build may replace it.
  if [[ -d "$APP" ]]; then
    local installed_by built_by
    installed_by=$(signer "$APP") built_by=$(signer "$SRC")
    echo "==> installed: LainHost $(describe "$APP") signed by $installed_by"
    if [[ $installed_by != "$built_by" ]]; then
      echo "This build is signed by $built_by: not the same signature. macOS ties the login agent and the"
      echo "Screen Recording and Accessibility permissions to it, and a host replaced by one signed differently"
      echo "has failed to start before. The installed app is unchanged. To switch on purpose: quit lain,"
      echo "Scripts/install-host.sh --uninstall, install again, and grant the permissions again."
      exit 1
    fi
  fi
  echo "==> copying the build to $NEW"
  if ! ditto "$SRC" "$NEW" || ! codesign --verify --deep --strict "$NEW"; then
    rm -rf "$NEW"
    echo "Couldn't stage the build at $NEW (see above); the installed app is unchanged."
    exit 1
  fi
  # No second copy with this signature stays on the Mac: with one beside the installed app, launchd can fail to
  # resolve the login agent's bundle.
  rm -rf "$EXPORT"
}

agent_runs() { [[ "$(launchctl print "$TARGET" 2>/dev/null)" == *"state = running"* ]]; }

# restart: the agent on the app now in place (or the app itself, which registers the agent, when none is
# loaded). launchctl has been seen to hang on an agent that can't start: it gets 20 s. Fails if launchctl did.
restart() {
  if launchctl print "$TARGET" >/dev/null 2>&1; then
    launchctl kickstart -k "$TARGET" &
    local pid=$! i result=0
    for (( i = 0; i < 100; i++ )); do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || result=$?
    return $result
  else
    pkill -f "$APP/Contents/MacOS/LainHost" 2>/dev/null || true   # an old non-agent copy
    sleep 1
    open "$APP"
  fi
}

# swap_in: the staged copy becomes the app and the agent restarts on it; only renames come before the restart.
# Unless --no-wait, the old app stays aside until the new agent runs, and comes back if it doesn't.
swap_in() {
  [[ -d $NEW ]] || { echo "Nothing staged at $NEW: run Scripts/install-host.sh --stage first."; exit 1; }
  echo "==> installing $APP"
  stop_dev_copies
  local was_loaded=0 had_app=0 i
  launchctl print "$TARGET" >/dev/null 2>&1 && was_loaded=1
  [[ -d "$APP" ]] && { had_app=1; mv "$APP" "$OLD"; }
  mv "$NEW" "$APP"
  if (( was_loaded )); then echo "==> restarting the agent on the new build"; else echo "==> starting (registers Start at Login if needed)"; fi
  local restarted=1
  restart || restarted=0
  if (( ! wait )); then
    (( restarted )) || { echo "launchctl couldn't restart the agent; the previous app is at $OLD."; exit 1; }
    # Best effort: a leftover must not keep the new build from starting.
    rm -rf "$OLD" || echo "(couldn't remove $OLD; the next install removes it)"
    echo "Installed; the agent is starting."
    return 0
  fi
  for (( i = 0; i < 20; i++ )); do agent_runs && break; sleep 0.5; done
  if agent_runs; then
    rm -rf "$OLD" || echo "(couldn't remove $OLD; the next install removes it)"
    echo "Installed; the agent is running (launchd restarts it after a crash; Quit keeps it quit)."
    return 0
  fi
  if (( was_loaded && had_app )); then
    # An update that doesn't start: back to the app that did.
    echo "The new build's agent didn't start:"
    launchctl print "$TARGET" 2>/dev/null | grep -E "job state|last exit code" | sed 's/^[[:space:]]*/  /' || true
    echo "==> putting the previous app back"
    rm -rf "$APP"
    mv "$OLD" "$APP"
    restart || true
    for (( i = 0; i < 20; i++ )); do agent_runs && break; sleep 0.5; done
    if agent_runs; then
      echo "The previous host is running again; nothing else changed. The build's log: build/logs/install-host.log"
    else
      echo "The previous app is back in place but its agent isn't running either. Open $APP, or choose"
      echo "Start at Login in lain's menu; the last release's disk image is in build/release/."
    fi
    exit 1
  fi
  rm -rf "$OLD" 2>/dev/null || true
  echo "Installed, but the agent isn't running yet. If macOS asked, allow lain in"
  echo "System Settings › General › Login Items, or pick Start at Login in the lain menu."
}

if (( uninstall )); then
  [[ -d "$APP" ]] && "$APP/Contents/MacOS/LainHost" --unregister-agent || true
  launchctl bootout "$TARGET" 2>/dev/null || true
  pkill -f "$APP/Contents/MacOS/LainHost" 2>/dev/null || true
  rm -rf "$APP" "$NEW" "$OLD"
  echo "Uninstalled."
  exit 0
fi

if (( build && ! only_stage && ! only_swap )); then build_host; fi
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
