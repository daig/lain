#!/bin/zsh
# Update lain on the Mac and on the iPad in one go, from Terminal on the lain display. On a headless Mac the
# iPad is the only screen and input, and a host and an iPad app on different protocol versions can't hold a
# session, so this prepares everything first and then swaps both apps back to back:
#   1. finds the iPad, builds the iPad app (Debug, for that iPad) and the host (Release), and copies the host
#      next to the installed one (Scripts/install-host.sh --stage); if any of that fails, nothing is installed
#      and lain keeps running;
#   2. installs the iPad app (the screen goes dark here); if that fails, the iPad's current app is launched
#      again and nothing on the Mac has changed;
#   3. swaps the host copy in and restarts its agent (Scripts/install-host.sh --swap-staged: two renames);
#   4. launches lain on the iPad (no console): the session comes back on the new versions.
# The screen is dark for about 20–40 s: keep the iPad unlocked with lain in front, and the cable plugged in
# (over Wi-Fi alone the session can only come back if both sides already have Local Network access).
# Safe to rerun.
#   Scripts/update-all.sh         # the first connected iPad
#   Scripts/update-all.sh <udid>  # this iPad
set -euo pipefail
self=${0:A}
cd "${0:A:h}/.."

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$self"; }
bad_usage() { print -u2 "update-all.sh: $1"; usage >&2; exit 2; }

device=()
for arg; do
  case $arg in
    -h|--help) usage; exit 0 ;;
    -*) bad_usage "unknown option $arg" ;;
    *) (( ${#device} == 0 )) || bad_usage "two devices: $device and $arg"; device=("$arg") ;;
  esac
done

# retry <attempts> <command...>: device steps can fail once for a passing reason (the device tunnel, a lock).
retry() {
  local attempts=$1 i; shift
  for (( i = 1; i <= attempts; i++ )); do
    "$@" && return 0
    if (( i < attempts )); then echo "   (attempt $i of $attempts failed; trying again in 3 s)"; sleep 3; fi
  done
  return 1
}
nothing_installed() { echo "Nothing was installed; lain keeps running."; exit 1; }

cat <<'EOF'
Updating lain on the Mac and on the iPad.
  - Both apps are built first (a few minutes). If a build fails, nothing is installed and lain keeps running.
  - Then both are swapped back to back: the screen goes dark for about 20–40 s.
    Keep the iPad unlocked with lain in front.
  - Local Network (for Wi-Fi): allow it on the iPad when lain launches; allow it on the Mac once the lain
    display is back (or later in System Settings › Privacy & Security › Local Network).
EOF
if [[ "$(ioreg -p IOUSB -w0)" != *"-o iPad@"* ]]; then
  echo "Note: no iPad on USB. Unless both sides already have Local Network access, plug the cable in first:"
  echo "the session can only come back over Wi-Fi once macOS has allowed it."
fi

# Once the iPad app is replaced, whatever is left must not fail for a reason found only then: one device for
# every step, looked up now, and a host copy that is made and checked now.
if (( ${#device} == 0 )); then
  udid=$(Scripts/ipad.sh --print-udid) && [[ -n $udid ]] || nothing_installed
  device=("$udid")
fi
echo "==> building the iPad app"
Scripts/ipad.sh --build-only $device || nothing_installed
echo "==> building the host"
Scripts/install-host.sh --build-only || nothing_installed
echo "==> staging the host"
Scripts/install-host.sh --stage || nothing_installed

echo "==> both builds done: swapping in 5 s (the screen goes dark for about 20–40 s; Ctrl-C now cancels)"
sleep 5

echo "==> installing lain on the iPad"
if ! retry 3 Scripts/ipad.sh --install-only $device; then
  echo "The iPad app couldn't be installed: launching the iPad's current app again. Nothing on the Mac changed."
  retry 3 Scripts/ipad.sh --launch-only --no-console $device || echo "Couldn't launch it either: open lain on the iPad."
  exit 1
fi
echo "==> installing the host"
host=1
Scripts/install-host.sh --swap-staged --no-wait || host=0
echo "==> launching lain on the iPad"
launched=1
retry 3 Scripts/ipad.sh --launch-only --no-console $device || launched=0

echo
if (( ! host )); then
  echo "The host couldn't be installed (see above), so the Mac may still run the previous one: run this again."
elif [[ "$(launchctl print "gui/$(id -u)/sub.dev.lain.host.agent" 2>/dev/null)" == *"state = running"* ]]; then
  echo "Done: the host agent runs the new build."
else
  echo "The host is installed, but its agent isn't running yet. If macOS asked, allow lain in"
  echo "System Settings › General › Login Items, or pick Start at Login in the lain menu."
fi
if (( launched )); then
  echo "lain is running on the iPad."
else
  echo "lain couldn't be launched on the iPad: unlock it and open lain."
fi
cat <<'EOF'
Local Network (for Wi-Fi):
  - iPad: Allow in the prompt that came up as lain launched (or Settings › Privacy & Security › Local Network).
  - Mac: Allow in lain's prompt on this display (or System Settings › Privacy & Security › Local Network).
EOF
(( host && launched ))
