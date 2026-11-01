# Speedup spike, candidate "vpp": BGRx to NV12 with Mesa's VA video processing, no GStreamer

`vpp.c` converts BGRx at 2752x2064 to NV12 with libva's video processing (VAProfileNone,
VAEntrypointVideoProc) on the AMD iGPU (radeonsi, renderD130, checked by PCI vendor 0x1002), called directly
from C. The question is whether the 3.5-7 ms that spike A measured with GStreamer's `vapostproc` comes from
the driver or from GStreamer.

- Input: a ring of 8 BGRx frames with scrolling-text content, filled once on the CPU. They are either
  GBM BOs on the AMD node with Mutter's modifier 0x0200000000401b03 (`--src gbm`) or LINEAR
  (`--src gbm-linear`), imported as VA surfaces through DRM PRIME 2, or driver-allocated BGRX surfaces
  (`--src va`). The program validates geometry before submitting any GPU work: the BO's modifier,
  dimensions and plane count, the pitch, and offset + pitch x height against the dma-buf size; and the
  VAImage plane offsets and pitches against its data size.
- Output: NV12 surfaces (VPP write + encoder usage). `--encode` sends each one through the HEVC encoder
  with spike A's vaenc settings (CBR 60 Mbps), which shows the encoder accepts them.
- Timing: vaEndPicture to vaSyncSurface for each conversion, paced at `--fps` (0 = back to back).
- Correctness: `--check N` reads back the NV12 of N ring frames and compares them with a CPU reference
  (BT.709 full range on the non-linear values, 2x2 chroma mean, rounded, clamped). It prints max and mean
  absolute error per plane.

## Build and run

    make
    ./run.sh --in-std bt709 --seconds 2              # check 3 frames, then 2 s paced at 120 Hz
    ./run.sh --in-std bt709 --encode --seconds 2     # convert + HEVC encode
    ./run.sh --help

`run.sh` checks the kernel log for amdgpu faults, timeouts and resets before and after each run. It runs
`vpp` under `spikes/linux-encoder/nvidia-guard.sh` and a 20 s timeout, with `LIBVA_DRIVER_NAME=radeonsi`,
EGL pinned to Mesa and Vulkan pinned to RADV. Runs are capped at 10 s. Run one at a time: never alongside
another GPU program.

## Findings (preliminary: short runs, desktop in use, 2026-10-31, Mesa 26.0.8, Raphael 2-CU iGPU)

- **The cost is the driver, not GStreamer.** Paced at 120 Hz, a conversion takes p50 3.6 ms (p95
  4.0-4.6 ms, max about 6-7 ms). That matches vapostproc's 3.5-7 ms.
- Run back to back (`--fps 0`), a conversion takes p50 2.0 ms (475 conversions/s, GPU 99 % busy). The gap
  against paced runs looks like GPU clock ramp-down between frames (DPM level `auto`); I didn't test
  this further. Even 2.0 ms is about 15 GB/s, far below memory bandwidth, so it looks bound by the shader
  on 2 CUs rather than by memory.
- `VA_FILTER_SCALING_FAST`, `_HQ`, `_DEFAULT`, `VA_PROC_PIPELINE_FAST`, GBM-tiled against LINEAR, and
  imported against driver-allocated input surfaces: none of them changes the time (all p50 3.58-3.66 ms).
- Convert + encode, sequential, paced at 120 Hz: p50 11.0 ms (encode 7.3 ms), so 91 fps. That is no
  better than spike A. **VPP does not get 120 Hz.** Conversion would have to drop to about 1 ms, or
  overlap with the encode of the previous frame.
- **Correctness: exact.** This needs `surface_color_standard = BT709` on the input, with output
  BT709 and `VA_SOURCE_RANGE_FULL`. Over 3 frames, Y max 0 / mean 0.0000, Cb max 1 / mean 0.0092,
  Cr max 1 / mean 0.0416. With `VAProcColorStandardSRGB` on the input (what you'd naturally pass for
  desktop RGB), Mesa applies a transfer-function change: Y is off by up to 7 (mean 4.6) and Cb by up to 3.
  `--range limited`, `explicit` and `none` are worse still.
- The encoder accepts the VPP's NV12 output surface (modifier 0x0200000000401b03, Y pitch 2816) directly.
- No amdgpu fault, timeout or reset in the kernel log during any of these runs.
