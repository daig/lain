#!/usr/bin/env bash
# Installs the lain host for this user (Swift's Scripts/install-host.sh, in spirit): builds the release binaries,
# copies lain-hostd and lain into ~/.local/bin (or $PREFIX/bin), turns Start at Login on (`lain autostart on`: the
# systemd user unit lain-hostd.service, bound to the graphical session), and starts or restarts it now.
#
# Usage: rust/dist/install.sh            (from anywhere in the repository)
#        PREFIX=/opt/lain rust/dist/install.sh
# Uninstall: lain autostart off; systemctl --user stop lain-hostd; rm ~/.local/bin/{lain,lain-hostd}
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rust=$(cd "$here/.." && pwd)
bin=${PREFIX:-$HOME/.local}/bin
unit=lain-hostd.service

echo "building (release)…"
# niced and first in line for the OOM killer: this machine also runs heavy jobs.
(cd "$rust" && nice -n 10 choom -n 1000 -- cargo build --release -p lain-hostd --bins)

mkdir -p "$bin"
for b in lain-hostd lain; do
    install -m 0755 "$rust/target/release/$b" "$bin/$b.new"
    mv -f "$bin/$b.new" "$bin/$b" # atomic: a running lain-hostd keeps its old file
done
echo "installed lain-hostd and lain in $bin"

"$bin/lain" autostart on

# A lain-hostd not started by systemd (one run by hand) would keep the unit's from owning the host's name.
if pgrep -x lain-hostd >/dev/null && ! systemctl --user is-active --quiet "$unit"; then
    echo "note: a lain-hostd started by hand is running; stop it, then: systemctl --user start $unit"
else
    systemctl --user restart "$unit"
    sleep 1
    systemctl --user --no-pager --lines=0 status "$unit" | head -3 || true
fi
case ":$PATH:" in *":$bin:"*) ;; *) echo "note: $bin isn't on your PATH" ;; esac
echo "done: \`lain status\` shows the host; its log is \`journalctl --user -u $unit -f\`"
