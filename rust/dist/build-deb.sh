#!/usr/bin/env bash
# Builds the Ubuntu package of the lain host, rust/target/debian/lain_<version>_amd64.deb (cargo-deb; the package
# is described in crates/lain-hostd/Cargo.toml, [package.metadata.deb]).
#
# Needs: cargo install cargo-deb; the build headers (libclang-dev libva-dev libgbm-dev libpipewire-0.3-dev
# libssl-dev pkg-config).
# Version: the workspace's, plus the commit count and hash (0.1.0+42.gabc1234), so every build of main sorts
# after the last; "+dirty" when the tree has uncommitted changes.
#
# Install:  sudo apt install ./rust/target/debian/lain_*.deb    (apt pulls in the dependencies)
# Then, once per user:  lain autostart on    (and after an upgrade: systemctl --user restart lain-hostd)
# Remove:   lain autostart off; sudo apt remove lain
set -euo pipefail
rust=$(cd "$(dirname "$0")/.." && pwd)
cd "$rust"
command -v cargo-deb >/dev/null || { echo "cargo-deb is missing: cargo install cargo-deb" >&2; exit 1; }

base=$(cargo metadata --no-deps --format-version 1 |
    python3 -c 'import json,sys; print(next(p["version"] for p in json.load(sys.stdin)["packages"] if p["name"]=="lain-hostd"))')
version="$base+$(git rev-list --count HEAD).g$(git rev-parse --short HEAD)"
git diff --quiet HEAD -- . || version="$version.dirty"

echo "building lain $version (release)…"
# niced and first in line for the OOM killer: this machine also runs heavy jobs.
nice -n 10 choom -n 1000 -- cargo build --release -j4 -p lain-hostd --bins
cargo deb -p lain-hostd --no-build --deb-version "$version"
