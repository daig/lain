#!/usr/bin/env bash
# Runs a command under strace with every non-AMD GPU device node fenced off: any open of a DRM node whose
# PCI vendor isn't 0x1002, or of /dev/nvidia*, fails with EACCES at syscall entry (so the device is never
# actually opened) and is logged. Exit status 3 if the command tried to open one, else the command's.
# Usage: ./nvidia-guard.sh <command> [args...]
set -u
fence=()
for dev in /sys/class/drm/card* /sys/class/drm/renderD*; do
    name=$(basename "$dev")
    [[ "$name" == *-* ]] && continue
    vendor=$(cat "$dev/device/vendor" 2>/dev/null || echo none)
    [[ "$vendor" == 0x1002 ]] || fence+=(-P "/dev/dri/$name")
done
for n in /dev/nvidia*; do [[ -c "$n" ]] && fence+=(-P "$n"); done
log=$(mktemp)
strace -f -qq -o "$log" -e trace=open,openat,openat2 -e inject=open,openat,openat2:error=EACCES "${fence[@]}" "$@"
status=$?
if [[ -s "$log" ]]; then
    echo "nvidia-guard: the command tried to open a fenced (non-AMD) device:" >&2
    sort -u -t' ' -k2 "$log" | head -20 >&2
    rm -f "$log"
    exit 3
fi
rm -f "$log"
echo "nvidia-guard: no non-AMD GPU node was opened" >&2
exit "$status"
