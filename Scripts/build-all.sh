#!/bin/zsh
# Build both apps and run the LainKit package tests; exits non-zero on the first failure.
# Takes minutes on a clean checkout, so agents run it in the background. Full logs: build/logs/.
#   Scripts/build-all.sh          # swift test + LainHost (macOS) + LainClient (iOS device build, signed)
#   Scripts/build-all.sh --sim    # also run the LainClient scheme's tests on the iPad simulator
set -euo pipefail
cd "${0:A:h}/.."

SIM_NAME="${LAIN_SIM:-iPad Pro 13-inch (M5)}"
mkdir -p build/logs

# step <label> <command...>: run quietly into build/logs/<label>.log, print a summary.
step() {
  local label=$1; shift
  local out="build/logs/$label.log"
  print -P "%B==> $label%b"
  if "$@" >"$out" 2>&1; then
    grep -E "Test run with|Executed [0-9]+ test|✘" "$out" || true
  else
    grep -E "error:|✘|FAILED|failed" "$out" | head -40 || true
    echo "FAILED: $label (see $out)"
    exit 1
  fi
}
xcb() { xcodebuild -project lain.xcodeproj -derivedDataPath build/DerivedData -allowProvisioningUpdates "$@"; }

[[ -d lain.xcodeproj ]] || Scripts/bootstrap.sh

step swift-test   swift test --package-path Packages/LainKit
step host-build   xcb -scheme LainHost -destination "generic/platform=macOS" build
step client-build xcb -scheme LainClient -destination "generic/platform=iOS" build
if [[ "${1:-}" == "--sim" ]]; then
  step client-sim-test xcb -scheme LainClient -destination "platform=iOS Simulator,name=$SIM_NAME" test
fi
echo "All good."
