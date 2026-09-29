#!/bin/zsh
# Build both apps and run the LainKit package tests; exits non-zero on the first failure.
# Takes minutes on a clean checkout, so agents run it in the background. Full logs: build/logs/.
#   Scripts/build-all.sh          # swift test + LainHost (macOS) + LainClient (iOS device build, signed)
#   Scripts/build-all.sh --sim    # also run the scheme tests: LainHost on the Mac (incl. hosted LainHostTests),
#                                 # LainClient on the iPad simulator (incl. hosted LainClientTests)
set -euo pipefail
cd "${0:A:h}/.."

SIM_NAME="${LAIN_SIM:-iPad Pro 13-inch (M5)}"
mkdir -p build/logs

# descendants <pid>: every process below pid, each before its own children.
descendants() {
  local child
  for child in $(pgrep -P "$1" || true); do
    print "$child"
    descendants "$child"
  done
}

# step <label> <command...>: run quietly into build/logs/<label>.log, print a summary.
step() {
  local label=$1; shift
  local out="build/logs/$label.log" expired="build/logs/$label.timed-out" limit=${LAIN_STEP_TIMEOUT:-900}
  print -P "%B==> $label%b"
  # Watchdog: xcodebuild has been seen to hang after a failed simulator test run (no `timeout` on
  # macOS). After LAIN_STEP_TIMEOUT seconds it ends the step's whole process tree (a hung test runner is
  # a grandchild): TERM, then KILL. The step appends to its log, so its last words can't overwrite the
  # TIMED OUT line.
  rm -f "$expired"; : >"$out"
  "$@" >>"$out" 2>&1 &
  local pid=$! ok=0
  # Detached from stdout: a lingering sleep must not hold the caller's pipe open.
  ( sleep "$limit"
    kill -0 "$pid" 2>/dev/null || exit 0
    tree=("$pid" $(descendants "$pid"))
    touch "$expired"
    echo "TIMED OUT after ${limit}s" >>"$out"
    kill $tree 2>/dev/null || true
    sleep 3
    kill -9 $tree 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
  local watchdog=$!
  wait "$pid" && ok=1
  if [[ -e $expired ]]; then
    wait "$watchdog" 2>/dev/null || true   # let it finish ending the tree
    rm -f "$expired"
  else
    pkill -P "$watchdog" 2>/dev/null || true; kill "$watchdog" 2>/dev/null || true
  fi
  if (( ok )); then
    grep -E "Test run with|Executed [0-9]+ test|✘" "$out" || true
  else
    grep -E "error:|✘|FAILED|failed" "$out" | head -40 || true
    grep "^TIMED OUT after" "$out" || true
    echo "FAILED: $label (see $out)"
    exit 1
  fi
}
xcb() { xcodebuild -project lain.xcodeproj -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration "$@"; }

Scripts/bootstrap.sh --if-stale

step swift-test   swift test --package-path Packages/LainKit
step host-build   xcb -scheme LainHost -destination "generic/platform=macOS" build
step client-build xcb -scheme LainClient -destination "generic/platform=iOS" build
if [[ "${1:-}" == "--sim" ]]; then
  step host-test xcb -scheme LainHost -destination "platform=macOS" test
  step client-sim-test xcb -scheme LainClient -destination "platform=iOS Simulator,name=$SIM_NAME" test
fi
echo "All good."
