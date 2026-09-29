#!/bin/zsh
# Offline checks for Scripts/: syntax, usage errors, and the whole flow of each owner script (update-all,
# install-host, ipad, wifi-bench, the build-all watchdog, bootstrap --if-stale) against fakes.
# Nothing here touches the real agent, /Applications, the iPad, Xcode or the network: the scripts run as
# copies in a temporary sandbox with /Applications rewritten into it, and PATH holds only fakes (launchctl,
# osascript, pgrep, pkill, open, ioreg, xcrun, xcodebuild, xcodegen, xcode-select, swift, ditto, codesign)
# and a few plain tools.
#   Scripts/test-scripts.sh             # about 30 s
#   Scripts/test-scripts.sh wifi-bench  # only the checks whose names contain this
set -euo pipefail
cd "${0:A:h}/.."

T=$(mktemp -d "${TMPDIR:-/tmp}/lain-scripts.XXXXXX")
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
only=${1:-} checks=0 failures=0 rc=0 resets=0
check() {   # check <name> <function>: one case
  local name=$1; shift
  [[ $name == *$only* ]] || return 0
  checks=$(( checks + 1 ))
  if "$@"; then
    print "ok    $name"
  else
    failures=$(( failures + 1 ))
    print "FAIL  $name (status $rc)"
    print "  --- output";    sed 's/^/  | /' $T/out.txt 2>/dev/null | tail -25 || true
    print "  --- fake calls"; sed 's/^/  | /' $T/calls.log 2>/dev/null | tail -25 || true
  fi
}

# MARK: syntax
under_test=(bootstrap build-all install-host ipad update-all wifi-bench)
for s in $under_test setup-dev test-scripts; do
  checks=$(( checks + 1 ))
  if zsh -n Scripts/$s.sh; then print "ok    syntax: $s.sh"; else failures=$(( failures + 1 )); print "FAIL  syntax: $s.sh"; fi
done

# MARK: sandbox
mkdir -p $T/bin $T/fast $T/fakes $T/repo/Scripts $T/repo/Apps/Host $T/repo/Apps/Client $T/repo/Packages/LainKit \
  $T/Applications $T/home $T/tmp
touch $T/repo/project.yml
for tool in awk cat chmod cp cut date find grep head id ls mkdir mktemp mv rm sed sleep tail tee touch tr; do
  ln -s "$(command -v $tool)" $T/bin/$tool
done
ln -s "$(python3 -c 'import sys; print(sys.executable)')" $T/bin/python3
for s in $under_test; do
  sed "s|/Applications/|$T/Applications/|g" Scripts/$s.sh >$T/repo/Scripts/$s.sh
  chmod +x $T/repo/Scripts/$s.sh
done
# The copies must not name anything real outside the sandbox (the shebang aside); what they run comes from PATH.
for s in $under_test; do
  if sed "s|$T/||g" $T/repo/Scripts/$s.sh | grep -n -E '(^|[^[:alnum:]_.])/(Applications|usr|bin|sbin|System|Library|opt|private|var|Users)/' |
     grep -v -E '^1:#!/bin/zsh$'; then
    print "the sandbox copy of $s.sh still names the real paths above: not running anything"; exit 1
  fi
done

cat >$T/fakes/lib.zsh <<'EOF'
# Shared by the fakes. `in_sandbox <pid>`: the process descends from the test run (never touch others).
log() { print -r -- "$*" >>$FAKE/calls.log; }
in_sandbox() {
  local p=$1
  while [[ $p == <-> ]] && (( p > 1 )); do
    (( p == FAKE_ROOT )) && return 0
    p=${$(/bin/ps -o ppid= -p $p 2>/dev/null)// /}
  done
  return 1
}
# fails <name>: the state file holds how many more calls fail (a number), or it's absent (none).
fails() {
  local f=$FAKE/state/$1 n
  [[ -e $f ]] || return 1
  n=$(<$f); (( n > 0 )) || return 1
  print $(( n - 1 )) >$f
}
EOF
fake() { { print '#!/bin/zsh'; print 'source $FAKE/fakes/lib.zsh'; cat; } >$T/bin/$1; chmod +x $T/bin/$1; }

# state/lain-running names the running lain instance (reset, then "agent <pid>" or "opened <pid>").
fake launchctl <<'EOF'
log launchctl "$@"
case $1 in
  print) [[ -e $FAKE/state/agent-loaded ]] || exit 113
         if [[ -e $FAKE/state/lain-running ]]; then print "	state = running"; else print "	state = not running"; fi ;;
  kickstart)   # like launchd: a plain kickstart leaves a running lain alone, even one still quitting; -k kills it
    [[ -e $FAKE/state/agent-loaded ]] || exit 113
    ! fails kickstart-fails || exit 1
    [[ ! -e $FAKE/state/lain-running || $2 == -k ]] || exit 0
    [[ ! -e $FAKE/state/lain-running ]] || log "launchd: killed the running lain"
    print "agent $$" >$FAKE/state/lain-running ;;
esac
exit 0
EOF
fake osascript <<'EOF'
log osascript "$@"
if [[ -e $FAKE/state/deny-automation ]]; then
  print -u2 "execution error: Not authorized to send Apple events to lain. (-1743)"; exit 1
fi
case "$*" in
  *" to quit")   # lain quits on its own, in launchd's session: signals to the script's process group miss it
    python3 -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
      $FAKE/bin/lain-quits "$(cat $FAKE/state/lain-running 2>/dev/null)" </dev/null >/dev/null 2>&1 &
    for (( i = 0; i < 250; i++ )); do [[ -e $FAKE/state/quitting ]] && break; sleep 0.02; done
    touch $FAKE/state/quit-sent
    sleep 0.2 ;;   # osascript waits for lain's answer
  *)   # the Automation check: keep what the script had printed when macOS asked
    cp $FAKE/out.txt $FAKE/state/output-when-asked 2>/dev/null || true
    touch $FAKE/state/asked
    if [[ -e $FAKE/state/automation-times-out ]]; then
      print -u2 "execution error: lain got an error: AppleEvent timed out. (-1712)"; exit 1
    fi
    print -u2 "execution error: lain got an error: Can’t get every window. (-1708)"; exit 1 ;;
esac
EOF
fake lain-quits <<'EOF'
# lain (instance $1) quitting: gone after state/quit-delay seconds (default 0.3), unless kickstart -k killed it
# first. Once a later check has reset (another "lain N"), it ends without a trace.
instance=$1 delay=$(cat $FAKE/state/quit-delay 2>/dev/null || print 0.3)
touch $FAKE/state/quitting
current() { cat $FAKE/state/lain-running 2>/dev/null; }
for (( i = 0; i < delay * 20; i++ )); do
  [[ "$(current)" == "$instance" ]] || break
  $FAKE/bin/sleep 0.05
done
if [[ "$(current)" == "$instance" ]]; then rm -f $FAKE/state/lain-running
elif [[ "$(current)" == lain* ]]; then exit 0
fi
touch $FAKE/state/gone
EOF
fake pgrep <<'EOF'
# -P (build-all's process tree) asks the real pgrep, for sandbox processes only; LainHost comes from the state.
if [[ $1 == -P ]]; then in_sandbox $2 && exec /usr/bin/pgrep -P $2; exit 1; fi
[[ -e $FAKE/state/lain-running ]] || exit 1
[[ $1 == -xq ]] || print 4242
EOF
fake pkill <<'EOF'
log pkill "$@"
# -P (build-all's watchdog) goes to the real pkill, for sandbox processes only; nothing else is ever killed.
if [[ $1 == -P ]]; then in_sandbox $2 && exec /usr/bin/pkill -P $2; fi
exit 1
EOF
fake open <<'EOF'
log open "$@"
# A second lain exits at once while one runs (LoginAgent.settleInstance), also while that one is quitting.
[[ -e $FAKE/state/lain-running ]] || print "opened $$" >$FAKE/state/lain-running
EOF
fake ioreg <<'EOF'
print "+-o Root  <class IORegistryEntry>"
[[ ! -e $FAKE/state/ipad-on-usb ]] || print "    | +-o iPad@02210000  <class IOUSBHostDevice>"
EOF
fake xcrun <<'EOF'
log xcrun "$@"
[[ $1 == devicectl ]] || exit 1
case "$2 $3" in
  "list devices")
    devices='[{"hardwareProperties": {"reality": "physical", "deviceType": "iPad", "udid": "FAKE-UDID"},
               "connectionProperties": {"tunnelState": "connected"}}]'
    [[ ! -e $FAKE/state/no-ipad ]] || devices='[]'
    print -r -- "{\"result\": {\"devices\": $devices}}" >${@[-1]} ;;
  "device install") ! fails install-fails ;;
  "device process") ! fails launch-fails ;;
esac
EOF
fake xcodebuild <<'EOF'
log xcodebuild "$@"
scheme= config=Debug
while (( $# )); do
  case $1 in -scheme) scheme=$2; shift ;; -configuration) config=$2; shift ;; esac
  shift
done
if [[ -e $FAKE/state/fail-$scheme ]]; then print "error: fake $scheme build failure"; exit 65; fi
case $scheme in
  LainHost) mkdir -p build/DerivedData/Build/Products/$config/LainHost.app/Contents/MacOS
            print "new $config build" >build/DerivedData/Build/Products/$config/LainHost.app/Contents/MacOS/LainHost ;;
  LainClient) mkdir -p build/DerivedData/Build/Products/$config-iphoneos/LainClient.app ;;
esac
print "** BUILD SUCCEEDED **"
EOF
fake xcodegen <<'EOF'
log xcodegen "$@"
mkdir -p lain.xcodeproj Generated
touch lain.xcodeproj/project.pbxproj
EOF
fake xcode-select <<'EOF'
print /Applications/Xcode.app/Contents/Developer
EOF
fake ditto <<'EOF'
log ditto "$@"
if fails ditto-fails; then mkdir -p "$2/Contents"; print "ditto: $2: No space left on device" >&2; exit 1; fi
cp -R "$1" "$2"
EOF
fake codesign <<'EOF'
log codesign "$@"
! fails codesign-fails
EOF
fake swift <<'EOF'
log swift "$@"
if [[ -e $FAKE/state/swift-hangs ]]; then   # a hung test run: the runner and its child never end
  print $$ >$FAKE/state/swift.pid
  hung-runner &
  wait
fi
print "Test run with 3 tests passed"
EOF
fake hung-runner <<'EOF'
print $$ >$FAKE/state/runner.pid
$FAKE/bin/sleep 120 &   # by its sandbox path, so the harness can tell it from any other sleep
print $! >$FAKE/state/child.pid
wait
EOF
# The installed app's binary doubles as the bench; $FAKE/state/bench says how the run goes.
cat >$T/fakes/LainHost <<'EOF'
#!/bin/zsh
source $FAKE/fakes/lib.zsh
log bench "$@"
[[ $1 == --bench ]] || exit 0
case $(cat $FAKE/state/bench 2>/dev/null || print done) in
  done)
    print "Wi-Fi bench (S9), mode $3: all phases done after 1.0 s (deadline $4 s)"
    print "  raw samples: $HOME/lain-s9-$3-20260101-000000.csv"
    print "  §13: S9 --bench wifi $3 over awdl0 (peer-to-peer); fake numbers" ;;
  fails)
    print "wifi bench failed: fake"; exit 1 ;;
  until-stopped)   # like the bench: Ctrl-C ends the run with what was measured
    stop=0
    trap 'stop=1' INT
    print "bench running"
    touch $FAKE/state/bench-started   # the harness signals from here on
    for (( i = 0; i < 40 && ! stop; i++ )); do sleep 0.05; done
    print "Wi-Fi bench (S9), mode $3: PARTIAL, stopped"
    exit 1 ;;
esac
EOF
chmod +x $T/fakes/LainHost
# A fast `sleep` for flows whose waits are just for people (update-all, install-host).
print '#!/bin/zsh\nexec '"$(command -v sleep)"' 0.02' >$T/fast/sleep; chmod +x $T/fast/sleep

reset() {
  chmod -R u+w $T/Applications 2>/dev/null || true
  rm -rf $T/state $T/calls.log $T/out.txt $T/home/*(N) $T/repo/build $T/Applications/{LainHost.app,.LainHost.app.new,.LainHost.app.old}
  mkdir -p $T/state $T/Applications/LainHost.app/Contents/MacOS
  cp $T/fakes/LainHost $T/Applications/LainHost.app/Contents/MacOS/LainHost
  touch $T/calls.log $T/state/agent-loaded
  resets=$(( resets + 1 )); print "lain $resets" >$T/state/lain-running   # a new instance for each check
}
set_state() { print ${2:-1} >$T/state/$1; }
# run [--fast] <script> <args...>: the sandbox copy against the fakes; output in $T/out.txt, status in $rc.
run() {
  local search=$T/bin
  if [[ $1 == --fast ]]; then search=$T/fast:$T/bin; shift; fi
  local script=$1; shift
  rc=0
  env -i HOME=$T/home TMPDIR=$T/tmp PATH=$search FAKE=$T FAKE_ROOT=$$ LAIN_STEP_TIMEOUT=${step_timeout:-900} \
    LAIN_QUIT_TIMEOUT=${quit_timeout:-30} $T/repo/Scripts/$script "$@" >$T/out.txt 2>&1 </dev/null || rc=$?
}
# run_signal <signal> <when> <script> <args...>: like run, as a terminal's foreground job (its own process
# group) that gets <signal> once <when> holds: seconds, or a state file that exists. "pid:SIG" signals only
# the script itself. Several signals, comma-separated, come 0.3 s apart.
run_signal() {
  local sig=$1 when=$2 script=$3; shift 3
  rc=0
  python3 - $sig $when env -i HOME=$T/home TMPDIR=$T/tmp PATH=$T/bin FAKE=$T FAKE_ROOT=$$ \
    LAIN_QUIT_TIMEOUT=${quit_timeout:-30} $T/repo/Scripts/$script "$@" >$T/out.txt 2>&1 <<'PY' || rc=$?
import os, signal, subprocess, sys, time
sigs, when, cmd = sys.argv[1].split(","), sys.argv[2], sys.argv[3:]
p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, preexec_fn=os.setpgrp)
if when.replace(".", "", 1).isdigit():
    time.sleep(float(when))
else:
    deadline = time.time() + 20
    while not os.path.exists(when) and p.poll() is None and time.time() < deadline:
        time.sleep(0.02)
for i, sig in enumerate(sigs):
    if i:
        time.sleep(0.3)
    if p.poll() is not None:
        break
    number = getattr(signal, "SIG" + sig.split(":")[-1])
    os.kill(p.pid, number) if sig.startswith("pid:") else os.killpg(p.pid, number)
status = p.wait()
sys.exit(status if status >= 0 else 128 - status)
PY
}
has() { grep -q -F -- "$1" $T/out.txt; }
# has_in_order <text...>: the output has these lines (containing each text), in this order.
has_in_order() {
  local line=0 text
  for text; do
    line=$(awk -v start=$line -v text="$text" 'NR > start && index($0, text) { print NR; exit }' $T/out.txt)
    [[ -n $line ]] || { print "  (no output line with '$text' after the ones before it)"; return 1; }
  done
}
called() { grep -q -E -- "$1" $T/calls.log; }
# in_order <pattern...>: fake calls matching each pattern (extended regular expressions), in this order.
in_order() {
  local line=0 pattern
  for pattern; do
    line=$(awk -v start=$line -v pat="$pattern" 'NR > start && $0 ~ pat { print NR; exit }' $T/calls.log)
    [[ -n $line ]] || { print "  (no call matching /$pattern/ after the ones before it)"; return 1; }
  done
}
kickstart='launchctl kickstart -k gui/[0-9]+/sub.dev.lain.host.agent$'
lain_instance() { cat $T/state/lain-running 2>/dev/null; }

# MARK: bootstrap.sh --if-stale
stale_setup() {
  reset
  rm -rf $T/repo/lain.xcodeproj $T/repo/Generated
  run bootstrap.sh --if-stale                    # no project yet: generates it
  touch -t 202601010000 $T/repo/project.yml $T/repo/Apps $T/repo/Apps/*
  touch -t 202601010100 $T/repo/lain.xcodeproj/project.pbxproj
  : >$T/calls.log
}
t_fresh() { stale_setup; run bootstrap.sh --if-stale; (( rc == 0 )) && ! called xcodegen; }
t_missing() { reset; rm -rf $T/repo/lain.xcodeproj; run bootstrap.sh --if-stale; (( rc == 0 )) && called xcodegen; }
t_yml() { stale_setup; touch -t 202601010200 $T/repo/project.yml; run bootstrap.sh --if-stale; called xcodegen; }
t_new_file() { stale_setup; touch $T/repo/Apps/Client/New.swift; run bootstrap.sh --if-stale; called xcodegen; }
t_generated() { stale_setup; rm -rf $T/repo/Generated; run bootstrap.sh --if-stale; called xcodegen; }
t_plain() { stale_setup; run bootstrap.sh; called xcodegen; }
# The build scripts regenerate a project older than project.yml before building (only ipad.sh's build path).
t_regen_host() { stale_setup; touch $T/repo/project.yml; run --fast install-host.sh --build-only; in_order '^xcodegen' '^xcodebuild'; }
t_regen_ipad() { stale_setup; touch $T/repo/project.yml; run ipad.sh --build-only; in_order '^xcodegen' '^xcodebuild'; }
t_regen_ipad_no_build() {
  stale_setup; run ipad.sh --build-only; touch $T/repo/project.yml; : >$T/calls.log
  run ipad.sh --no-build; (( rc == 0 )) && ! called '^xcodegen'
}
t_regen_build_all() { stale_setup; touch $T/repo/project.yml; run build-all.sh; in_order '^xcodegen' '^swift test'; }
check "bootstrap --if-stale: a fresh project is left alone" t_fresh
check "bootstrap --if-stale: generates a missing project" t_missing
check "bootstrap --if-stale: regenerates after project.yml changed" t_yml
check "bootstrap --if-stale: regenerates after a file was added in Apps/" t_new_file
check "bootstrap --if-stale: regenerates without Generated/" t_generated
check "bootstrap: always generates without --if-stale" t_plain
check "install-host: regenerates a stale project before building" t_regen_host
check "ipad: regenerates a stale project before building" t_regen_ipad
check "ipad --no-build: leaves the project alone" t_regen_ipad_no_build
check "build-all: regenerates a stale project first" t_regen_build_all

# MARK: install-host.sh
installed() { [[ "$(<$T/Applications/LainHost.app/Contents/MacOS/LainHost)" == "new Release build" ]]; }
staged() { [[ "$(cat $T/Applications/.LainHost.app.new/Contents/MacOS/LainHost 2>/dev/null)" == "new Release build" ]]; }
no_leftovers() { [[ ! -e $T/Applications/.LainHost.app.new && ! -e $T/Applications/.LainHost.app.old ]]; }
t_host_build_only() {
  reset; run --fast install-host.sh --build-only
  (( rc == 0 )) && called 'xcodebuild .*-scheme LainHost -configuration Release' && has "not installed" &&
    ! called '^(ditto|launchctl|pkill|open)' && ! installed
}
t_host_default() {
  reset; run --fast install-host.sh
  (( rc == 0 )) && installed && has "the agent is running" && no_leftovers &&
    in_order '^xcodebuild ' '^ditto ' "^codesign --verify --deep --strict $T/Applications/.LainHost.app.new$" \
      '^pkill -f /Build/Products/' 'launchctl kickstart -k gui/'
}
t_host_stage() {   # the copy is made and checked next to the app; nothing running changes
  reset; run --fast install-host.sh --build-only; : >$T/calls.log
  run --fast install-host.sh --stage
  (( rc == 0 )) && staged && ! installed && [[ -e $T/state/lain-running ]] &&
    in_order '^ditto ' "^codesign --verify --deep --strict $T/Applications/.LainHost.app.new$" &&
    ! called '^(xcodebuild|launchctl|pkill|open)'
}
t_host_stage_fails() {   # a failed copy or signature check: nothing staged, the app as it was
  local failure
  for failure in ditto-fails codesign-fails; do
    reset; run --fast install-host.sh --build-only; set_state $failure; : >$T/calls.log
    run --fast install-host.sh --stage
    (( rc == 1 )) && has "the installed app is unchanged" && no_leftovers && [[ -e $T/Applications/LainHost.app ]] &&
      ! installed && ! called '^(launchctl|pkill|open)' || { print "  ($failure)"; return 1; }
  done
}
t_host_swap_staged() {   # renames and the restart only: no build, no copy
  reset; run --fast install-host.sh --build-only; run --fast install-host.sh --stage; : >$T/calls.log
  run --fast install-host.sh --swap-staged --no-wait
  (( rc == 0 )) && installed && no_leftovers && has "the agent is starting" &&
    in_order '^pkill -f /Build/Products/' 'launchctl kickstart -k gui/' && ! called '^(xcodebuild|ditto|codesign)'
}
t_host_swap_unstaged() {
  reset; run --fast install-host.sh --swap-staged
  (( rc == 1 )) && has "Nothing staged" && [[ -e $T/Applications/LainHost.app ]] && ! called '^(launchctl|pkill|open)'
}
t_host_old_cleanup_fails() {   # the old app can't be removed: the agent still restarts on the new one
  reset; run --fast install-host.sh --build-only; run --fast install-host.sh --stage
  chmod 555 $T/Applications/LainHost.app/Contents/MacOS   # the app, soon the old one, can't be emptied
  run --fast install-host.sh --swap-staged --no-wait
  (( rc == 0 )) && installed && has "couldn't remove" && called 'launchctl kickstart -k gui/'
}
t_host_no_build() {
  reset; run --fast install-host.sh --build-only; : >$T/calls.log
  run --fast install-host.sh --no-build --no-wait
  (( rc == 0 )) && installed && ! called '^xcodebuild' && called 'launchctl kickstart -k gui/' && has "the agent is starting"
}
t_host_no_build_missing() { reset; run --fast install-host.sh --no-build; (( rc == 1 )) && has "No Release build" && ! called '^ditto'; }
t_host_leftovers() {   # an interrupted run: the app moved aside, a partial copy left behind
  reset; run --fast install-host.sh --build-only
  mv $T/Applications/LainHost.app $T/Applications/.LainHost.app.old
  mkdir -p $T/Applications/.LainHost.app.new/junk
  run --fast install-host.sh --no-build --no-wait
  (( rc == 0 )) && installed && [[ ! -e $T/Applications/LainHost.app/junk && ! -e $T/Applications/LainHost.app/LainHost.app ]] &&
    no_leftovers
}
t_host_not_loaded() {
  reset; rm $T/state/agent-loaded; run --fast install-host.sh --build-only; run --fast install-host.sh --no-build --no-wait
  (( rc == 0 )) && called "^open $T/Applications/LainHost.app$" && ! called 'launchctl kickstart'
}
t_host_build_fails() {
  reset; set_state fail-LainHost; run --fast install-host.sh
  (( rc == 1 )) && has "error: fake LainHost build failure" && has "build failed" && ! called '^(ditto|launchctl)'
}
t_host_uninstall() {
  reset; mkdir -p $T/Applications/.LainHost.app.new; run --fast install-host.sh --uninstall
  (( rc == 0 )) && called '^bench --unregister-agent' && called 'launchctl bootout' && [[ ! -e $T/Applications/LainHost.app ]] &&
    no_leftovers
}
t_host_usage() {
  reset; run install-host.sh --bogus; (( rc == 2 )) || return 1
  run install-host.sh --build-only --no-build; (( rc == 2 )) || return 1
  local bad
  for bad in "--stage --no-wait" "--stage --swap-staged" "--swap-staged --build-only" "--swap-staged --swap-staged"; do
    run install-host.sh ${=bad}; (( rc == 2 )) || { print "  (accepted: '$bad')"; return 1; }
  done
  run install-host.sh --uninstall --no-build; (( rc == 2 )) && [[ ! -s $T/calls.log ]]
}
check "install-host --build-only: builds, installs nothing" t_host_build_only
check "install-host: builds, swaps the app, restarts the agent" t_host_default
check "install-host --no-build --no-wait: installs the last build" t_host_no_build
check "install-host --no-build: refuses without a build" t_host_no_build_missing
check "install-host: recovers from an interrupted install" t_host_leftovers
check "install-host: opens the app when the agent isn't loaded" t_host_not_loaded
check "install-host: a failed build installs nothing" t_host_build_fails
check "install-host --stage: copies and checks the build, nothing running changes" t_host_stage
check "install-host --stage: a failed copy or signature check leaves nothing staged" t_host_stage_fails
check "install-host --swap-staged: renames and restarts, no build or copy" t_host_swap_staged
check "install-host --swap-staged: refuses with nothing staged" t_host_swap_unstaged
check "install-host: a failed cleanup of the old app still restarts the agent" t_host_old_cleanup_fails
check "install-host --uninstall" t_host_uninstall
check "install-host: usage errors" t_host_usage

# MARK: ipad.sh
t_ipad_default() {
  reset; run ipad.sh
  (( rc == 0 )) && in_order 'devicectl list devices' 'xcodebuild .*-scheme LainClient -configuration Debug -destination id=FAKE-UDID' \
    'devicectl device install app --device FAKE-UDID .*/Debug-iphoneos/LainClient.app' \
    'devicectl device process launch --device FAKE-UDID --terminate-existing --console sub.dev.lain.client$'
}
t_ipad_no_console() {
  reset; run ipad.sh --build-only; : >$T/calls.log; run ipad.sh --no-console --no-build
  (( rc == 0 )) && ! called xcodebuild && in_order 'device install app' 'process launch --device FAKE-UDID --terminate-existing sub.dev.lain.client$'
}
t_ipad_build_only() { reset; run ipad.sh --build-only; (( rc == 0 )) && called xcodebuild && ! called 'device (install|process)'; }
t_ipad_install_only() {
  reset; run ipad.sh --build-only; : >$T/calls.log; run ipad.sh --install-only
  (( rc == 0 )) && called 'device install app' && ! called 'process launch' && ! called xcodebuild
}
t_ipad_launch_only() {
  reset; run ipad.sh MY-IPAD --launch-only --no-console
  (( rc == 0 )) && ! called 'list devices' && ! called 'device install' &&
    called 'process launch --device MY-IPAD --terminate-existing sub.dev.lain.client$'
}
t_ipad_none() { reset; set_state no-ipad; run ipad.sh; (( rc == 1 )) && has "No connected iPad" && ! called xcodebuild; }
t_ipad_no_build_missing() { reset; run ipad.sh --no-build; (( rc == 1 )) && has "No build at" && ! called 'device install'; }
t_ipad_build_fails() {
  reset; set_state fail-LainClient; run ipad.sh
  (( rc == 1 )) && has "error: fake LainClient build failure" && has "build failed" && ! called 'device install'
}
t_ipad_print_udid() {
  reset; run ipad.sh --print-udid
  (( rc == 0 )) && [[ "$(<$T/out.txt)" == FAKE-UDID ]] && called 'list devices' && ! called '^xcodebuild' &&
    ! called 'device (install|process)' || return 1
  reset; set_state no-ipad; run ipad.sh --print-udid
  (( rc == 1 )) && has "No connected iPad"
}
t_ipad_usage() {
  reset; run ipad.sh --bogus; (( rc == 2 )) || return 1
  run ipad.sh one two; (( rc == 2 )) || return 1
  run ipad.sh --print-udid --build-only; (( rc == 2 )) || return 1
  run ipad.sh --print-udid MY-IPAD; (( rc == 2 )) || return 1
  run ipad.sh --build-only --launch-only; (( rc == 2 )) && [[ ! -s $T/calls.log ]]
}
check "ipad: builds, installs, launches with the console" t_ipad_default
check "ipad --no-build --no-console" t_ipad_no_console
check "ipad --build-only" t_ipad_build_only
check "ipad --install-only" t_ipad_install_only
check "ipad <device> --launch-only --no-console" t_ipad_launch_only
check "ipad: no connected iPad" t_ipad_none
check "ipad --no-build: refuses without a build" t_ipad_no_build_missing
check "ipad: a failed build installs nothing" t_ipad_build_fails
check "ipad --print-udid: prints the first connected iPad" t_ipad_print_udid
check "ipad: usage errors" t_ipad_usage

# MARK: update-all.sh
# After the iPad app is installed (the point of no return) come only the host's renames and restart, and the
# launch; the device is looked up once, first.
t_update() {
  reset; run --fast update-all.sh
  (( rc == 0 )) && installed && no_leftovers && [[ $(grep -c 'list devices' $T/calls.log) == 1 ]] &&
    in_order 'devicectl list devices' 'xcodebuild .*-scheme LainClient .*-destination id=FAKE-UDID' \
      'xcodebuild .*-scheme LainHost -configuration Release' '^ditto ' '^codesign --verify' \
      'devicectl device install app --device FAKE-UDID' 'launchctl kickstart -k gui/' \
      'process launch --device FAKE-UDID --terminate-existing sub.dev.lain.client$' &&
    has "Done: the host agent runs the new build." && has "lain is running on the iPad."
}
t_update_no_ipad() {
  reset; set_state no-ipad; run --fast update-all.sh
  (( rc == 1 )) && has "No connected iPad" && has "Nothing was installed; lain keeps running." &&
    ! called '^(xcodebuild|ditto|launchctl|pkill|open)' && ! called 'device (install|process)'
}
t_update_device() {
  reset; run --fast update-all.sh MY-IPAD
  (( rc == 0 )) && ! called 'list devices' && called 'destination id=MY-IPAD' && called 'install app --device MY-IPAD' &&
    called 'launch --device MY-IPAD'
}
t_update_client_build_fails() {
  reset; set_state fail-LainClient; run --fast update-all.sh
  (( rc == 1 )) && has "Nothing was installed; lain keeps running." && ! called 'device (install|process)' &&
    ! called '^(ditto|launchctl|pkill|open)' && ! installed
}
t_update_host_build_fails() {
  reset; set_state fail-LainHost; run --fast update-all.sh
  (( rc == 1 )) && has "Nothing was installed; lain keeps running." && ! called 'device (install|process)' &&
    ! called '^(ditto|launchctl|pkill|open)' && ! installed
}
t_update_install_fails() {   # the host was only staged: nothing running on the Mac changed
  reset; set_state install-fails 99; run --fast update-all.sh
  (( rc == 1 )) && [[ $(grep -c 'device install app' $T/calls.log) == 3 ]] && called 'process launch' &&
    has "Nothing on the Mac changed." && called '^ditto ' && ! called '^(launchctl|pkill|open)' && ! installed
}
t_update_install_retried() {
  reset; set_state install-fails 1; run --fast update-all.sh
  (( rc == 0 )) && [[ $(grep -c 'device install app' $T/calls.log) == 2 ]] && installed && has "attempt 1 of 3 failed"
}
t_update_stage_fails() {   # the host copy fails before the iPad app is touched: both old apps stay, the screen stays up
  reset; set_state ditto-fails 1; run --fast update-all.sh
  (( rc == 1 )) && has "Nothing was installed; lain keeps running." && ! called 'device (install|process)' &&
    ! called '^(launchctl|pkill|open)' && ! installed && no_leftovers
}
t_update_host_fails() {   # the host's restart fails after the iPad app is installed: the iPad app is still launched
  reset; set_state kickstart-fails 1; run --fast update-all.sh
  (( rc == 1 )) && in_order 'device install app' 'launchctl kickstart -k gui/' 'process launch' &&
    has "The host couldn't be installed"
}
t_update_launch_fails() {
  reset; set_state launch-fails 99; run --fast update-all.sh
  (( rc == 1 )) && installed && [[ $(grep -c 'process launch' $T/calls.log) == 3 ]] && has "couldn't be launched on the iPad"
}
t_update_cable() {
  reset; run --fast update-all.sh; has "no iPad on USB" || return 1
  reset; set_state ipad-on-usb; run --fast update-all.sh; (( rc == 0 )) && ! has "no iPad on USB"
}
t_update_usage() {
  reset; run update-all.sh --bogus; (( rc == 2 )) || return 1
  run update-all.sh one two; (( rc == 2 )) && [[ ! -s $T/calls.log ]]
}
check "update-all: builds both and stages the host, then iPad app, host swap, launch" t_update
check "update-all <device>: uses it throughout" t_update_device
check "update-all: no connected iPad, nothing built or installed" t_update_no_ipad
check "update-all: iPad build fails, nothing installed" t_update_client_build_fails
check "update-all: host build fails, nothing installed" t_update_host_build_fails
check "update-all: host copy fails, nothing installed" t_update_stage_fails
check "update-all: iPad install fails, relaunches, Mac untouched" t_update_install_fails
check "update-all: a failed iPad install is retried" t_update_install_retried
check "update-all: host install fails, iPad app still launched" t_update_host_fails
check "update-all: launch fails, says to open lain" t_update_launch_fails
check "update-all: notes when the cable is out" t_update_cable
check "update-all: usage errors" t_update_usage

# MARK: wifi-bench.sh
bench_log() { print -l $T/home/lain-s9-*.log(N) | head -1; }
t_bench() {
  reset; run wifi-bench.sh awdl 30 --delay 0
  (( rc == 0 )) && in_order 'osascript -e tell application id "sub.dev.lain.host" to count «class cwin»$' \
    '^pkill -f /Build/Products/' 'osascript -e tell application id "sub.dev.lain.host" to quit$' '^bench --bench wifi awdl 30$' "$kickstart" &&
    has "Raw samples: $T/home/lain-s9-awdl-20260101-000000.csv" && has "§13: S9 --bench wifi awdl" &&
    [[ -n $(bench_log) ]] && grep -q "all phases done" $(bench_log) && has "Results: $(bench_log)"
}
t_bench_fails() {
  reset; set_state bench fails; run wifi-bench.sh lan --delay 0
  (( rc == 1 )) && in_order '^bench --bench wifi lan 180$' "$kickstart"
}
t_bench_ctrl_c() {
  reset; set_state bench until-stopped; run_signal INT $T/state/bench-started wifi-bench.sh any 60 --delay 0
  (( rc == 1 )) && has_in_order "PARTIAL" "lain is starting again" "Results:" && grep -q PARTIAL $(bench_log) &&
    in_order '^bench --bench wifi any 60$' "$kickstart" && [[ $(grep -c 'launchctl kickstart' $T/calls.log) == 1 ]]
}
t_bench_ctrl_c_countdown() {   # Ctrl-C once the Automation check is done, in the countdown
  reset; run_signal INT $T/state/asked wifi-bench.sh awdl --delay 30
  (( rc == 130 )) && has "lain was left running" && ! called 'to quit' && ! called '^bench' && ! called 'launchctl' &&
    [[ -e $T/state/lain-running ]]
}
t_bench_hangup() {
  reset; set_state bench until-stopped; run_signal HUP $T/state/bench-started wifi-bench.sh awdl --delay 0
  (( rc == 129 )) && in_order '^bench --bench wifi awdl 180$' "$kickstart"
}
t_bench_term() {   # only the script gets it: the bench runs to its end, then lain starts
  reset; set_state bench until-stopped; run_signal pid:TERM $T/state/bench-started wifi-bench.sh awdl --delay 0
  (( rc == 143 )) && has_in_order "PARTIAL" "lain is starting again" && in_order '^bench --bench wifi awdl 180$' "$kickstart"
}
t_bench_denied() {
  reset; set_state deny-automation; run wifi-bench.sh awdl --delay 0
  (( rc == 1 )) && has "Terminal may not control lain" && ! has "unplug" && ! called 'to quit' && ! called '^bench' &&
    ! called launchctl
}
t_bench_asks_first() {   # macOS asks about Automation before the steps say to take the screen away
  reset; run wifi-bench.sh awdl 30 --delay 0
  (( rc == 0 )) && grep -q "checking that Terminal may quit lain" $T/state/output-when-asked &&
    ! grep -q "unplug" $T/state/output-when-asked &&
    has_in_order "checking that Terminal may quit lain" "During the countdown below:" "unplug the USB-C cable" \
      "keep your hands off the iPad's keyboard and trackpad during the run"
}
t_bench_automation_times_out() {   # no answer to macOS's question in time: stop, before any step
  reset; set_state automation-times-out; run wifi-bench.sh awdl --delay 0
  (( rc == 1 )) && has "If macOS is asking whether Terminal may control lain" && ! has "unplug" &&
    ! called 'to quit' && ! called '^bench' && ! called launchctl && [[ "$(lain_instance)" == "lain $resets" ]]
}
t_bench_cable() {
  reset; set_state ipad-on-usb
  ( sleep 1.5; rm -f $T/state/ipad-on-usb ) &
  run wifi-bench.sh awdl --delay 0
  wait
  (( rc == 0 )) && has "still on the cable" && in_order 'to quit' '^bench' "$kickstart"
}
t_bench_not_running() {   # nothing was quit: a plain kickstart, which leaves alone a lain that runs by then
  reset; rm $T/state/lain-running; run wifi-bench.sh lan --delay 0
  (( rc == 0 )) && ! called osascript && in_order '^bench --bench wifi lan 180$' 'launchctl kickstart gui/[0-9]+/' &&
    [[ "$(lain_instance)" == agent* ]]
}
wait_gone() { local i; for (( i = 0; i < 100; i++ )); do [[ -e $T/state/gone ]] && return; sleep 0.05; done; }
# A signal right after lain got the quit, while it is still quitting: lain is started again once it has quit
# (launchd ignores a kickstart while it runs, and doesn't restart a clean quit), not cut short by -k.
bench_signal_while_quitting() {   # <signals> <expected status>
  reset; set_state quit-delay 1.2
  run_signal $1 $T/state/quit-sent wifi-bench.sh awdl --delay 0
  wait_gone
  (( rc == $2 )) && [[ -e $T/state/gone && "$(lain_instance)" == agent* ]] && ! called 'launchd: killed' &&
    in_order 'to quit$' "$kickstart" && ! called '^bench'
}
t_bench_quitting_ctrl_c() { bench_signal_while_quitting INT 130; }
t_bench_quitting_hangup() { bench_signal_while_quitting HUP 129; }
t_bench_quitting_term() { bench_signal_while_quitting pid:TERM 143; }
t_bench_quitting_more_signals() { bench_signal_while_quitting INT,INT,HUP 130; }   # the later ones while it waits
t_bench_quit_stuck() {   # lain hasn't quit in time: no bench beside it, and -k restarts it
  reset; set_state quit-delay 60; quit_timeout=1 run wifi-bench.sh awdl --delay 0
  wait_gone
  (( rc == 1 )) && has "lain is still running" && ! called '^bench' && in_order 'to quit$' "$kickstart" &&
    called 'launchd: killed' && [[ -e $T/state/gone && "$(lain_instance)" == agent* ]]
}
t_bench_not_loaded() {   # no agent: lain is opened instead, once the old one has quit
  reset; rm $T/state/agent-loaded; set_state quit-delay 1.2
  run_signal INT $T/state/quit-sent wifi-bench.sh lan --delay 0
  (( rc == 130 )) && called "^open $T/Applications/LainHost.app$" && [[ "$(lain_instance)" == opened* ]]
}
t_bench_not_installed() {
  reset; rm -rf $T/Applications/LainHost.app; run wifi-bench.sh awdl --delay 0
  (( rc == 1 )) && has "lain isn't installed" && [[ ! -s $T/calls.log ]]
}
t_bench_arguments() {
  reset; run wifi-bench.sh AWDL 90.5 --delay=0; (( rc == 0 )) && called '^bench --bench wifi awdl 90.5$' || return 1
  local bad
  for bad in "" "bogus" "awdl 0" "awdl lan" "awdl 30 40" "awdl --delay" "awdl --delay 1.5" "awdl 30 40x"; do
    reset; run wifi-bench.sh ${=bad}
    (( rc == 2 )) && [[ ! -s $T/calls.log ]] || { print "  (accepted: '$bad')"; return 1; }
  done
  reset; quit_timeout='1x' run wifi-bench.sh awdl --delay 0; (( rc == 2 )) && [[ ! -s $T/calls.log ]]
}
check "wifi-bench: asks Automation, quits lain, benches, starts lain again" t_bench
check "wifi-bench: a failed bench still starts lain again" t_bench_fails
check "wifi-bench: Ctrl-C ends the bench with results, then lain starts" t_bench_ctrl_c
check "wifi-bench: Ctrl-C in the countdown leaves lain alone" t_bench_ctrl_c_countdown
check "wifi-bench: a closed terminal still starts lain again" t_bench_hangup
check "wifi-bench: SIGTERM still starts lain again" t_bench_term
check "wifi-bench: no Automation permission, lain untouched" t_bench_denied
check "wifi-bench: the Automation check comes before the steps" t_bench_asks_first
check "wifi-bench: Automation check timed out, stops before the steps" t_bench_automation_times_out
check "wifi-bench: waits for the cable to come out" t_bench_cable
check "wifi-bench: lain not running, still started afterwards" t_bench_not_running
check "wifi-bench: Ctrl-C while lain quits, started again once it has quit" t_bench_quitting_ctrl_c
check "wifi-bench: a closed terminal while lain quits, started again once it has quit" t_bench_quitting_hangup
check "wifi-bench: SIGTERM while lain quits, started again once it has quit" t_bench_quitting_term
check "wifi-bench: more signals while it waits for lain to quit don't stop the restart" t_bench_quitting_more_signals
check "wifi-bench: lain doesn't quit in time, restarted with -k" t_bench_quit_stuck
check "wifi-bench: no agent loaded, lain opened once it has quit" t_bench_not_loaded
check "wifi-bench: refuses without an installed lain" t_bench_not_installed
check "wifi-bench: arguments" t_bench_arguments

# MARK: build-all.sh
t_build_all() { reset; run build-all.sh; (( rc == 0 )) && has "All good." && has "Test run with 3 tests passed"; }
t_build_all_fails() {
  reset; set_state fail-LainHost; run build-all.sh
  (( rc == 1 )) && has "error: fake LainHost build failure" && has "FAILED: host-build" && ! has "TIMED OUT"
}
t_build_all_timeout() {
  reset; set_state swift-hangs; step_timeout=3 run build-all.sh
  local p survived=0 pids=($(cat $T/state/{swift,runner,child}.pid 2>/dev/null))
  for p in $pids; do   # a survivor still runs a sandbox file (a reused pid wouldn't)
    if [[ "$(ps -o command= -p $p 2>/dev/null)" == *$T/bin/* ]]; then
      print "  (pid $p survived the timeout)"; kill -9 $p; survived=1
    fi
  done
  (( rc == 1 )) && has "TIMED OUT after 3s" && has "FAILED: swift-test" && (( ${#pids} == 3 && ! survived ))
}
check "build-all: runs every step" t_build_all
check "build-all: a failing step says FAILED" t_build_all_fails
check "build-all: a hung step times out, says so, and its whole tree ends" t_build_all_timeout

print "$checks checks, $failures failed"
(( failures == 0 ))
