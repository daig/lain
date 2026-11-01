#!/usr/bin/env bash
# Prints the AMD iGPU's VCN busy percentage and active video/GFX clocks every 200 ms while a command runs.
# Usage: ./gpu-sample.sh <command...>     (the AMD card is found by PCI vendor 0x1002)
set -u
dev=""
for c in /sys/class/drm/card[0-9]*; do
    [[ "$(cat "$c/device/vendor" 2>/dev/null)" == 0x1002 ]] && dev="$c/device" && break
done
[[ -n "$dev" ]] || { echo "no AMD GPU" >&2; exit 1; }
"$@" &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
    vclk=$(grep '\*' "$dev/pp_dpm_vclk" | awk '{print $2}')
    dclk=$(grep '\*' "$dev/pp_dpm_dclk" | awk '{print $2}')
    sclk=$(grep '\*' "$dev/pp_dpm_sclk" | awk '{print $2}')
    echo "sample vcn_busy=$(cat "$dev/vcn_busy_percent")% gfx_busy=$(cat "$dev/gpu_busy_percent")% vclk=${vclk:-?} dclk=${dclk:-?} sclk=${sclk:-?}"
    sleep 0.2
done
wait "$pid"
