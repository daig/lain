#!/usr/bin/env bash
# Runs a command with every non-AMD GPU node (DRM nodes whose PCI vendor isn't 0x1002, and /dev/nvidia*)
# masked by /dev/null in a private mount namespace (bubblewrap), so nothing in it can open them.
# GStreamer's VA plugin opens every render node when it loads (plugin_init); this is the only way found
# to keep it off the NVIDIA cards while still using it. Usage: ./fence.sh <command> [args...]
set -u
mask=()
for dev in /sys/class/drm/card* /sys/class/drm/renderD*; do
    name=$(basename "$dev")
    [[ "$name" == *-* ]] && continue
    vendor=$(cat "$dev/device/vendor" 2>/dev/null || echo none)
    [[ "$vendor" == 0x1002 ]] || mask+=(--bind /dev/null "/dev/dri/$name")
done
for n in /dev/nvidia*; do [[ -c "$n" ]] && mask+=(--bind /dev/null "$n"); done
exec bwrap --dev-bind / / "${mask[@]}" "$@"
