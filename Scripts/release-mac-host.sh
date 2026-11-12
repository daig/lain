#!/bin/zsh
# Build the Mac host for a GitHub release: a Release archive of LainHost, exported with Developer ID, notarized
# by Apple, stapled and zipped. The result opens on any Mac (macOS 27) without Gatekeeper warnings; no App
# Review is involved (notarization is an automated scan). Release steps: RELEASING.md.
#   Scripts/release-mac-host.sh --version 0.2              # build build/release/lain-mac-host-0.2.zip (+ .sha256)
#   Scripts/release-mac-host.sh --version 0.2 --upload TAG # and attach both to the GitHub release TAG (gh)
#   Scripts/release-mac-host.sh --version 0.2 --no-notarize # signed only, for a dry run of the signing
# Options: --build N (CFBundleVersion; default: the commit count), --notary-profile NAME (default lain-notary).
# One-time setup (RELEASING.md): a "Developer ID Application" certificate (Xcode › Settings › Accounts ›
# Manage Certificates), and notarytool credentials in the Keychain:
#   xcrun notarytool store-credentials lain-notary --apple-id <Apple ID> --team-id 8DWR7MSCR6
# (it asks for an app-specific password from account.apple.com).
set -euo pipefail
self=${0:A}
cd "${0:A:h}/.."

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$self"; }
bad_usage() { print -u2 "release-mac-host.sh: $1"; usage >&2; exit 2; }

version="" build_number="" profile=lain-notary upload="" notarize=1
while (( $# )); do
  case $1 in
    --version) version=${2:-}; shift ;;
    --build) build_number=${2:-}; shift ;;
    --notary-profile) profile=${2:-}; shift ;;
    --upload) upload=${2:-}; shift ;;
    --no-notarize) notarize=0 ;;
    -h|--help) usage; exit 0 ;;
    *) bad_usage "unknown argument $1" ;;
  esac
  shift
done
[[ $version =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || bad_usage "--version takes a version like 0.2 or 0.2.1"
build_number=${build_number:-$(git rev-list --count HEAD)}
[[ $build_number =~ '^[0-9]+$' ]] || bad_usage "--build takes a number"
(( notarize || ! ${#upload} )) || bad_usage "--upload needs a notarized build (drop --no-notarize)"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "The tree has uncommitted changes: a release is built from a commit. Commit or stash them first."
  exit 1
fi

OUT=build/release
ARCHIVE=$OUT/LainHost.xcarchive
EXPORT=$OUT/export
APP=$EXPORT/LainHost.app
ZIP=$OUT/lain-mac-host-$version.zip
LOG=$OUT/logs
rm -rf "$ARCHIVE" "$EXPORT" "$ZIP" "$ZIP.sha256"
mkdir -p "$LOG"

Scripts/bootstrap.sh --if-stale
echo "==> archiving LainHost $version ($build_number) at $(git rev-parse --short HEAD)"
xcodebuild -project lain.xcodeproj -scheme LainHost -configuration Release -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" -derivedDataPath build/DerivedData -allowProvisioningUpdates \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" archive >"$LOG/archive.log" 2>&1 ||
  { grep -E "error:" "$LOG/archive.log" | head -20 || true; echo "archive failed ($LOG/archive.log)"; exit 1; }

echo "==> exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -allowProvisioningUpdates \
  -exportOptionsPlist Scripts/release/ExportOptions-DeveloperID.plist >"$LOG/export.log" 2>&1 ||
  { grep -E "error:" "$LOG/export.log" | head -20 || true; echo "export failed ($LOG/export.log): is there a" \
    "Developer ID Application certificate? (Xcode › Settings › Accounts › Manage Certificates)"; exit 1; }

echo "==> checking the signature"
codesign --verify --deep --strict "$APP"
signature=$(codesign -dvv "$APP" 2>&1)
[[ $signature == *"Authority=Developer ID Application"* ]] ||
  { echo "$APP isn't signed with Developer ID:"; echo "$signature" | grep Authority; exit 1; }
[[ $signature == *"runtime"* ]] || { echo "$APP lacks the hardened runtime, which notarization requires"; exit 1; }

if (( notarize )); then
  echo "==> notarizing (usually a few minutes)"
  submission=$OUT/LainHost-notarize.zip
  ditto -c -k --keepParent "$APP" "$submission"
  if ! xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait --output-format json \
      >"$LOG/notarize.json" 2>"$LOG/notarize.err"; then
    cat "$LOG/notarize.err" "$LOG/notarize.json" 2>/dev/null | tail -20
    echo "notarization failed; details: xcrun notarytool log <submission id> --keychain-profile $profile"
    exit 1
  fi
  status=$(plutil -extract status raw -o - "$LOG/notarize.json" 2>/dev/null || echo unknown)
  if [[ $status != Accepted ]]; then
    id=$(plutil -extract id raw -o - "$LOG/notarize.json" 2>/dev/null || echo "?")
    xcrun notarytool log "$id" --keychain-profile "$profile" "$LOG/notarize-log.json" >/dev/null 2>&1 || true
    echo "notarization: $status (submission $id; Apple's log: $LOG/notarize-log.json)"
    exit 1
  fi
  rm -f "$submission"
  xcrun stapler staple "$APP" >"$LOG/staple.log"
  spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" ||
    { spctl --assess --type execute -vv "$APP"; echo "Gatekeeper doesn't accept $APP"; exit 1; }
fi

ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "${ZIP:t}" >"${ZIP:t}.sha256")
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1)); $(cat "$ZIP.sha256")"
(( notarize )) || echo "Not notarized (--no-notarize): don't publish this one."

if [[ -n $upload ]]; then
  echo "==> attaching to the GitHub release $upload"
  gh release upload "$upload" "$ZIP" "$ZIP.sha256" --clobber
fi
