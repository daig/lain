# BGRx to NV12 with an OpenGL compute shader (convert spike, GL candidate)

`glconv.c` converts BGRx to NV12 at 2752x2064 (BT.709 full range on the non-linear values; chroma is the
mean of each 2x2 block) in one compute pass on the AMD iGPU, through EGL on GBM on
`/dev/dri/by-path/pci-0000:79:00.0-render` (it checks the node's PCI vendor is 0x1002 before opening it).

- **Input:** a ring of 8 GBM BOs, XRGB8888 with Mutter's modifier `0x0200000000401b03`, filled once with
  scrolling-terminal content (random junk in the x byte), imported as EGLImages and sampled with `texelFetch`.
- **Output, zero-copy:** three NV12 VA surfaces created for the HEVC encoder (a `VAProfileHEVCMain` /
  `VAEntrypointEncSlice` context is created with them as render targets), exported with
  `vaExportSurfaceHandle` (DRM PRIME 2, separate layers), their R8 and GR88 layers imported as EGLImages and
  written with `imageStore`. **This works**: the export is one object (10 027 008 bytes, modifier
  `0x0200000000401b03`), Y at offset 0 pitch 2816, CbCr at offset 6 488 064 pitch 3072; no fallback was needed.
- Each invocation reads a 2x2 block and writes four Y and one CbCr pair. Every frame: timer queries around the
  dispatch, then a GL fence (`glClientWaitSync`, or `--sync fd` for an `EGL_ANDROID_native_fence_sync` sync file,
  what a VA encode would wait on).
- Before any GPU work the exported layers (format, object, `offset + pitch * rows <= object size`, pitch at
  least a row) and the input BOs (modifier, one plane, size, stride, offset) are checked.
- **Correctness:** after timing, frames are converted again into the VA surfaces, read back through
  `vaGetImage`, and compared with a CPU reference in double precision.

## Build and run

```
make
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json \
       VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json VK_LOADER_LAYERS_DISABLE=~implicit~
../../linux-encoder/nvidia-guard.sh ./glconv --info                       # setup only, prints the layouts
../../linux-encoder/nvidia-guard.sh ./glconv --wg 16x8 --frames 240 --verify 3
```

Options: `--wg WxH` (workgroup), `--frames N`, `--pace HZ` (0 = back to back; default 120), `--sync gl|fd`,
`--verify N`, `--ring N`, `--size WxH`, `--input texel|image|u32`, `--sweep`. Keep each run to a few
seconds, run one GPU program at a time, and check `journalctl -k` for amdgpu faults before and after.

## Findings (preliminary: 240 frames per case, one short run each, desktop idle, load about 0.1)

Correctness: **exact.** Y and CbCr max error 0, mean 0, over 3 frames (16x8), and 1 frame for every other
shape and sync mode.

| Case (texelFetch input) | GPU, timer queries p50 / p95 | dispatch to fence signalled, p50 / p95 |
|---|---|---|
| 16x8, paced 120 Hz | 1.25 / 1.34 ms | 2.21 / 2.51 ms |
| 8x8, paced 120 Hz | 1.19 / 1.34 ms | 2.10 / 2.52 ms |
| 16x16, paced 120 Hz | 1.19 / 1.34 ms | 2.11 / 2.48 ms |
| 32x4, paced 120 Hz | 1.41 / 1.64 ms | 2.30 / 2.70 ms |
| 32x8, paced 120 Hz | 1.37 / 1.60 ms | 2.31 / 2.70 ms |
| 64x1, paced 120 Hz | 1.93 / 2.16 ms | 2.88 / 3.30 ms |
| 16x8, sync-file fence, paced 120 Hz | 1.23 / 1.34 ms | 2.22 / 2.54 ms |
| 16x8, back to back (`--pace 0`) | **0.64 / 0.66 ms** | **0.71 / 0.74 ms** |

- Square-ish workgroups (8x8, 16x8, 16x16) are best; wide rows (64x1, 32x4) lose 15-60 %.
- Back to back the pass takes 0.64 ms (31 MB in 0.64 ms, about 49 GB/s), under the 1 ms goal. Paced at
  120 Hz with an otherwise idle GPU it takes about twice as long and the fence signals about 1 ms after the
  shader ends: the GPU clocks down between frames. In the pipeline the encoder keeps the GPU busier, so the
  real number should lie between; the measuring agent should take it with the encoder running.
- Either way conversion plus the 7.3 ms encode is about 8.0-9.5 ms, against 3.5-7 ms for `vapostproc`, and it
  is zero-copy into the encoder's own surface.
- `--input image|u32` (imageLoad) is **wrong**: the imported XR24 texture is `GL_RGB8`, which is not an
  image-unit format, so loads return garbage (Y max error 230) without a GL error. Use `texelFetch`.
- No amdgpu fault, timeout or reset was logged during any of these runs.
