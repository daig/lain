# lain

An iPad Pro (with its Magic Keyboard) as a computer's display, keyboard and trackpad, with low latency,
over USB-C or Wi-Fi on the local network.

| Part | Where | Get it |
|---|---|---|
| **iPad app** (the client) | `Apps/Client`, `Packages/LainKit` | Build from source (below) |
| **Mac host** (macOS 27) | `Apps/Host`, `Packages/LainKit` | Build from source for now; notarized `lain-mac-host-*.dmg` [releases](https://github.com/daig/lain/releases) are coming |
| **Linux host** (Ubuntu 26.04, GNOME/Wayland, AMD GPU) | `rust/` | [Releases](https://github.com/daig/lain/releases) (`lain_*_amd64.deb`) |

The first connection must be over USB-C: it pairs the iPad with the host. After that, Wi-Fi works too, and an
attached cable always wins. The internet is out of scope (local network only).

## Install a host

**Linux** (Ubuntu 26.04):

```sh
sudo apt install ./lain_<version>_amd64.deb
lain autostart on                  # as yourself: start with your desktop session
systemctl --user start lain-hostd  # or log out and back in
```

`lain status` shows the host, and `journalctl --user -u lain-hostd -f` its log. Linux has no AWDL (Apple's
peer-to-peer Wi-Fi), so set the iPad's Wi-Fi path to Automatic or Network: Direct never finds a Linux host.
More: [`rust/HOST-PARITY.md`](rust/HOST-PARITY.md), `/usr/share/doc/lain/config.example.toml`.

**Mac** (macOS 27): open `lain-mac-host-<version>.dmg`, drag `LainHost.app` onto `Applications` and open it.
It lives in the menu bar. Allow it Screen Recording and Local Network when macOS asks. Accessibility (which
input needs) isn't asked for on its own: pick **Grant Accessibility…** in its menu, or turn LainHost on in
System Settings › Privacy & Security › Accessibility. Then pick Start at Login in its menu. Turn off Universal
Control (Mac: Displays › Advanced; iPad: AirPlay & Continuity › Cursor and Keyboard), or the Mac's own mouse
and keyboard can wander onto the iPad and come back through lain.

## Build the iPad app

Needs a Mac with Xcode 27, an iPad Pro on iPadOS 27, and an Apple ID (a free one works, but the app then
expires after 7 days).

1. In `project.yml`, set `DEVELOPMENT_TEAM` to your team ID, and the `LainClient` target's
   `PRODUCT_BUNDLE_IDENTIFIER` (and `LainClientTests`') to a bundle ID of your own.
2. `Scripts/bootstrap.sh` generates `lain.xcodeproj` (it installs XcodeGen through Homebrew if needed).
3. Open `lain.xcodeproj`, pick the `LainClient` scheme and your iPad, and run.

The Mac host builds the same way (scheme `LainHost`; `Scripts/install-host.sh` installs it as a login service).
The Linux host: `rust/dist/build-deb.sh` builds the package, `rust/dist/install.sh` installs from source.

## License

MIT: see [LICENSE](LICENSE).
