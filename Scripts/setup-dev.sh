#!/bin/zsh
# One-time (and after every Xcode update) developer setup for lain.
#   - verifies the active developer directory is Xcode 27 (Homebrew/CLT installs can flip it)
#   - exports Xcode's Apple-written agent skills into .claude/skills/ (generated, git-ignored)
# The Xcode MCP server itself is configured by the checked-in .mcp.json (xcrun mcpbridge).
set -euo pipefail
cd "${0:A:h}/.."

fail() { print -u2 "✗ $1"; exit 1; }
ok() { print "✓ $1"; }

# 1. Developer directory must be full Xcode, not the Command Line Tools.
dev=$(xcode-select -p)
[[ "$dev" == *"/Xcode"*".app/Contents/Developer" ]] ||
  fail "xcode-select points at $dev. Fix: sudo xcode-select -s /Applications/Xcode.app"
version=$(xcodebuild -version | head -1)
[[ "$version" == "Xcode 27"* ]] || fail "Expected Xcode 27, found: $version"
ok "$version at $dev"
xcrun -f devicectl >/dev/null && xcrun -f mcpbridge >/dev/null || fail "devicectl/mcpbridge missing from $dev"
ok "devicectl and mcpbridge available"

# 2. Xcode's agent skills — only the ones relevant to lain (see docs/ARCHITECTURE.md §12).
skills=(device-interaction modernize-tests audit-xcode-security-settings uikit-app-modernization swiftui-specialist swiftui-whats-new-27)
plugin=$(xcrun agent plugin path --plugin-format claude 2>/dev/null) || fail "Couldn't locate Xcode's Claude plugin"
mkdir -p .claude/skills
for s in $skills; do
  [[ -d "$plugin/skills/$s" ]] || { print -u2 "  (skill $s not in this Xcode; skipped)"; continue; }
  rm -rf ".claude/skills/$s"
  cp -R "$plugin/skills/$s" ".claude/skills/$s"
done
ok "exported ${#skills} Xcode skills to .claude/skills/ from $plugin"

# 3. Reminder that can't be automated: with Xcode › Settings › Intelligence › External Agent Access set to
#    "Always", the tools work without the Xcode window (the "Xcode Service" helper starts on demand);
#    with "While Xcode is Open", Xcode must be running.
print "i Xcode › Settings › Intelligence › External Agent Access should be \"Always\" (tools work without the Xcode window)."
print "Done. Restart Claude Code in this repo to (re)load the xcode MCP server and skills."
