# Spike 6, candidate "vk": BGRx → NV12 in one Vulkan compute pass on RADV

Can BGRx → NV12 at 2752×2064 run in about 1 ms on the AMD iGPU, so that conversion plus HEVC encoding
(about 7.3 ms, SL2) fits in 8.3 ms at 120 Hz? This candidate converts with one Vulkan compute dispatch on
RADV (ash; the WGSL shader is compiled to SPIR-V at run time with naga), on the AMD render node only.

## What it does

- **Input:** a ring of 8 BGRx (`XRGB8888`) DMA-BUFs, allocated with GBM on `renderD130` at exactly
  the modifier Mutter's screen-cast streams offer (`0x200000000401b03`, GFX10.3 64K_R_X, no DCC, one plane).
  Each is imported into Vulkan as a `B8G8R8A8_UNORM` image (`VK_EXT_external_memory_dma_buf`,
  `VK_EXT_image_drm_format_modifier`, explicit layout from GBM) and filled once with spike A's scrolling-text
  content by a buffer-to-image copy.
- **Conversion:** BT.709 full range on the non-linear values; chroma is the mean over each 2×2 block;
  8-bit, rounded, clamped. One pass reads every source pixel once and writes Y and CbCr.
- **Outputs (`--out`):**
  - `vk-tiled` (the one for the encoder): Vulkan allocates one exportable memory holding NV12 at the same
    tiled layout libva's own NV12 surfaces have (modifier `0x200000000401b03`, Y pitch 2816, CbCr at
    6488064 with pitch 3072), as an `R8` and an `R8G8` storage image. It is exported as one DMA-BUF and
    imported into libva with `vaCreateSurfaces` (`DRM_PRIME_2`). Shader `src/convert_img.wgsl`, one 2×2
    block per invocation.
  - `buffer`: NV12 into a plain linear Vulkan storage buffer (`src/convert.wgsl`, 32-bit word stores, one or
    more 4×2 blocks per invocation).
  - `va-import`: the same linear layout in an exported Vulkan buffer, imported into libva as a LINEAR NV12
    surface (pitch 2816).
  - `img`: Vulkan-owned optimal-tiling `R8`/`R8G8` storage images (a control for the image shader).
  - `va-export`, `va-tiled`: libva's own surfaces imported into Vulkan; see the findings (neither works).
- **Timing:** a timestamp pair around the dispatch, and CPU time from `vkQueueSubmit` to the fence, one
  frame in flight; paced at `--fps` (120 by default; 0 = back to back), on the compute-only queue by default
  (`--queue gfx` for the graphics queue).
- **Correctness:** `--check N` frames are converted and read back (through libva when there is a VA
  surface, `vaDeriveImage` or `vaGetImage`, and through Vulkan), then compared with a CPU reference in f64.
  It prints the max and mean absolute error per plane.
- **Safety:** the render node is checked to be a DRM render node of PCI vendor `0x1002`, and the Vulkan
  device is chosen by its DRM render major:minor and checked to be RADV. Every import checks the
  modifier, plane count, pitch and offset against what GBM or libva reported and against the DMA-BUF's
  size (`lseek`). Vulkan's memory requirement must fit in the DMA-BUF too. Buffer destinations are
  validated: alignment, pitch ≥ width, planes inside the buffer and not overlapping. Descriptors cover
  exactly the validated range. The shader is compiled with naga's `Restrict` bounds-check policy and runs
  with `robustBufferAccess`. Fence waits time out after 5 s, and a timed run is capped at about 10 s.

## Build and run

```sh
cd spikes/linux-convert/vk
cargo build --release          # needs libgbm-dev and libva-dev; no bindgen, native/native.c is built with cc
cd ../../..
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
export GBM_DEVICE=/dev/dri/by-path/pci-0000:79:00.0-render
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json
export VK_LOADER_LAYERS_DISABLE='~implicit~'
export LIBVA_DRIVER_NAME=radeonsi
journalctl -k --since "-2min" | grep -iE "amdgpu.*(fault|timeout|reset|hang|wedged)"   # must print nothing
spikes/linux-encoder/nvidia-guard.sh spikes/linux-convert/vk/target/release/vkconvert \
    --out vk-tiled --wx 8 --wy 8 --check 3 --frames 240
journalctl -k --since "-2min" | grep -iE "amdgpu.*(fault|timeout|reset|hang|wedged)"   # again
```

Options: `--out vk-tiled|buffer|va-import|img|va-export|va-tiled`, `--wx --wy` (workgroup), `--words N` and
`--strided 1` (buffer shader only), `--frames`, `--fps` (0 = back to back), `--queue compute|gfx`,
`--check N`, `--ring N`, `--width --height`, `--vk-readback 0` (libva readback only), `--shared-import 0|1`
(`va-tiled`). `--dump-spv FILE` compiles the shader without opening any device. `VKCONVERT_VERBOSE=1`
prints each import's layout as RADV sees it. `VKCONVERT_CLEAR=1` clears the planes before each check and
prints what libva reads (a diagnostic).

## Findings (2026-10-31; preliminary timings: 1–2 s runs, the developer's desktop in use)

All runs on the Ryzen 9 9950X iGPU (RADV RAPHAEL_MENDOCINO, Mesa 26.0.8), compute-only queue unless noted,
with the kernel log clean before and after every run, and the guard reporting no non-AMD node opened.

| Output | Workgroup | Pacing | GPU (timestamps) p50 / p95 | submit → fence p50 / p95 | Correctness |
|---|---|---|---|---|---|
| `vk-tiled` (libva surface) | 8×8 | 120 Hz | 1.22 / 1.52 ms | 2.19 / 2.72 ms | exact (max 0), libva and Vulkan readback, 3 frames |
| `vk-tiled` | 16×8 | 120 Hz | 1.17 / 1.34 ms | 2.12 / 2.43 ms | — |
| `vk-tiled` | 32×4 | 120 Hz | 1.37 / 1.60 ms | 2.35 / 2.69 ms | — |
| `vk-tiled` | 8×8 | back to back | 0.65 / 1.11 ms | 0.70 / 1.15 ms | — |
| `buffer` | 64×1 | 120 Hz | 1.77 / 1.98 ms | 2.74 / 3.06 ms | exact, 3 frames |
| `buffer` | 8×8 (also 16×4, 16×16) | 120 Hz | 1.30 / 1.50 ms | 2.21 / 2.60 ms | — |
| `buffer` | 8×8 | back to back | 0.70 / 0.76 ms | 0.74 / 0.81 ms | — |
| `buffer` | 8×8, graphics queue | 120 Hz | 1.27 / 1.50 ms | 2.13 / 2.57 ms | — |
| `buffer` | 64×1, 2 blocks per invocation | 120 Hz | 3.45 / 3.86 ms | — | — |
| `va-import` (linear libva surface) | 8×8 | 120 Hz | 1.35 / 1.54 ms | 2.33 / 2.63 ms | exact, libva readback, 3 frames |

- **Correctness:** on the terminal content (five colours on a background, no blending), every checked frame
  matches the CPU reference exactly (max and mean absolute error 0 on Y and on CbCr), in every output that
  works. That includes the frames libva reads back from the `vk-tiled` and `va-import` surfaces. Over all
  2^24 colours plus random pixels (`--content allcolors --ring 8 --check 8`, vk-tiled), it is **max error 1**
  in Y and CbCr, from f32 rounding at ties (under 0.01% of samples, identical through libva and Vulkan;
  `../results/allcolors-vk.txt`). "exact" in the table means on the terminal content.
- **Speed:** the pass takes 0.65–0.7 ms of GPU time when the GPU is kept busy, about 44 GB/s against
  31.2 MB per frame. Paced at 120 Hz, as lain would run it, it takes 1.2–1.3 ms, presumably because the
  iGPU clocks down between frames (`pp_dpm_sclk` steps 600/700/2200 MHz; not measured per run).
  Submit → fence is about 0.9 ms longer than GPU time when paced, and 0.05 ms longer back to back.
  Against VA video processing's 3.5–7 ms (SL2), conversion is 3–5× faster. Conversion plus encode would be
  about 1.2 + 7.3 ≈ 8.5 ms per frame if run serially at the paced figure, just over 8.3 ms. At the
  back-to-back figure it is about 8.0 ms. Conversion runs on GFX/compute and encoding on VCN, so they can
  overlap across frames (convert frame n+1 while frame n encodes). The encoder's 7.3 ms then sets the
  frame rate, and the latency is about 8.5–9.5 ms. That end-to-end claim is not measured here.
- **Layout for the encoder:** libva's own NV12 surfaces on this GPU are not linear. They use the same
  modifier `0x200000000401b03`, Y pitch 2816 and CbCr pitch 3072 at offset 6488064, in one 10,027,008-byte
  object. Vulkan can allocate exactly that layout (`vk-tiled`), export it as one DMA-BUF, and libva imports
  it as an NV12 surface: zero-copy into a surface laid out like the encoder's own. A LINEAR import into
  libva (`va-import`) also works. This spike didn't run an encode from either surface.
- **Dead ends:** `va-export` stops by design: libva's surfaces are tiled, so a buffer can't address them.
  `va-tiled` imports libva's own exported surface into Vulkan as `R8` and `R8G8` images. The imports
  succeed with layouts that match (checked with `VKCONVERT_VERBOSE`). But nothing Vulkan writes there is
  visible, even to Vulkan's own copy back: shader stores and `vkCmdClearColorImage` alike read back as
  zeros, through libva and through Vulkan. That holds both for one import per plane and for one shared
  import. Not understood. Allocating in Vulkan and importing into libva avoids it.
- **Workgroup shape matters:** 2D tiles (8×8, 16×8) beat 1D rows (64×1) by about 30%. More blocks per
  invocation made it slower.

## Open

- An encode from a `vk-tiled` surface (spike A's `vaenc` path), and convert-plus-encode overlapped end to
  end with the GPU clocks as they are in a real run.
- Why writes to libva's exported surface, imported into Vulkan, are lost.
- Mutter's buffers need a queue-family acquire from `VK_QUEUE_FAMILY_FOREIGN_EXT` and implicit-sync
  handling (or DMA-BUF sync files). Here the ring is the spike's own and is filled once.
