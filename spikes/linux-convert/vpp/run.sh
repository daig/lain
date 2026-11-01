#!/usr/bin/env bash
# Runs ./vpp under the NVIDIA guard with the environment pinned to Mesa on the AMD node, checking the kernel
# log for amdgpu faults before and after. Usage: ./run.sh [vpp args...]
set -u
here=$(cd "$(dirname "$0")" && pwd)
pat='amdgpu.*(fault|timeout|reset|hang|wedged)'
if journalctl -k --since "-2min" | grep -iE "$pat"; then echo "run.sh: amdgpu trouble in the kernel log; not running" >&2; exit 4; fi
export LIBVA_DRIVER_NAME=radeonsi
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json VK_LOADER_LAYERS_DISABLE='~implicit~'
timeout 20 "$here/../../linux-encoder/nvidia-guard.sh" "$here/vpp" "$@"
status=$?
if journalctl -k --since "-2min" | grep -iE "$pat"; then echo "run.sh: amdgpu trouble in the kernel log after the run" >&2; exit 5; fi
exit $status
