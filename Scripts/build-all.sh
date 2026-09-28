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

# step <label> <command...>: run quietly into build/logs/<label>.log, print a summary.
step() {
  local label=$1; shift
  local out="build/logs/$label.log"
  print -P "%B==> $label%b"
  # Watchdog: xcodebuild has been seen to hang after a failed simulator test run (no `timeout` on
  # macOS). Kill the step after LAIN_STEP_TIMEOUT seconds.
  "$@" >"$out" 2>&1 &
  local pid=$!
  # Detached from stdout: a lingering sleep must not hold the caller's pipe open.
  ( sleep "${LAIN_STEP_TIMEOUT:-900}"; kill "$pid" 2>/dev/null && echo "TIMED OUT after ${LAIN_STEP_TIMEOUT:-900}s" >>"$out" ) \
    </dev/null >/dev/null 2>&1 &
  local watchdog=$!
  if wait "$pid"; then
    pkill -P "$watchdog" 2>/dev/null; kill "$watchdog" 2>/dev/null || true
    grep -E "Test run with|Executed [0-9]+ test|✘" "$out" || true
  else
    pkill -P "$watchdog" 2>/dev/null; kill "$watchdog" 2>/dev/null || true
    grep -E "error:|✘|FAILED|failed|TIMED OUT" "$out" | head -40 || true
    echo "FAILED: $label (see $out)"
    exit 1
  fi
}
xcb() { xcodebuild -project lain.xcodeproj -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration "$@"; }

[[ -d lain.xcodeproj ]] || Scripts/bootstrap.sh

step swift-test   swift test --package-path Packages/LainKit
step host-build   xcb -scheme LainHost -destination "generic/platform=macOS" build
step client-build xcb -scheme LainClient -destination "generic/platform=iOS" build
if [[ "${1:-}" == "--sim" ]]; then
  step host-test xcb -scheme LainHost -destination "platform=macOS" test
  step client-sim-test xcb -scheme LainClient -destination "platform=iOS Simulator,name=$SIM_NAME" test
fi
echo "All good."
