#!/usr/bin/env bash
# Runs ONE GPU program for the conversion spike, safely:
# - refuses if the kernel log shows amdgpu trouble in the last 2 minutes, or if another spike GPU program
#   (vpp, glconv, vkconvert, vaenc, e2e) is already running;
# - pins Mesa EGL, RADV and radeonsi, runs under the NVIDIA guard with a timeout;
# - records /proc/loadavg and the iGPU's gpu_busy_percent before and after, and samples gpu_busy every
#   100 ms during the run (mean and max);
# - checks the kernel log again afterwards (exit 5 on trouble) and pauses a few seconds.
# Usage: ./run-one.sh <label> <command> [args...]   (env TIMEOUT, default 25 s; PAUSE, default 4 s)
set -u
here=$(cd "$(dirname "$0")" && pwd)
label=$1; shift
pat='amdgpu.*(fault|timeout|reset|hang|wedged)'
busy=/sys/class/drm/card3/device/gpu_busy_percent
[[ "$(cat /sys/class/drm/card3/device/vendor)" == 0x1002 ]] || { echo "card3 is not the AMD iGPU" >&2; exit 2; }
if journalctl -k --since "-2min" | grep -iE "$pat"; then echo "run-one: amdgpu trouble in the kernel log; not running" >&2; exit 4; fi
if pgrep -x 'vpp|glconv|vkconvert|vaenc|e2e' >/dev/null; then
    echo "run-one: another spike GPU program is running:" >&2; pgrep -a -x 'vpp|glconv|vkconvert|vaenc|e2e' >&2; exit 6
fi
export LIBVA_DRIVER_NAME=radeonsi
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
export GBM_DEVICE=/dev/dri/by-path/pci-0000:79:00.0-render
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json VK_LOADER_LAYERS_DISABLE='~implicit~'
echo "=== $label: $* ($(date +%T))"
echo "loadavg before: $(cat /proc/loadavg); gpu_busy before: $(cat $busy)%"
samples=$(mktemp)
( while :; do cat $busy >>"$samples"; sleep 0.1; done ) &
sampler=$!
timeout "${TIMEOUT:-25}" "$here/../linux-encoder/nvidia-guard.sh" "$@"
status=$?
kill $sampler 2>/dev/null; wait $sampler 2>/dev/null
echo "gpu_busy during: $(awk '{s+=$1; if ($1>m) m=$1; n++} END {printf "mean %.0f%%, max %d%%, %d samples", n ? s/n : 0, m, n}' "$samples")"
rm -f "$samples"
echo "loadavg after: $(cat /proc/loadavg); gpu_busy after: $(cat $busy)%; exit $status"
if journalctl -k --since "-2min" | grep -iE "$pat"; then echo "run-one: AMDGPU TROUBLE in the kernel log after the run: STOP" >&2; exit 5; fi
sleep "${PAUSE:-4}"
exit $status
