# Spike 6: a faster BGRx → NV12 conversion on the AMD iGPU

**Question.** Can BGRx → NV12 at 2752×2064 be made fast enough (goal about 1 ms; the pass is memory-bound,
about 22.7 MB read and 8.5 MB written per frame) that conversion plus HEVC encoding fits in 8.3 ms, so that
120 Hz end to end becomes reachable (decision D1)?

**Answer in short.**
- **Yes, 2752×2064 at 120 Hz is reachable end to end on this iGPU (measured).** The pipeline runs capture →
  convert → encode at **119.6–119.9 fps with no drops**. Capture → access unit is **p50 13.2–13.4 ms, p95
  14.0–15.2 ms**, while a fullscreen client animates the whole 120 Hz virtual monitor. This took two changes
  in how the host is built, not just a faster shader:
  1. **Service PipeWire on its own thread.** With the stream on the same thread as convert + encode, Mutter's
     frames sat in PipeWire for 5 ms (p50) and only 104.8/s were delivered.
  2. **Pipeline conversion against encoding.** The next picture is converted on GFX while the previous one
     encodes on VCN, with still one encode outstanding. Run in sequence, convert + encode takes about 9 ms
     and caps the rate at about 106 fps.
- **Conversion: one compute pass, GL and Vulkan alike, about 0.65 ms of GPU time (measured).** On a busy GPU
  that is 5.4 MB/ms read and written (31.2 MB at about 48 GB/s), and the output is exact (error 0 against an
  f64 reference). The 1 ms goal is met whenever the GPU is clocked up: back to back, and in the pipelined end
  to end path (GPU p50 0.66–0.69 ms, p95 0.83–0.93 ms). Paced at 120 Hz on an idle GPU it is 1.2 ms (the
  clocks drop between frames; inferred, see below).
- **VA video processing also reaches 120 fps once pipelined (measured), but it costs more.** It runs at 117.5–119.9
  fps, capture → AU p50 14.8–15.2 ms and p95 15.6–19.5 ms, with gpu_busy at 80–83%. The compute pass runs at
  57–60%. Its conversion is 2.0 ms back to back and 2.9–3.7 ms paced, against 0.65 / 1.2 ms for compute.
  So spike A's 70–90 fps came mostly from the serial design. VPP's own cost made it worse, and GStreamer
  played no part in it.
- **Recommendation for `lain-linux-video`:** convert with a single compute pass into libva's own NV12 encoder
  surface, exported with `vaExportSurfaceHandle` (zero-copy). Wait on the conversion's fence on the CPU before
  `vaBeginPicture`. Return the PipeWire buffer as soon as that fence signals. Run PipeWire on its own thread,
  and keep one conversion ahead of the encoder. Details and caveats are below.

## Method

Machine: Ryzen 9 9950X, iGPU `0000:79:00.0` (`renderD130`, `card3`, RADV/radeonsi `raphael_mendocino`, 2 CUs,
VCN 3.1.2), Mesa 26.0.8, libva 1.23, PipeWire 1.6.2, kernel 7.0.0-38, GNOME 50.1 on Wayland. HDMI-1 is at
3840×2160 at 60 Hz, and the developer's desktop was in use (idle apart from the spike). Measured 2026-10-31,
21:50–22:35.

Candidates (each one has its own README, written by its builder):
- **`gl/`** (`glconv.c`): a GL 4.6 compute shader through EGL on GBM. It reads the BGRx EGLImage with
  `texelFetch` and writes the Y (R8) and CbCr (GR88) layers of an exported VA NV12 surface with `imageStore`,
  one 2×2 block per invocation, in 16×8 workgroups.
- **`vk/`** (`vkconvert`, Rust/ash): a Vulkan compute pass on RADV's compute queue. It writes into
  Vulkan-allocated memory at libva's own tiled NV12 layout, exported as a DMA-BUF and imported into libva
  (`--out vk-tiled`, 16×8).
- **`vpp/`** (`vpp.c`): libva video processing, the driver's own conversion. It is called with
  `VAProcColorStandardBT709` on the input and full range on the output; the SRGB input standard changes the
  transfer function and gets the colours wrong.

Harness, in this directory:
- **`run-one.sh`** runs exactly one GPU program. It refuses to start if the kernel log shows amdgpu trouble in
  the last 2 minutes or another spike GPU program is running. It pins Mesa EGL, RADV and radeonsi, runs the
  program under `../linux-encoder/nvidia-guard.sh` with a timeout, and records `/proc/loadavg` and
  `gpu_busy_percent`: before and after, and sampled every 100 ms during the run. It then checks the kernel
  log again and pauses 4 s.
- **`virtmon.py`** creates lain's display as spike B does: a ScreenCast session, `RecordVirtual` with
  cursor-mode metadata, 2752×2064 at max 120 fps, which gives `Meta-0` at 2752×2064@120. It runs spike B's
  `gtkprobe.py` fullscreen on it, under the guard, with `GSK_RENDERER=gl` and Mesa EGL pinned. The probe's
  `full` mode (added here) changes every pixel each frame: an alternating background under 64 moving bars.
  Its two modes:
  - `load` runs a converter while spike B's `pwprobe` consumes the stream as DMA-BUF.
  - `e2e` lets `e2e/e2e` be the consumer.

  It compares the monitor layout before and after (identical in every run, and equal to the brief's
  snapshot). No `ApplyMonitorsConfig`, no input.
- **`e2e/e2e.c`** is a PipeWire DMA-BUF consumer in C (based on spike B's `pwprobe.c`). It keeps the newest
  picture (one slot, latest wins), converts it (GL compute, `--conv gl`; or VA video processing,
  `--conv vpp`), and encodes it with libva as spike A's `vaenc` does: HEVC Main, CBR 60 Mbps, a two-frame
  HRD, one reference, no B-frames, no periodic IDR, its own VPS/SPS/PPS. One encode is outstanding at a
  time. Its options:
  - `--loop thread` puts PipeWire on a `pw_thread_loop`.
  - `--pipeline` converts the next picture while the previous one encodes.

  Capture time is the buffer's `spa_meta_header.pts` (Mutter's frame time, CLOCK_MONOTONIC), and every
  timestamp is CLOCK_MONOTONIC. The measurement window is the 10 s after a 2 s warm-up.
- **`e2e/decode-check.py`** decodes a dumped stream in software with libde265 through ctypes, with no
  GStreamer and no GPU, under `../linux-encoder/fence.sh`. It compares the last picture with the NV12 that
  `e2e` read back from that frame's surface.

Safety:
- Every GPU program validated its buffers before submitting work: modifier, plane count, pitch, offsets and
  sizes checked against the DMA-BUF's real size (`lseek`), and VA exports checked layer by layer.
- Only one GPU program ran at a time, each one 1–12 s.
- The kernel log was clean before and after every run.
- The guard reported no non-AMD node opened in every run.

Raw output is in `results/`.

## Isolated conversion (measured)

2752×2064, one conversion in flight, 1200 conversions per row except where noted. GPU time comes from timer
queries or timestamps around the dispatch; VPP exposes none, so its column is CPU time from `vaEndPicture` to
`vaSyncSurface`. CPU wall time is from submit to the fence signalling.

| Candidate | Condition | GPU p50 / p95 / max (ms) | CPU wall p50 / p95 / max (ms) | Rate | loadavg (1 min) | gpu_busy mean |
|---|---|---|---|---|---|---|
| gl 16×8 | idle, back to back | 0.640 / 0.712 / 1.918 | 0.711 / 0.925 / 3.709 | 1306.6/s | 0.68 | 74% |
| gl 16×8 | idle, paced 120 Hz | 1.191 / 1.348 / 1.999 | 2.128 / 2.466 / 3.119 | 120.1/s | 0.86 | 32% |
| vk vk-tiled 16×8 | idle, back to back | 0.648 / 0.671 / 1.031 | 0.688 / 0.720 / 1.217 | 1412.1/s | 0.49 | 81% |
| vk vk-tiled 16×8 | idle, paced 120 Hz | 1.172 / 1.332 / 2.824 | 2.126 / 2.425 / 3.855 | 120.1/s | 0.57 | 29% |
| vpp (bt709 in) | idle, back to back (3 s, 1323 conversions) | n/a | 1.988 / 3.568 / 6.237 | 441.0/s | 0.45 | 96% |
| vpp (bt709 in) | idle, paced 120 Hz | n/a | 3.657 / 4.102 / 5.832 | 120.0/s | 0.41 | 48% |
| gl 16×8 | loaded, back to back | 0.655 / 2.643 / 3.333 | 0.733 / 2.744 / 3.404 | 947.8/s | 0.68 | 87% |
| gl 16×8 | loaded, paced 120 Hz | 2.972 / 3.319 / 4.927 | 3.900 / 4.376 / 6.141 | 120.1/s | 0.87 | 60% |
| vk vk-tiled 16×8 | loaded, back to back | 0.689 / 3.283 / 4.600 | 0.732 / 3.330 / 4.658 | 897.0/s | 0.45 | 90% |
| vk vk-tiled 16×8 | loaded, paced 120 Hz | 3.745 / 4.121 / 5.219 | 4.634 / 5.170 / 6.198 | 120.1/s | 0.53 | 57% |
| vpp (bt709 in) | loaded, back to back (3 s, 1020 conversions) | n/a | 2.083 / 4.537 / 5.824 | 339.8/s | 0.76 | 96% |
| vpp (bt709 in) | loaded, paced 120 Hz | n/a | 2.855 / 3.752 / 5.398 | 120.0/s | 0.98 | 70% |

Conditions:
- **"Idle"** is the developer's desktop with nothing animating.
- **"Loaded"** is the 120 Hz virtual monitor with `gtkprobe full` animating fullscreen. gtkprobe ticked 119–121/s
  and `pwprobe` received 119–121 pictures/s (DMA-BUF, modifier `0x200000000401b03`) throughout every loaded
  run.
- **Correctness:** every row's verification passed. gl and vk show Y and CbCr max error 0. vpp with BT.709
  input shows Y max 0 and Cb/Cr max 1, mean 0.009 and 0.042.

The first loaded runs of gl and vk (`results/stalled-stream-load-*.txt`) are not in the table. In them the
`pwprobe` pipe was never drained: it fills in about 4 s, after which pwprobe blocks and the stream stalls, so
Mutter stopped its per-frame copy into the stream for most of the run. The harness was fixed and the runs
redone. The stalled runs are kept because they are instructive: with the stream stalled, paced gl and vk took
GPU p50 0.95 and 0.86 ms, against 2.97 and 3.75 ms with the stream flowing.

## End to end (measured)

Each row is one `virtmon.py e2e full` run: `Meta-0` at 2752×2064@120, `gtkprobe full` ticking 114–121/s, and
the e2e consumer converting and encoding. Over the 10 s measurement window:

| Configuration | Delivered / encoded / dropped per s | Capture → AU p50 / p95 / max (ms) | Convert, GPU p50 / p95 (ms) | Convert, CPU wall p50 (ms) | Encode p50 / p95 (ms) | gpu_busy mean | loadavg |
|---|---|---|---|---|---|---|---|
| gl, main loop, serial | 104.8 / 104.8 / 0 | 13.79 / 19.42 / 21.39 | 0.74 / 3.12 | 1.28 | 7.72 / 8.05 | 62% | 0.64 |
| vpp, main loop, serial | 83.1 / 83.1 / 0 | 15.93 / 22.02 / 38.20 | n/a | 3.41 | 7.69 / 8.08 | 65% | 0.54 |
| gl, thread loop, serial | 119.9 / 105.8 / 14.1 | 13.62 / 19.31 / 22.37 | 0.71 / 3.07 | 1.24 | 7.70 / 8.00 | 62% | 0.54 |
| **gl, thread loop, pipelined** | **119.8 / 119.9 / 0** | **13.20 / 14.03 / 15.58** | 0.66 / 0.83 | 3.50 | 8.28 / 8.96 | 57% | 0.53 |
| gl, thread loop, pipelined (run 2) | 119.6 / 119.6 / 0 | 13.37 / 15.16 / 24.69 | 0.69 / 0.93 | 3.49 | 8.26 / 9.16 | 60% | 0.32 |
| vpp, thread loop, pipelined | 119.9 / 119.9 / 0 | 14.76 / 15.56 / 17.03 | n/a | 4.67 | 8.14 / 9.43 | 80% | 0.32 |
| vpp, thread loop, pipelined (run 2) | 119.0 / 117.5 / 1.6 | 15.20 / 19.54 / 35.76 | n/a | 4.83 | 8.19 / 9.86 | 83% | about 0.3 |

- **Delivery.** With the main loop, PTS → arrival is p50 5.0–5.5 ms, p95 7.6–7.8 ms. Mutter's buffers waited in
  PipeWire while the single thread converted and encoded, and Mutter skipped frames (PTS interval p95 16.7 ms).
  With `--loop thread`, PTS → arrival is p50 0.08–0.10 ms, p95 0.19–0.22 ms, and the PTS interval is p50 8.33
  ms, p95 8.36–8.37 ms. That is Mutter's full 120 Hz.
- **Serial cap.** Converting then encoding in sequence takes about 9.0 ms (1.24 + 7.70), so a thread-loop serial
  run encodes 105.8/s and drops the remaining 14.1/s (newest wins).
- **Pipelined.** The conversion's CPU wall time grows to 3.5 ms (GL) or 4.7 ms (VPP), because it now runs while
  VCN encodes. That doesn't matter: it is hidden behind the encode. A converted picture then waits p50
  0.07–0.24 ms for the encoder. The encode itself grows from 7.7 to 8.1–8.3 ms (p95 9.0–9.9 ms) when GFX
  runs alongside it. Nothing else changed between the two configurations, so the GFX work is the probable
  cause, through shared memory bandwidth or clocks; the mechanism is not verified.
- Every run used under 2% of one CPU core (3.4% in vpp run 2), and the stream averaged 59 Mbps in the
  pipelined runs. Cursor-only buffers: 2–10 per run.
- **Decode check** (`results/decode-check.txt`; libde265 in software under `fence.sh`). Each stream decodes
  completely with no errors or warnings: VPS, SPS, PPS, one IDR, then TRAIL_R pictures plus CBR filler NAL
  units. The last picture matches the NV12 read back from its surface:
  - gl pipelined: 1419/1419 pictures, Y PSNR 82.4 dB, Cb 74.9 dB, Cr 75.1 dB.
  - vpp pipelined: 1418/1418 pictures, Y PSNR 82.8 dB.
  - gl serial (main loop): 1246/1246 pictures, Y PSNR 82.5 dB.
  - vpp serial (main loop): 984/984 pictures, Y PSNR 82.9 dB.

  The PSNR is this high because the probe's content is flat colour; that says nothing about text quality.

## Correctness of the conversion (measured)

Read-back comparison against an f64 CPU reference of BT.709 full range on the non-linear values: Y = 0.2126 R +
0.7152 G + 0.0722 B, Cb = (B − Y)/1.8556 + 128, Cr = (R − Y)/1.5748 + 128, with chroma the mean over each 2×2
block, 8-bit, rounded and clamped.

- **gl:** read back through `vaGetImage` from the VA surface the encoder uses. Y and CbCr max error 0 on every
  checked frame, idle and loaded.
- **vk (vk-tiled):** read back through libva and through a Vulkan copy. Max error 0 on frames 0, 2 and 5 (idle)
  and frame 0 (loaded).
- **vpp:** exact only with `VAProcColorStandardBT709` on the input. Y max 0, Cb/Cr max 1.
  - With SRGB on the input, Mesa changes the transfer function: Y max error 7.
  - Limited, explicit or unset output ranges are worse: Y errors of 8–20.

  See `vpp/README.md`.
- The gl candidate must sample the imported XR24 EGLImage with `texelFetch`. Mesa imports it as `GL_RGB8`, which
  is not an image-unit format, so `imageLoad` silently returns garbage (Y max error 230) and raises no GL error.

## What is inferred, not measured

- **Clock drop on an idle GPU.** Idle conversions take about twice as long paced (1.2 ms) as back to back (0.65 ms),
  probably because the GPU clocks drop between frames (DPM `auto`; sclk levels 600/700/2200 MHz). The DPM level
  was never forced, which would need root and affect the whole desktop. In the pipelined end to end path the GPU
  stays busy, and the conversion runs at back-to-back speed (0.66–0.69 ms).
- **Paced runs under load.** These are slower than on an idle GPU (gl 2.97, vk 3.75 ms), and slower than the
  stalled-stream runs (about 0.9 ms). A plausible reading: the converter's own 120 Hz timer runs nearly in phase
  with Mutter's 120 Hz frame and per-frame stream copy, so it keeps colliding with them on the iGPU's 2 CUs.
  The phase depends on the run. Not verified; a pace off 120 Hz would sample every phase. The e2e path converts
  just after Mutter's frame arrives, and there the conversion is 0.66–0.74 ms.
- **GL against Vulkan.** They are equivalent on this hardware: within 0.05 ms everywhere in isolation, both
  memory-bound at about 45–49 GB/s. Only GL was wired into e2e. The vk-tiled surface is accepted by libva with
  the same modifier and pitches as libva's own NV12 surfaces, but the encoder was never run from it, so its
  end-to-end figures are an expectation only.
- **The 8.3 ms budget.** It no longer applies to the sum of conversion and encode: once pipelined, the frame
  interval only has to cover the larger of the two, which is the encode at 8.1–8.3 ms (p50). That is close to
  8.33 ms. The runs held 120 fps with zero drops (gl) and 0–1.6 drops/s (vpp), but there is little headroom.
  Heavier desktop GFX load could push the encode over the interval. A cheaper rate-control setting could buy
  margin, and so could finishing the frame faster (for example, slices handed over as they complete); neither
  was tested.
- **Latency.** Capture → AU of about 13.2 ms at p50 (pipelined) breaks down as follows:
  - up to one frame of waiting for the conversion slot;
  - the conversion (CPU wall 3.5 ms, with VCN busy);
  - about 0.1 ms waiting for the encoder;
  - the encode (8.3 ms).

  This is lower than spike A's 15.5–24 ms, and it comes at 120 fps instead of 70–90.

## Recommendation for `lain-linux-video`

- **Conversion method and API.** Use one compute pass on the iGPU: 2×2 block per invocation, 16×8 workgroups,
  BT.709 full range, written straight into the encoder's NV12 surface. Either GL (EGL on GBM, `texelFetch` input,
  `imageStore` into the R8/GR88 layers) or Vulkan on RADV (compute queue) works.
  - **For the Rust crate, prefer Vulkan (ash):** the same speed and exactness, explicit synchronisation and queue
    choice, and no EGL/GL context to manage from Rust. Mutter's buffers need a queue-family acquire from
    `VK_QUEUE_FAMILY_FOREIGN_EXT`.
  - Keep VA video processing as the fallback. It is exact with `VAProcColorStandardBT709` input and does reach
    120 fps pipelined, but it costs 3–5× more GFX time (gpu_busy 80–83% against 57–60%) and adds about 1.5 ms of
    latency.
  - If Vulkan has to write libva's own exported surface, see `vk/README.md`. Importing libva's exported NV12 into
    Vulkan reads back zeros (`va-tiled`, not understood). The working direction is Vulkan allocating at libva's
    layout and libva importing it (`vk-tiled`), which is not yet proven end to end with the encoder (the GL path
    is).
- **Zero-copy handoff:**
  - Mutter's DMA-BUF (BGRx, modifier `0x200000000401b03`) is imported once per PipeWire buffer.
  - It is converted into one of three NV12 surfaces that belong to the encode context. For GL these are
    `vaExportSurfaceHandle`, DRM PRIME 2, separate layers; for Vulkan, an exported allocation at the same layout
    imported with `vaCreateSurfaces`.
  - Each surface is encoded in place.
  - No CPU copy anywhere. Validate every import's modifier, pitch, offset and size against the DMA-BUF before
    use (as all the spike programs do).
- **Synchronisation:**
  - Wait on the conversion's fence on the CPU before `vaBeginPicture`, then return the PipeWire buffer at once
    (measured; cheap, since it overlaps the previous encode).
  - Implicit sync between GL and VA on the shared surface was not measured end to end. `e2e --sync implicit`
    exists, serial only, and was not run.
  - With Vulkan, a sync file exported from the conversion's semaphore could replace the CPU wait later; not
    needed for 120 Hz.
- **Structure:**
  - PipeWire on its own thread (a `pw_thread_loop` in C, or the `pipewire` crate's thread loop), only swapping
    the newest buffer into a one-slot holder.
  - A video thread that keeps one picture converted ahead and one encode outstanding.
  - The encoder's completion polled or waited with `vaSyncBuffer` (with a timeout, so the thread can take a newer
    capture meanwhile).

## What it means for D1

**Measured:** 2752×2064 at 120 Hz runs end to end on this iGPU at 119.6–119.9 fps with no drops. Capture →
AU is p50 13.2–13.4 ms and p95 14.0–15.2 ms, while a fullscreen client animates the virtual monitor at 120 Hz.
The configuration is GL compute conversion, PipeWire on its own thread, and conversion pipelined against the
encode. D1's premise ("70–90 fps because the conversion shares the GFX engine") no longer holds. Option (c),
a faster conversion, is done, and together with the pipelining it gives 120 Hz at full resolution without
options (b) or (d).

**Inferred:** the margin is thin. The encode at 8.1–8.3 ms p50 sits right at the 8.33 ms interval, so heavy
desktop GFX load, more complex content, or a slower rate-control mode could cost frames. Other GPU work
(browsers, games) on the same iGPU was not tested.

## Open questions

- An end to end run with the Vulkan converter (`vk-tiled` surface fed to the encoder), and the cause of the
  `va-tiled` zeros.
- The encode's slowdown when GFX runs alongside it (7.7 → 8.3 ms): memory bandwidth or clocks? It sets the
  margin at 120 Hz.
- Content: the end to end probe draws flat bars. Text-heavy content changes the encode time (spike A's scrolling
  text: 7.3 ms in isolation), not the conversion.
- Implicit sync between GL and VA (`e2e --sync implicit`), and Vulkan sync files: not measured.
- The paced-under-load phase effect (a pace off 120 Hz would show it).
- The earlier GPU reset (21:15, before this measurement) was attributed to Chrome. The machine's later panic
  (22:12–22:13) followed an `ath12k` Wi-Fi firmware crash with `iommu_dma_unmap_phys` warnings and logged no
  amdgpu errors. Both are recorded here only as context.
