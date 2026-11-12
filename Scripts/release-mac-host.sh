#!/bin/zsh
# Build the Mac host for a GitHub release: a Release archive of LainHost, exported with Developer ID, notarized
# and stapled, in a disk image (the app and an Applications link, to drag it onto, laid out by dmgbuild over a
# background with an arrow: Scripts/release/dmg-*) that is itself signed,
# notarized and stapled. The result opens on any Mac (macOS 27) without Gatekeeper warnings, offline too; no
# App Review is involved (notarization is an automated scan). Release steps: RELEASING.md.
#   Scripts/release-mac-host.sh --version 0.2              # build build/release/lain-mac-host-0.2.dmg (+ .sha256)
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
DMG=$OUT/lain-mac-host-$version.dmg
STAGE=$OUT/dmg
LOG=$OUT/logs
rm -rf "$ARCHIVE" "$EXPORT" "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$LOG"

Scripts/bootstrap.sh --if-stale
# dmgbuild lays out the disk image's window (Scripts/release/dmg-settings.py); a pinned copy in a local venv.
VENV=build/tools/venv DMGBUILD=build/tools/venv/bin/dmgbuild
if [[ ! -x $DMGBUILD ]] || [[ "$("$VENV/bin/pip" show dmgbuild 2>/dev/null | sed -n 's/^Version: //p')" != 1.6.5 ]]; then
  echo "==> installing dmgbuild 1.6.5 in $VENV"
  python3 -m venv "$VENV" && "$VENV/bin/pip" install -q 'dmgbuild==1.6.5' >"$LOG/dmgbuild-install.log" 2>&1 ||
    { tail -5 "$LOG/dmgbuild-install.log"; echo "couldn't install dmgbuild"; exit 1; }
fi
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

# notarize <file> <label>: submit to Apple's notary service and wait for its verdict.
notarize() {
  local file=$1 label=$2 json=$LOG/notarize-$2.json
  if ! xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format json \
      >"$json" 2>"$LOG/notarize-$label.err"; then
    cat "$LOG/notarize-$label.err" "$json" 2>/dev/null | tail -20
    echo "notarization of the $label failed; details: xcrun notarytool log <submission id> --keychain-profile $profile"
    exit 1
  fi
  local result id
  result=$(plutil -extract status raw -o - "$json" 2>/dev/null || echo unknown)
  if [[ $result != Accepted ]]; then
    id=$(plutil -extract id raw -o - "$json" 2>/dev/null || echo "?")
    xcrun notarytool log "$id" --keychain-profile "$profile" "$LOG/notarize-$label-log.json" >/dev/null 2>&1 || true
    echo "notarization of the $label: $result (submission $id; Apple's log: $LOG/notarize-$label-log.json)"
    exit 1
  fi
}

if (( notarize )); then
  # The app is notarized and stapled on its own first, so that the copy in /Applications carries its ticket and
  # opens offline; the disk image then gets its own.
  echo "==> notarizing the app (usually a few minutes)"
  submission=$OUT/LainHost-notarize.zip
  ditto -c -k --keepParent "$APP" "$submission"
  notarize "$submission" app
  rm -f "$submission"
  xcrun stapler staple "$APP" >>"$LOG/staple.log"
  spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" ||
    { spctl --assess --type execute -vv "$APP"; echo "Gatekeeper doesn't accept $APP"; exit 1; }
fi

echo "==> building the disk image"
# The window's background, drawn at 1x and 2x and combined, so Finder shows the sharp one on a Retina display.
mkdir -p "$STAGE"
swift Scripts/release/dmg-background.swift "$STAGE/background.png" 1
swift Scripts/release/dmg-background.swift "$STAGE/background@2x.png" 2
tiffutil -cathidpicheck "$STAGE/background.png" "$STAGE/background@2x.png" -out "$STAGE/background.tiff" >/dev/null
volume_icon=()
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] && volume_icon=(-D "icon=$APP/Contents/Resources/AppIcon.icns")
"$DMGBUILD" -s Scripts/release/dmg-settings.py -D "app=$APP" -D "background=$STAGE/background.tiff" $volume_icon \
  "LainHost $version" "$DMG" >"$LOG/dmgbuild.log" 2>&1 || { tail -20 "$LOG/dmgbuild.log"; echo "dmgbuild failed"; exit 1; }
rm -rf "$STAGE"
# The image is signed too when the Developer ID certificate is in the Keychain. Xcode's export can sign with a
# cloud-managed one that codesign can't use; an unsigned image is still notarized and stapled, and the app in it
# is what Gatekeeper checks when it opens.
identity=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
dmg_signed=0
if [[ -n $identity ]] && security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
  codesign --sign "$identity" --timestamp "$DMG"
  codesign --verify --strict "$DMG"
  dmg_signed=1
else
  echo "   (no local \"${identity:-Developer ID Application}\" certificate: the disk image stays unsigned)"
fi

if (( notarize )); then
  echo "==> notarizing the disk image"
  notarize "$DMG" dmg
  xcrun stapler staple "$DMG" >>"$LOG/staple.log"
  xcrun stapler validate "$DMG" >>"$LOG/staple.log"
  if (( dmg_signed )); then
    spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 |
      grep -q "source=Notarized Developer ID" ||
      { spctl --assess --type open --context context:primary-signature -vv "$DMG"; echo "Gatekeeper doesn't accept $DMG"; exit 1; }
  fi
fi

(cd "$OUT" && shasum -a 256 "${DMG:t}" >"${DMG:t}.sha256")
echo "Built $DMG ($(du -h "$DMG" | cut -f1)); $(cat "$DMG.sha256")"
(( notarize )) || echo "Not notarized (--no-notarize): don't publish this one."

if [[ -n $upload ]]; then
  echo "==> attaching to the GitHub release $upload"
  gh release upload "$upload" "$DMG" "$DMG.sha256" --clobber
fi
