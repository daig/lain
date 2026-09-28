#!/bin/zsh
# Generate lain.xcodeproj from project.yml (the only source of project structure).
# Run after cloning and after any change to project.yml or to files in Apps/.
set -euo pipefail
cd "${0:A:h}/.."

if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew or XcodeGen first."; exit 1; }
  brew install xcodegen
  # Homebrew may have switched xcode-select to the Command Line Tools (ARCHITECTURE §12).
fi
[[ "$(xcode-select -p)" == *Xcode*.app/Contents/Developer ]] ||
  echo "warning: xcode-select points at $(xcode-select -p); run: sudo xcode-select -s /Applications/Xcode.app"

xcodegen generate --quiet
echo "Generated lain.xcodeproj"
