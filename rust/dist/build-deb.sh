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

# No build machine's paths in the published binaries (panic locations name dependency sources): the home
# directory, the cargo registry and this workspace are remapped (rustc applies the last matching prefix). A
# target directory of its own, so these flags don't invalidate the everyday build in target/.
export CARGO_TARGET_DIR="$rust/target/package"
cargo_home=${CARGO_HOME:-$HOME/.cargo}
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/home/user --remap-path-prefix=$cargo_home=/cargo --remap-path-prefix=$rust=/lain/rust"

echo "building lain $version (release)…"
# niced and first in line for the OOM killer: this machine also runs heavy jobs.
nice -n 10 choom -n 1000 -- cargo build --release -j4 -p lain-hostd --bins
cargo deb -p lain-hostd --no-build --deb-version "$version" --output "$rust/target/debian/"
if strings "$CARGO_TARGET_DIR/release/lain-hostd" "$CARGO_TARGET_DIR/release/lain" | grep -q -F "$HOME"; then
    echo "error: the binaries still name $HOME" >&2
    exit 1
fi
