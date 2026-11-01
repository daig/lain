#!/usr/bin/env bash
# Runs ONE command that may use the AMD iGPU (lain-linux-video's live tests, lain-gnome's), safely:
# - waits for the machine-wide GPU lock: one GPU user at a time (three at once reset the iGPU, 2026-10-31);
# - refuses if the kernel log shows amdgpu trouble in the last 2 minutes;
# - pins Mesa (L7): the EGL vendor, RADV with implicit Vulkan layers off, radeonsi for VA-API, GTK on GL;
# - runs the command under spikes/linux-encoder/nvidia-guard.sh, which makes any open of a non-AMD GPU node
#   fail and reports it (exit 3), with a timeout;
# - checks the kernel log again afterwards (exit 5, STOP, on trouble), pauses, then releases the lock;
# - appends one line per run to the run log.
#
# Usage: rust/scripts/gpu-run.sh <label> <command> [args...]
#   e.g. rust/scripts/gpu-run.sh encode-idr cargo test -p lain-linux-video -- --ignored --exact gpu_idr --test-threads=1
# Build first (cargo test -p <crate> --no-run): the lock is held for the whole command.
# Env: TIMEOUT (seconds, default 120), PAUSE (default 4), LOCK_WAIT (default 1800),
#      GPU_RUN_LOG (default /run/user/<uid>/lain-gpu-runs.log).
# Exit: the command's status, or 3 (a non-AMD GPU node was opened), 4 (amdgpu trouble before: not run),
#       5 (amdgpu trouble after: stop all GPU work), 6 (no AMD render node), 7 (the lock wasn't free in time).
set -u
[[ $# -ge 2 ]] || { echo "usage: $0 <label> <command> [args...]" >&2; exit 2; }
label=$1; shift
here=$(cd "$(dirname "$0")" && pwd)
guard=$here/../../spikes/linux-encoder/nvidia-guard.sh
# The lock must be the same file for every caller, whatever its environment.
runtime=/run/user/$(id -u)
[[ -d "$runtime" && -w "$runtime" ]] || runtime=/tmp
log=${GPU_RUN_LOG:-$runtime/lain-gpu-runs.log}
pat='amdgpu.*(fault|timeout|reset|hang|wedged|ring .* (timeout|reset))'

node=
for d in /sys/class/drm/renderD*; do
    [[ "$(cat "$d/device/vendor" 2>/dev/null)" == 0x1002 ]] || continue
    if [[ -z "$node" || "$(cat "$d/device/boot_vga" 2>/dev/null)" == 1 ]]; then node=$d; fi
done
[[ -n "$node" ]] || { echo "gpu-run: no AMD render node" >&2; exit 6; }
busy=$node/device/gpu_busy_percent

exec 9>"$runtime/lain-gpu.lock"
if ! flock -n 9; then
    echo "gpu-run: waiting for the GPU lock, held by: $(cat "$runtime/lain-gpu.holder" 2>/dev/null)" >&2
    flock -w "${LOCK_WAIT:-1800}" 9 || { echo "gpu-run: the GPU lock wasn't free within ${LOCK_WAIT:-1800} s" >&2; exit 7; }
fi
echo "$label (pid $$, $(date +%T), $PWD)" >"$runtime/lain-gpu.holder"

if journalctl -k --since "-2min" | grep -iE "$pat" >&2; then
    echo "gpu-run: amdgpu trouble in the kernel log in the last 2 minutes; not running" >&2
    echo "$(date -Is) $label REFUSED (kernel log) :: $*" >>"$log"
    exit 4
fi

export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json VK_LOADER_LAYERS_DISABLE='~implicit~'
export LIBVA_DRIVER_NAME=radeonsi GSK_RENDERER=gl
start=$(date -Is)
echo "=== gpu-run $label on $(basename "$node") ($(date +%T)): $*" >&2
echo "loadavg $(cut -d' ' -f1-3 /proc/loadavg), gpu_busy $(cat "$busy" 2>/dev/null)% before" >&2
timeout --kill-after=10 "${TIMEOUT:-120}" "$guard" "$@"
status=$?
echo "loadavg $(cut -d' ' -f1-3 /proc/loadavg), gpu_busy $(cat "$busy" 2>/dev/null)% after; exit $status" >&2
trouble=0
if journalctl -k --since "$start" | grep -iE "$pat" >&2; then
    trouble=1
    echo "gpu-run: AMDGPU TROUBLE in the kernel log after '$label': STOP all GPU work and report it" >&2
fi
echo "$start $label exit $status$([[ $trouble == 1 ]] && echo ' KERNEL-TROUBLE') :: $*" >>"$log"
sleep "${PAUSE:-4}"
[[ $trouble == 1 ]] && exit 5
exit "$status"
