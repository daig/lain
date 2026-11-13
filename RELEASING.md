# Releasing

Both hosts are published as GitHub release assets. The iPad app is distributed as source for now (TestFlight is
the likely next step). Nothing here goes through App Review: the `.deb` is unsigned, and the Mac host is
Developer ID-signed and notarized (an automated scan, not a review).

Releases are built from a pushed commit on `main` with a clean tree, and each host gets its own tag:
`linux-host-v<version>-r<commits>` and `mac-host-v<version>`. Mark releases before 1.0 as pre-releases.

## Linux host (`.deb`)

On the Ubuntu 26.04 build machine (`cargo install cargo-deb`; headers: `libclang-dev libva-dev libgbm-dev
libpipewire-0.3-dev libssl-dev pkg-config`):

```sh
rust/dist/build-deb.sh   # rust/target/debian/lain_<version>+<commits>.g<hash>_amd64.deb
cd rust/target/debian && sha256sum lain_*.deb > SHA256SUMS
gh release create linux-host-v0.1.0-r<commits> --prerelease --target <commit> \
  --title "Linux host 0.1.0 (r<commits>)" --notes-file <notes.md> lain_*.deb SHA256SUMS
```

- The version is the workspace's (`rust/Cargo.toml`) plus the commit count and hash, so apt always takes a newer
  build as an upgrade. Bump the workspace version for a notable release.
- `build-deb.sh` remaps the build machine's paths out of the binaries and refuses to finish if any home path is
  left. It builds in `rust/target/package`, apart from the everyday build.
- The package's contents and dependencies are in `rust/crates/lain-hostd/Cargo.toml`
  (`[package.metadata.deb]`). The shipped unit `rust/dist/lain-hostd.service` must stay identical to what
  `UnitFile::host("/usr/bin/lain-hostd")` renders (a test checks), so that `lain autostart on` recognises it.

## Mac host (notarized `.dmg`)

One-time setup on the Mac:

1. Optional: a local **Developer ID Application** certificate (Xcode › Settings › Accounts › (team 8DWR7MSCR6) ›
   Manage Certificates › + › Developer ID Application). The export signs the app without it, using a
   cloud-managed certificate; the local one is needed only to sign the disk image as well (otherwise the image
   is notarized and stapled unsigned, which Gatekeeper accepts: it checks the app).
2. An app-specific password (account.apple.com › Sign-In and Security › App-Specific Passwords), stored for
   notarytool:
   ```sh
   xcrun notarytool store-credentials lain-notary --apple-id <Apple ID> --team-id 8DWR7MSCR6
   ```

Each release:

```sh
git pull && Scripts/release-mac-host.sh --version 0.1.0 --no-notarize   # optional: check the signing first
gh release create mac-host-v0.1.0 --prerelease --title "Mac host 0.1.0" --notes-file <notes.md>
Scripts/release-mac-host.sh --version 0.1.0 --upload mac-host-v0.1.0
```

The script archives the `LainHost` scheme in Release and exports it with Developer ID
(`Scripts/release/ExportOptions-DeveloperID.plist`). Automatic signing creates the Developer ID provisioning
profile that the Keychain entitlement needs. The script then checks the signature and hardened runtime,
notarizes and staples the app, and checks that Gatekeeper accepts it. It then puts the app and an
`Applications` link in a disk image (laid out by dmgbuild), signs it when the certificate is local, notarizes and staples it, and
writes `build/release/lain-mac-host-<version>.dmg` and its `.sha256`; with `--upload` it attaches both to the
release. Logs: `build/release/logs/`.

The disk image's window is laid out by dmgbuild (a pinned copy the script installs in `build/tools/venv`) over a
background drawn by `Scripts/release/dmg-background.swift`; its volume icon is the app's.

Verified (2026-11-12, `mac-host-v0.1.0`): the Developer ID export succeeds with the Keychain entitlement
(`keychain-access-groups`) and the hardened runtime, and Apple notarizes the app and the disk image.

### Development builds on this Mac

`Scripts/install-host.sh` installs the working tree's host on this Mac for testing: nothing committed is
required, and nothing is notarized, put in a disk image or uploaded. It builds as a release does (a Release
archive exported with Developer ID) because macOS ties the login agent's registration and the Screen Recording
and Accessibility grants to the app's signature: a host installed from a release's disk image must only ever be
replaced by one signed the same way. Replaced by a build signed with Apple Development (what the script made
before releases existed), the agent failed to start (launchd: "spawn failed", `EX_CONFIG`) and the Screen
Recording grant had to be removed and added again.

The script therefore refuses to install over a host signed differently, removes its export and archive once the
copy is staged (a second copy with the same signature can also keep launchd from resolving the agent), and keeps
the old app until the new agent runs, putting it back if it doesn't. The build number is
`<commits>.<yymmdd>.<hhmm>`, so a development build is told from a release at a glance (lain's menu, or
`plutil -p /Applications/LainHost.app/Contents/Info.plist`). `Scripts/test-scripts.sh` checks all of this
against fakes; to go back to a release, install its disk image from `build/release/`.

## Artwork

`Scripts/assets/generate.swift` draws the app icons' layers (`Apps/Host/AppIcon.icon`, `Apps/Client/AppIcon.icon`),
the menu-bar and tray glyphs and the README splash, all from one definition of the emblem. Run it from the
repository root after changing the design, and commit what it rewrites.

## iPad app

Source only for now; see the README. For TestFlight later: archive the `LainClient` scheme, upload with an App
Store Connect export (method `app-store-connect`), and add testers. Internal testers (your team) need no review;
a public link needs a Beta App Review.
