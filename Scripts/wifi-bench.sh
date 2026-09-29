#!/bin/zsh
# The Wi-Fi bench (S9, LainHost --bench wifi), run from Terminal on the lain display itself. The bench needs
# the cable out and lain quit, which takes away a headless Mac's only screen and input, so this runs unattended:
#   Scripts/wifi-bench.sh awdl            # AWDL: the iPad off the home network with Wi-Fi still on; 180 s
#   Scripts/wifi-bench.sh lan 120         # the home network, through the router; 120 s
#   Scripts/wifi-bench.sh any --delay 60  # whichever path Network.framework picks; 60 s to get ready
# It first checks that Terminal may quit lain (macOS may ask, while this screen is up), then prints what to do
# and waits --delay seconds (default 45) for the cable to come out (and, for awdl, for the iPad to leave the
# home network with the Wi-Fi button in Control Center, which keeps AWDL up). Then it quits lain cleanly
# (launchd doesn't restart a clean quit), runs the installed LainHost --bench wifi <mode> <seconds> with its
# output also in ~/lain-s9-<mode>-<time>.log, and starts lain again: always, also after a failure or Ctrl-C.
set -euo pipefail
self=${0:A}
typeset -F SECONDS

APP=/Applications/LainHost.app
BENCH=$APP/Contents/MacOS/LainHost
BUNDLE_ID=sub.dev.lain.host
TARGET="gui/$(id -u)/sub.dev.lain.host.agent"
# How long lain gets to quit before it's restarted anyway (tests shorten it).
QUIT_TIMEOUT=${LAIN_QUIT_TIMEOUT:-30}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$self"; }
bad_usage() { print -u2 "wifi-bench.sh: $1"; usage >&2; exit 2; }

mode= seconds= delay=45
while (( $# )); do
  case ${1:l} in
    any|awdl|lan) [[ -z $mode ]] || bad_usage "two modes: $mode and $1"; mode=${1:l} ;;
    --delay) (( $# > 1 )) || bad_usage "--delay needs a number of seconds"; delay=$2; shift ;;
    --delay=*) delay=${${1:l}#--delay=} ;;
    -h|--help) usage; exit 0 ;;
    *) [[ $1 =~ '^[0-9]+([.][0-9]+)?$' ]] && (( $1 > 0 )) || bad_usage "unknown argument $1"
       [[ -z $seconds ]] || bad_usage "two durations: $seconds and $1"; seconds=$1 ;;
  esac
  shift
done
seconds=${seconds:-180}
[[ -n $mode ]] || bad_usage "which path: any, awdl or lan?"
[[ $delay =~ '^[0-9]+$' ]] || bad_usage "bad --delay $delay (whole seconds)"
[[ $QUIT_TIMEOUT =~ '^[0-9]+([.][0-9]+)?$' ]] ||
  { print -u2 "wifi-bench.sh: bad LAIN_QUIT_TIMEOUT $QUIT_TIMEOUT (seconds)"; exit 2; }
[[ -x $BENCH ]] || { echo "lain isn't installed at $APP: run Scripts/install-host.sh first."; exit 1; }

log=$HOME/lain-s9-$mode-$(date +%Y%m%d-%H%M%S).log
lain_running() { pgrep -xq LainHost; }
ipad_on_usb() { [[ "$(ioreg -p IOUSB -w0)" == *"-o iPad@"* ]]; }
# tell_lain <AppleScript command>: false only if Terminal may not send lain Apple Events (Automation). lain's
# answer (an error, for most requests) is left in $reply.
reply=
tell_lain() {
  reply=$(osascript -e "tell application id \"$BUNDLE_ID\" to $1" 2>&1) || true
  if [[ $reply == *-1743* ]]; then
    echo "Terminal may not control lain: allow it in System Settings › Privacy & Security › Automation › Terminal,"
    echo "then run this again."
    return 1
  fi
}

echo "Wi-Fi bench, mode $mode, $seconds s."
# Until lain is quit nothing has changed, and Ctrl-C just stops.
trap 'print; echo "Stopped; lain was left running."; exit 130' INT
if lain_running; then
  # The first Apple Event from Terminal to lain makes macOS ask whether Terminal may control it. Ask before
  # the steps below take this screen away, with a request lain doesn't handle (it answers with an error).
  echo "==> checking that Terminal may quit lain (if macOS asks, allow it)"
  tell_lain "count «class cwin»" || exit 1
  if [[ $reply == *-1712* ]]; then   # timed out: typically nobody has answered macOS's question yet
    echo "lain didn't answer in time. If macOS is asking whether Terminal may control lain, answer it; then run"
    echo "this again."
    exit 1
  fi
fi

echo "During the countdown below:"
echo "  - unplug the USB-C cable;"
case $mode in
  awdl) echo "  - on the iPad, tap Wi-Fi off in Control Center: that leaves the home network but keeps AWDL"
        echo "    (not Settings › Wi-Fi or Airplane Mode, which turn the radio off);" ;;
  lan) echo "  - keep the iPad on the home network;" ;;
  any) echo "  - leave Wi-Fi as it is on both sides;" ;;
esac
echo "  - keep lain in front on the iPad, unlocked;"
echo "  - keep your hands off the iPad's keyboard and trackpad during the run (input shares the connection with"
echo "    the measured pings)."
echo "Then lain quits on this Mac, so this screen goes dark, and the bench runs for $seconds s while lain on the"
echo "iPad dials it by itself. Afterwards lain starts again on its own, also if the bench fails, and the iPad"
echo "reconnects over Wi-Fi if it can; otherwise plug the cable back in."
if [[ $mode == awdl ]]; then echo "Then turn the iPad's Wi-Fi back on in Control Center."; fi
echo "Results: $log"

for (( left = delay; left > 0; left-- )); do
  print -n "\r   quitting lain in $left s (Ctrl-C stops) "
  sleep 1
done
(( delay == 0 )) || print
if ipad_on_usb; then
  echo "The iPad is still on the cable: unplug it (waiting up to 5 min; Ctrl-C stops)."
  for (( i = 0; i < 300; i++ )); do
    ipad_on_usb || break
    sleep 1
  done
  if ipad_on_usb; then echo "Still plugged in: stopped; lain was left running."; exit 1; fi
fi

# From here on lain is started again however this ends: the bench finishing or failing, Ctrl-C (the bench
# then stops early with what it measured; a second Ctrl-C stops it at once), or the terminal going away.
armed=1 interrupted=0 quit_sent=0 quit_deadline=0
start_lain() {
  trap '' INT HUP TERM   # nothing stops this any more (what it runs ignores them too)
  (( armed )) || return 0
  armed=0
  local kickstart=(kickstart)
  if (( quit_sent )); then
    # launchd ignores a kickstart while lain is still quitting, and doesn't restart a clean quit: let lain
    # finish (it releases input and removes its display), then -k restarts it, also if it never finished.
    while (( SECONDS < quit_deadline )) && lain_running; do sleep 0.25; done
    kickstart+=(-k)
  fi
  if launchctl $kickstart "$TARGET" 2>/dev/null || open "$APP" 2>/dev/null; then
    echo "==> lain is starting again (launchctl $kickstart $TARGET)" 2>/dev/null || true
  else
    echo "Couldn't start lain again: run  launchctl kickstart -k $TARGET  or open $APP" 2>/dev/null || true
  fi
}
trap start_lain EXIT
trap 'exit 129' HUP
trap 'exit 143' TERM
trap 'interrupted=1' INT

echo "==> quitting lain (this screen goes dark until lain is back)"
# Hosts started from build folders would take the iPad's connection instead of the bench.
pkill -f "/Build/Products/[^/]*/LainHost.app/Contents/MacOS/LainHost" 2>/dev/null || true
if lain_running; then
  # Marked before it's sent: a signal can end this script after lain got the quit, while osascript waits.
  quit_sent=1 quit_deadline=$(( SECONDS + QUIT_TIMEOUT ))
  tell_lain quit || { armed=0; exit 1; }
fi
while (( quit_sent && ! interrupted && SECONDS < quit_deadline )) && lain_running; do sleep 0.25; done
(( ! interrupted )) || exit 130
if lain_running; then
  echo "lain is still running (pid $(pgrep -x LainHost | tr '\n' ' ')): the bench can't run next to it."
  exit 1
fi

echo "==> $BENCH --bench wifi $mode $seconds"
bench_status=0
"$BENCH" --bench wifi "$mode" "$seconds" 2>&1 | tee -i "$log" || bench_status=$?
start_lain

echo "Results: $log"
if [[ -f $log ]]; then
  csv=$(sed -n 's/^  raw samples: //p' "$log" | tail -1)
  summary=$(sed -n 's/^  §13: //p' "$log" | tail -1)
  [[ -z $csv ]] || echo "Raw samples: $csv"
  [[ -z $summary ]] || echo "§13: $summary"
fi
exit $bench_status
