#!/bin/zsh
# Generate lain.xcodeproj from project.yml (the only source of project structure).
# Run after cloning and after any change to project.yml or to files in Apps/.
#   Scripts/bootstrap.sh             # generate
#   Scripts/bootstrap.sh --if-stale  # only if the project is missing or older than project.yml or than a folder
#                                    # in Apps/ (a file added, removed or renamed); the build scripts run this
set -euo pipefail
cd "${0:A:h}/.."

# XcodeGen rewrites project.pbxproj on every run, so a generated project is newer than its inputs.
if [[ "${1:-}" == "--if-stale" && -f lain.xcodeproj/project.pbxproj && -d Generated ]] &&
   [[ -z "$(find project.yml Apps \( -name project.yml -o -type d \) -newer lain.xcodeproj/project.pbxproj -print -quit)" ]]; then
  exit 0
fi

if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew or XcodeGen first."; exit 1; }
  brew install xcodegen
  # Homebrew may have switched xcode-select to the Command Line Tools (ARCHITECTURE §12).
fi
[[ "$(xcode-select -p)" == *Xcode*.app/Contents/Developer ]] ||
  echo "warning: xcode-select points at $(xcode-select -p); run: sudo xcode-select -s /Applications/Xcode.app"

xcodegen generate --quiet
echo "Generated lain.xcodeproj"
