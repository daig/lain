# Spike 6: a faster BGRx → NV12 conversion on the AMD iGPU

**Question.** Can BGRx → NV12 at 2752×2064 be made fast enough (goal about 1 ms; the pass is memory-bound,
about 22.7 MB read and 8.5 MB written per frame) that conversion plus HEVC encoding fits in 8.3 ms, so that
120 Hz end to end becomes reachable (decision D1)?

**Answer in short.**
- **Yes, 2752×2064 at 120 Hz is reachable end to end on this iGPU (measured).** The pipeline runs capture →
  convert → encode at **119.6–120.0 fps with 0–0.2 drops/s** (5 runs). Capture → access unit varies from run
  to run: **p50 13.1–16.2 ms, p95 14.0–19.2 ms** over 8 runs, measured while a fullscreen client animates the
  whole 120 Hz virtual monitor. The spread comes from the phase the loop settles into (see "Latency" below).
  This took two changes in how the host is built, not just a faster shader:
  1. **Service PipeWire on its own thread.** With the stream on the same thread as convert + encode, Mutter's
     frames sat in PipeWire for 5 ms (p50) and only 104.8/s were delivered.
  2. **Pipeline conversion against encoding.** The next picture is converted on GFX while the previous one
     encodes on VCN, with still one encode outstanding. Run in sequence, convert + encode takes about 9 ms
     and caps the rate at about 106 fps.
- **Conversion: one compute pass, GL and Vulkan alike, about 0.65 ms of GPU time (measured).** Back to back
  that is 31.2 MB read and written in 0.65 ms, about 48 MB/ms (48 GB/s). The output has **max error 1**
  against an f64 reference, from f32 rounding at ties: all 2^24 colours plus random pixels give Y and CbCr
  max 1, and under 0.01% of samples are off. It is bit-exact on the text-like test content. The 1 ms goal is
  met at p50 in the pipelined end to end path (GPU p50 0.66–0.75 ms), but **p95 is 0.74–1.44 ms** across runs.
  Paced at 120 Hz on an idle GPU it is 1.2 ms at p50, above the goal. That is probably the clocks dropping
  between frames (inferred, see below).
- **VA video processing works as a fallback but costs more, and its 120 fps did not hold up (measured).** In
  the first three pipelined runs it reached about 117–120 fps, with drops in two of them (117.4–119.9 fps,
  0–2.5 drops/s, capture → AU p95 15.6–22.5 ms), and gpu_busy was 80–83% against 57–60% for compute. Two
  later runs got only 94–96 fps (11–22 drops/s, gpu_busy 95–96%). Those used the corrected timing loop while
  the desktop's own GPU load was intermittent; the cause is not resolved (see "End to end"). VPP's conversion
  is 2.0 ms back to back and 2.9–3.7 ms paced, against 0.65 / 1.2 ms for compute. So spike A's 70–90 fps
  came mostly from the serial design. VPP's own cost made it worse, and GStreamer played no part in it.
- **Recommendation for `lain-linux-video`:** convert with a single compute pass into libva's own NV12 encoder
  surface, exported with `vaExportSurfaceHandle` (zero-copy). Wait on the conversion's fence on the CPU before
  `vaBeginPicture`. Return the PipeWire buffer as soon as that fence signals. Run PipeWire on its own thread,
  and keep one conversion ahead of the encoder. Collect the encoder's AU while the conversion runs, not after
  it. Re-phase when pictures start to queue for the encoder. Details and caveats are below.

## Method

Machine: Ryzen 9 9950X, iGPU `0000:79:00.0` (`renderD130`, `card3`, RADV/radeonsi `raphael_mendocino`, 2 CUs,
VCN 3.1.2), Mesa 26.0.8, libva 1.23, PipeWire 1.6.2, kernel 7.0.0-38, GNOME 50.1 on Wayland. HDMI-1 is at
3840×2160 at 60 Hz, and the developer's desktop was in use (idle apart from the spike until 22:55, then with
Chrome loading the iGPU off and on). Measured 2026-10-31, 21:50–22:35 and, after the review, 22:50–22:58.

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
  - **AU timing.** The first pipelined runs ("blocking wait" below) blocked in `glClientWaitSync` /
    `vaSyncSurface` during the conversion. An encode that finished meanwhile was only collected after the
    conversion, so its time was late by up to the conversion's 3.5–4.7 ms. The mean encode then equalled
    the frame period, 8.33 ms. The later runs ("polled") alternate 50 µs checks of the conversion's fence and
    the coded buffer (`vaSyncBuffer`; `vaSyncSurface2` for VPP), so the AU is timed within about 0.05 ms of
    the encode finishing. In those runs 750–1000 of about 1400 AUs per run were collected during a
    conversion.
- **`e2e/decode-check.py`** decodes a dumped stream in software with libde265 through ctypes, with no
  GStreamer and no GPU, under `../linux-encoder/fence.sh`. It compares the last picture with the NV12 that
  `e2e` read back from that frame's surface, the encoder's own input. **It validates the encode only, not
  the conversion.** The conversion was checked against the reference on GBM buffers with synthetic content
  (below), never on Mutter's own buffers in `e2e`.

Safety:
- Every GPU program validated its buffers before submitting work: modifier, plane count, pitch, offsets and
  sizes checked against the DMA-BUF's real size (`lseek`), and VA exports checked layer by layer.
- Only one GPU program ran at a time, each one 1–12 s.
- The kernel log was clean before and after every run.
- The guard reported no non-AMD node opened in every run.

Raw output is in `results/`.

## Isolated conversion (measured)

2752×2064, one conversion in flight, 1200 conversions per row except where noted (the vpp program runs for a
fixed time, `--seconds`, so its back-to-back rows have other counts). GPU time comes from timer
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
| vpp (bt709 in) | loaded, back to back (4 s, 1315 conversions; `load-vpp-full-4s.txt`) | n/a | 2.226 / 4.618 / 6.629 | 328.7/s | 0.63 | 97% |
| vpp (bt709 in) | loaded, paced 120 Hz | n/a | 2.855 / 3.752 / 5.398 | 120.0/s | 0.98 | 70% |

Conditions:
- **"Idle"** is the developer's desktop with nothing animating.
- **"Loaded"** is the 120 Hz virtual monitor with `gtkprobe full` animating fullscreen. gtkprobe ticked 119–121/s
  and `pwprobe` received 119–121 pictures/s (DMA-BUF, modifier `0x200000000401b03`) throughout every loaded
  run.
- **Correctness:** every row's verification passed. On their text-like content gl and vk show Y and CbCr
  max error 0; over all colours both are max 1 (see "Correctness of the conversion"). vpp with BT.709 input
  shows Y max 0 and Cb/Cr max 1, mean 0.009 and 0.042.

The first loaded runs of gl and vk (`results/stalled-stream-load-*.txt`) are not in the table. In them the
`pwprobe` pipe was never drained: it fills in about 4 s, after which pwprobe blocks and the stream stalls, so
Mutter stopped its per-frame copy into the stream for most of the run. The harness was fixed and the runs
redone. The 3 s loaded vpp back-to-back run in `load-vpp.txt` (1020 conversions, p50 2.083 ms, 339.8/s)
fell short of 1200 conversions and was redone for 4 s. The stalled runs are kept because they are instructive: with the stream stalled, paced gl and vk took
GPU p50 0.95 and 0.86 ms, against 2.97 and 3.75 ms with the stream flowing.

## End to end (measured)

Each row is one `virtmon.py e2e full` run: `Meta-0` at 2752×2064@120, `gtkprobe full` ticking 114–121/s, and
the e2e consumer converting and encoding. Over the 10 s measurement window:

| Configuration | Delivered / encoded / dropped per s | Capture → AU p50 / p95 / max (ms) | Convert, GPU p50 / p95 (ms) | Convert, CPU wall p50 (ms) | Encode p50 / p95 (ms) | gpu_busy mean | loadavg |
|---|---|---|---|---|---|---|---|
| gl, main loop, serial | 104.8 / 104.8 / 0 | 13.79 / 19.42 / 21.39 | 0.74 / 3.12 | 1.28 | 7.72 / 8.05 | 62% | 0.64 |
| vpp, main loop, serial | 83.1 / 83.1 / 0 | 15.93 / 22.02 / 38.20 | n/a | 3.41 | 7.69 / 8.08 | 65% | 0.54 |
| gl, thread loop, serial | 119.9 / 105.8 / 14.1 | 13.62 / 19.31 / 22.37 | 0.71 / 3.07 | 1.24 | 7.70 / 8.00 | 62% | 0.54 |
| gl, thread loop, pipelined, blocking wait | 119.8 / 119.9 / 0 | 13.20 / 14.03 / 15.58 | 0.66 / 0.83 | 3.50 | (8.28 / 8.96, late) | 57% | 0.53 |
| gl, thread loop, pipelined, blocking wait (run 2) | 119.6 / 119.6 / 0 | 13.37 / 15.16 / 24.69 | 0.69 / 0.93 | 3.49 | (8.26 / 9.16, late) | 60% | 0.32 |
| **gl, thread loop, pipelined, polled** | **120.0 / 120.0 / 0** | **13.20 / 14.72 / 16.33** | 0.70 / 1.04 | 3.86 | **7.94 / 8.50** | 61% | 0.16 |
| gl, thread loop, pipelined, polled (run 2) | 119.8 / 119.7 / 0.2 | 13.11 / 17.12 / 29.12 | 0.73 / 1.11 | 3.52 | 7.97 / 8.73 | 65% | 1.64 |
| gl, thread loop, pipelined, polled (run 3) | 119.9 / 120.0 / 0 | 13.28 / 16.20 / 18.61 | 0.75 / 1.21 | 3.79 | 8.01 / 8.93 | 63% | 2.04 |
| vpp, thread loop, pipelined, blocking wait | 119.9 / 119.9 / 0 | 14.76 / 15.56 / 17.03 | n/a | 4.67 | (8.14 / 9.43, late) | 80% | 0.32 |
| vpp, thread loop, pipelined, blocking wait (run 2) | 119.0 / 117.5 / 1.6 | 15.20 / 19.54 / 35.76 | n/a | 4.83 | (8.19 / 9.86, late) | 83% | about 0.3 |
| vpp, thread loop, pipelined, polled | 105.1 / 94.1 / 11.1 | 19.89 / 25.50 / 30.37 | n/a | 8.02 | 8.05 / 10.25 | 95% | 1.81 |
| vpp, thread loop, pipelined, polled (run 2) | 117.5 / 95.6 / 21.9 | 21.45 / 26.28 / 38.14 | n/a | 8.44 | 8.68 / 10.55 | 96% | 0.95 |

A review rerun of the unmodified blocking-wait binary (its raw output is not in `results/`) gave:
- gl pipelined, three runs: capture → AU p50/p95 13.22/15.49, 13.47/15.25 and 16.15/19.18 ms (max 22.08), and
  conversion GPU p95 0.74–1.44 ms. In the third run the converted picture waited p50 3.19 / p95 5.32 ms for
  the encoder.
- vpp pipelined, one run: 117.4 encoded / 2.5 dropped per s, capture → AU p95 22.46 ms (max 29.32).

The polled gl runs 2 and 3 and both polled vpp runs ran while the developer's Chrome loaded the iGPU off and
on: loadavg 1–2, and with no spike program running gpu_busy sampled a mean of 7–30% with bursts to 100%. The
first polled gl run had an idle desktop (loadavg 0.16).

- **Delivery.** With the main loop, PTS → arrival is p50 5.0–5.5 ms, p95 7.6–7.8 ms. Mutter's buffers waited in
  PipeWire while the single thread converted and encoded, and Mutter skipped frames (PTS interval p95 16.7 ms).
  With `--loop thread`, PTS → arrival is p50 0.08–0.10 ms, p95 0.19–0.22 ms, and the PTS interval is p50 8.33
  ms, p95 8.36–8.37 ms. That is Mutter's full 120 Hz.
- **Serial cap.** Converting then encoding in sequence takes about 9.0 ms (1.24 + 7.70), so a thread-loop serial
  run encodes 105.8/s and drops the remaining 14.1/s (newest wins).
- **Pipelined.**
  - **Conversion wall time.** The conversion's CPU wall time grows to 3.5–3.9 ms (GL; 4.7 ms VPP, 8.0–8.4 ms
    in the polled VPP runs), while its GPU time stays at 0.66–0.75 ms. Why is not measured. It may be that the
    conversion now runs while VCN encodes. It may equally be that, starting about 0.1 ms after the frame
    arrives, it waits on the implicit fence of Mutter's own copy into the buffer. GFX and VCN are separate
    engines, which favours the second. Timing a sync_file export and poll on the input DMA-BUF would tell. The
    wait is hidden behind the encode either way.
  - **The encode, timed correctly (polled):** p50 7.94–8.01 ms, mean 7.97–8.09 ms, p95 8.50–8.93 ms. Serial,
    it is 7.70 ms. So pipelining costs it about 0.25–0.3 ms; the cause (shared memory bandwidth or clocks) is
    not verified. The blocking-wait runs' 8.26–8.28 ms (mean 8.33–8.34, exactly the frame period) were a
    timing artifact (see "AU timing" above), and so was part of their capture → AU. On average the encoder
    has 0.25–0.35 ms of slack per 8.33 ms frame.
  - **Waiting for the encoder.** A converted picture waits for the encoder p50 0.00 ms, p95 0.97–2.97 ms
    (polled). In one of the review's blocking-wait runs it waited p50 3.19 ms; see "Latency".
- **VPP, polled.** Both polled VPP runs fell to 94–96 fps, against 117–120 fps in the three blocking-wait runs.
  The conversion's wall time doubled (8.0–8.4 ms), gpu_busy was 95–96%, and in the first run Mutter itself
  skipped frames (105.1 delivered/s, PTS interval p95 16.7 ms). Two causes fit, and they were not separated:
  - the desktop's concurrent GPU load;
  - the polling itself, `vaSyncSurface2` and `vaSyncBuffer` every 50 µs on the same VA display, perturbing
    the VPP path.
  
  The gl path's figures did not change under the same polling.
- Every run used under 2.5% of one CPU core (3.4% in vpp run 2), and the stream averaged 59 Mbps in the gl
  pipelined runs. Cursor-only buffers: 1–10 per run (32 and 189 in the polled VPP runs).
- **Decode check** (`results/decode-check.txt`; libde265 in software under `fence.sh`). Each stream decodes
  completely with no errors or warnings: VPS, SPS, PPS, one IDR, then TRAIL_R pictures plus CBR filler NAL
  units. The last picture matches the NV12 read back from its surface:
  - gl pipelined: 1419/1419 pictures, Y PSNR 82.4 dB, Cb 74.9 dB, Cr 75.1 dB.
  - vpp pipelined: 1418/1418 pictures, Y PSNR 82.8 dB.
  - gl serial (main loop): 1246/1246 pictures, Y PSNR 82.5 dB.
  - vpp serial (main loop): 984/984 pictures, Y PSNR 82.9 dB.

  The PSNR is this high because the probe's content is flat colour; that says nothing about text quality.
  The reference is the encoder's own input surface, so this verifies the encode, not BGRx → NV12. The
  reference frame has only 6 distinct Y values. Comparing a converted Mutter frame with the CPU reference
  (dumping one captured BGRx buffer from `e2e`) was not done.

## Correctness of the conversion (measured)

Read-back comparison against an f64 CPU reference of BT.709 full range on the non-linear values: Y = 0.2126 R +
0.7152 G + 0.0722 B, Cb = (B − Y)/1.8556 + 128, Cr = (R − Y)/1.5748 + 128, with chroma the mean over each 2×2
block, 8-bit, rounded and clamped.

- **gl and vk: max error 1 (f32 rounding at ties); bit-exact only on the test content.**
  - **Test content.** The measured runs used text-like content with few colours (gl: a dark background, five
    palette colours and one 0.45 antialiasing blend; vk: a background and five colours, no blending). On it,
    both converters have Y and CbCr max error 0 on every checked frame, idle and loaded. gl was read back
    through `vaGetImage` from the encoder's VA surface. vk (vk-tiled) was read back through libva and through
    a Vulkan copy, on frames 0, 2 and 5 idle and frame 0 loaded.
  - **All colours** (`--content allcolors`: ring frames 0–2 hold each of the 2^24 colours once, one per pixel;
    the rest hold random pixels; all 8 ring frames checked):
    - gl (`results/allcolors-gl.txt`): Y max 1, mean 0.00007–0.00009 (418–511 of 5.68 M samples off by 1
      per frame). CbCr max 1, mean up to 0.00006 (0–175 of 2.84 M samples). Nothing off by more than 1.
    - vk (`results/allcolors-vk.txt`): Y max 1, mean 0.00004–0.00006 (213–318 samples). CbCr max 1, mean up
      to 0.00004 (19–126 samples). Identical through libva and through Vulkan.

    The shaders compute in f32 and the reference in f64, so values that land on a rounding tie can go either
    way. That is harmless for video.
- **vpp:** accurate only with `VAProcColorStandardBT709` on the input: Y max 0, Cb/Cr max 1 on its content,
  which includes pure red, pure blue and white.
  - With SRGB on the input, Mesa changes the transfer function: Y max error 7.
  - Limited, explicit or unset output ranges are worse: Y errors of 8–20.

  See `vpp/README.md`.
- The gl candidate must sample the imported XR24 EGLImage with `texelFetch`. Mesa imports it as `GL_RGB8`, which
  is not an image-unit format, so `imageLoad` silently returns garbage (Y max error 230) and raises no GL error.

## What is inferred, not measured

- **Clock drop on an idle GPU.** Idle conversions take about twice as long paced (1.2 ms) as back to back (0.65 ms),
  probably because the GPU clocks drop between frames (DPM `auto`; sclk levels 600/700/2200 MHz). The DPM level
  was never forced, which would need root and affect the whole desktop. In the pipelined end to end path the GPU
  stays busy, and the conversion runs at about back-to-back speed at p50 (0.66–0.75 ms). Its p95 is
  0.74–1.44 ms, so the 1 ms goal is not always met there either.
- **Paced runs under load.** These are slower than on an idle GPU (gl 2.97, vk 3.75 ms), and slower than the
  stalled-stream runs (about 0.9 ms). A plausible reading: the converter's own 120 Hz timer runs nearly in phase
  with Mutter's 120 Hz frame and per-frame stream copy, so it keeps colliding with them on the iGPU's 2 CUs.
  The phase depends on the run. Not verified; a pace off 120 Hz would sample every phase. The e2e path converts
  just after Mutter's frame arrives, and there the conversion is 0.66–0.75 ms at p50.
- **GL against Vulkan.** They are equivalent on this hardware: within 0.05 ms everywhere in isolation, both
  memory-bound at about 45–49 GB/s. Only GL was wired into e2e. The vk-tiled surface is accepted by libva with
  the same modifier and pitches as libva's own NV12 surfaces, but the encoder was never run from it, so its
  end-to-end figures are an expectation only.
- **The 8.3 ms budget.** It no longer applies to the sum of conversion and encode: once pipelined, the frame
  interval only has to cover the larger of the two. That is the encode, at p50 7.94–8.01 ms and mean
  7.97–8.09 ms (polled), against 8.33 ms. The gl runs held 120 fps with 0–0.2 drops/s, but the headroom is
  about 0.25–0.35 ms (3–4%) on average, and the encode's p95 (8.50–8.93 ms) is over the interval. Heavier
  desktop GFX load could push the encode over the interval. A cheaper rate-control setting could buy margin,
  and so could finishing the frame faster (for example, slices handed over as they complete); neither was
  tested.
- **Latency.** Capture → AU at p50 (pipelined, gl) breaks down as follows:
  - up to one frame of waiting for the conversion slot;
  - the conversion (CPU wall 3.5–3.9 ms; see "Conversion wall time" for why it is not 0.7);
  - waiting for the encoder (p50 0.00 ms; p95 up to 3 ms);
  - the encode (about 8.0 ms).

  It depends on the phase the loop falls into. Over 8 gl pipelined runs the p50 was 13.1–13.5 ms in seven and
  16.15 ms in one, and the p95 was 14.0–19.2 ms. In the slow run, a review rerun with the blocking wait, each
  converted picture waited p50 3.19 ms for the encoder. The encoder's slack is small (about 0.3 ms per frame
  on average, less when it slows), so a phase in which pictures queue behind it clears slowly or not at all.
  The phase effect is measured; why the slow phase persisted is inferred. A host cannot count on the
  low-latency phase without realigning explicitly: for example, dropping a frame or re-phasing the conversion
  when the wait for the encoder grows. Even the slow run's p50 (16.15 ms) is at the low end of spike A's
  15.5–24 ms, and it comes at 120 fps instead of 70–90.

## Recommendation for `lain-linux-video`

- **Conversion method and API.** Use one compute pass on the iGPU: 2×2 block per invocation, 16×8 workgroups,
  BT.709 full range, written straight into the encoder's NV12 surface. Either GL (EGL on GBM, `texelFetch` input,
  `imageStore` into the R8/GR88 layers) or Vulkan on RADV (compute queue) works.
  - **For the Rust crate, prefer Vulkan (ash):** the same speed and accuracy (max error 1), explicit synchronisation and queue
    choice, and no EGL/GL context to manage from Rust. Mutter's buffers need a queue-family acquire from
    `VK_QUEUE_FAMILY_FOREIGN_EXT`.
  - Keep VA video processing as the fallback. It is accurate with `VAProcColorStandardBT709` input (Y max 0,
    Cb/Cr max 1), but it costs 3–5× more GFX time (gpu_busy 80–83% against 57–60%) and adds about 1.5 ms of
    latency. Pipelined, it reached about 117–120 fps with drops in two of three runs, and 94–96 fps in two
    later runs (cause unresolved; see "VPP, polled"). It is not a 120 Hz path to count on.
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
    capture meanwhile). Poll it during the wait for the conversion too, or wait for it on its own thread. Then
    an AU is handed on when it is ready, not when the next conversion ends.
  - Watch the wait between conversion done and encode submit. If it grows (the slow phase in "Latency"), drop
    a frame or re-phase the conversion to get back to the low-latency phase.

## What it means for D1

**Measured:** 2752×2064 at 120 Hz runs end to end on this iGPU at 119.6–120.0 fps with 0–0.2 drops/s, while a
fullscreen client animates the virtual monitor at 120 Hz. Capture → AU depends on the run's phase: p50
13.1–13.5 ms in seven of 8 runs and 16.15 ms in one, and p95 14.0–19.2 ms.
The configuration is GL compute conversion, PipeWire on its own thread, and conversion pipelined against the
encode. D1's premise ("70–90 fps because the conversion shares the GFX engine") no longer holds. Option (c),
a faster conversion, is done, and together with the pipelining it gives 120 Hz at full resolution without
options (b) or (d).

**Inferred:** the margin is thin. The encode, timed correctly, takes p50 7.94–8.01 ms and mean 7.97–8.09 ms
when pipelined, against the 8.33 ms interval. That leaves about 0.25–0.35 ms (3–4%) on average, and its p95
(8.5–8.9 ms) is over the interval. Heavy desktop GFX load, more complex content, or a slower rate-control mode
could cost frames. With so little slack, the low-latency phase is not guaranteed without an explicit
realignment (drop or re-phase when the wait for the encoder grows). Two gl runs had the developer's browser
loading the iGPU off and on and still held 120 fps, but heavier GPU work (games, video) on the same iGPU was
not tested.

## Open questions

- An end to end run with the Vulkan converter (`vk-tiled` surface fed to the encoder), and the cause of the
  `va-tiled` zeros.
- The encode's slowdown when GFX runs alongside it (7.70 → 7.94–8.01 ms p50, polled): memory bandwidth or
  clocks? It sets the margin at 120 Hz.
- Why the pipelined conversion's wall time is 3.5–3.9 ms for 0.7 ms of GPU work: VCN overlap or the implicit
  fence of Mutter's copy (time a sync_file export and poll on the input DMA-BUF).
- Why VPP fell to 94–96 fps in the polled runs: the desktop's concurrent GPU load, or the 50 µs
  `vaSyncSurface2` / `vaSyncBuffer` polling. A polled VPP run on an idle desktop would tell.
- Conversion correctness on Mutter's own buffers (a captured BGRx frame from `e2e` against the CPU reference).
- Re-phasing: detect the slow latency phase and recover from it.
- Content: the end to end probe draws flat bars. Text-heavy content changes the encode time (spike A's scrolling
  text: 7.3 ms in isolation), not the conversion.
- Implicit sync between GL and VA (`e2e --sync implicit`), and Vulkan sync files: not measured.
- The paced-under-load phase effect (a pace off 120 Hz would show it).
- The earlier GPU reset (21:15, before this measurement) was attributed to Chrome. The machine's later panic
  (22:12–22:13) followed an `ath12k` Wi-Fi firmware crash with `iommu_dma_unmap_phys` warnings and logged no
  amdgpu errors. Both are recorded here only as context.
