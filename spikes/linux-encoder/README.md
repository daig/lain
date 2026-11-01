# Spike A: HEVC encode on the AMD iGPU (open spike 1)

**Question.** Which technology gives lain the lowest-latency HEVC Main 4:2:0 8-bit encoding on the AMD iGPU at
2752×2064 and 120 Hz, and how should `lain-linux-video` drive it?

**Answer in short.**
- The encoder hardware sets the speed, not the API. At 2752×2064 from NV12, VCN 3.1.2 takes **7.3 ms (p50),
  7.7–7.9 ms (p95)** per frame with one request outstanding, and sustains 120 fps.
  - libva directly gets this with the driver's default preset.
  - GStreamer `vah265enc` gets exactly the same with `target-usage=2` (or 3). Its default (4) and 5–7 add a
    pre-encode pass: 9.2 ms, about 107 fps.
- **Capture → AU at 120 Hz is out of reach at 2752×2064.** Mutter delivers BGRx/ARGB, and the BGRx→NV12 conversion
  on the GFX engine (VA-API VPP, through `vapostproc`) adds 3.5–5.6 ms. End to end that is 10–13 ms, 74–92 fps.
  At 2064×1548 it is 8.6 ms and 116 fps.
- Capture is **zero-copy**: `pipewiresrc` negotiates DMA-BUF (`AR24`, AMD tiled modifier `0x0200000000401b03`),
  and `vapostproc` imports, converts and scales it on the GPU, at 5 % of one CPU core.
- **Control differs a lot.** libva gives an IDR on exactly the requested frame at the cost of a P-frame (7.2 ms,
  about 250 KB under a two-frame HRD), and any QP per frame. `vah265enc` has three problems:
  - It enforces a CPB of at least 2 s, so forced IDRs are 1.35–2.0 MB and take 13–16 ms.
  - Above its 2.14 MB coded buffer it emits a **corrupt access unit**: every late forced IDR on text content.
  - It has no per-frame QP: changing a QP property restarts the sequence with an IDR, or takes effect frames later.
- FFmpeg `hevc_vaapi` was **not tried**: its development headers aren't installed (`pkg-config libavcodec`:
  not found, no `/usr/include/libavcodec`, no `ffmpeg` binary; checked 2026-10-31).

## Machine

Ryzen 9 9950X, Radeon iGPU at PCI `0000:79:00.0`, `/dev/dri/renderD130`, `card3`: GC 10.3.6 and **VCN 3.1.2, one
instance** (from `ip_discovery`). Mesa 26.0.8 (radeonsi, `raphael_mendocino`), libva 1.23, GStreamer 1.28.2,
PipeWire GStreamer plugin 1.6.2, kernel 7.0.0-38, GNOME 50.1 on Wayland. HDMI-1 is 3840×2160 at 60 Hz. The
NVIDIA nodes (renderD128 and renderD129) were never opened: GStreamer's VA plugin lists only the AMD device, and
both tools refuse any render node whose PCI vendor isn't `0x1002`.

Encoder capabilities (libva, `vaenc --query`):
- Input formats: **NV12 only**. No RGB input, so a colour conversion is unavoidable.
- Rate control: CBR, VBR, CQP and QVBR.
- References: **one** L0 reference at most, so `ref-frames=1` is all there is.
- Supported: packed headers (sequence, picture, slice, misc and raw), ROI, intra refresh, max frame size.
- Not supported: tiles.

## Method

All times are `CLOCK_MONOTONIC`. Every run prints `/proc/loadavg` before and after; the tables give the 1-minute
figure from before the run. Other agents were compiling Rust at times, and the desktop was in use.

**Content.** `text` is a scrolling-terminal pattern: rows of glyph-sized, high-frequency blobs in five colours
on a dark purple background, scrolled 18 px (one line) per frame and periodic, so the 32-frame ring wraps
seamlessly. `smpte` and `zone-plate` (videotestsrc, moving) were run for comparison. Content changes encode time
by less than 0.5 ms; zone-plate is the worst case. The ring is made once on the GPU (VA surfaces), and the timed
loop never touches pixels on the CPU.

**Request model (lain's).** Ticks at 120 Hz "capture" ring frame *k*. Whenever no request is outstanding, the
newest tick not yet encoded is submitted, so a slow encode skips content rather than queueing it. fps is
encodes per second of wall time.

**`encbench synth`** (Rust, gstreamer-rs 0.25, `src/synth.rs`) builds this pipeline:

```
appsrc ! vapostproc ! video/x-raw(memory:VAMemory),format=NV12 ! vah265enc ! fakesink
```

Pad probes time each stage. "Encode" runs from the buffer arriving at the `vah265enc` sink pad to the AU
leaving its src pad. "push → AU" runs from `appsrc.push_buffer` to the AU leaving the encoder. Outputs are
matched to inputs in order, because the encoder rewrites timestamps.

`--ring-format NV12` makes the ring NV12, so `vapostproc` passes through and the encode is measured alone.
`--csc-at-capture` converts every tick's frame on a capture thread (appsrc → vapostproc → a latest-wins appsink)
and encodes the newest converted frame. A forced IDR is a `force-key-unit` event pushed from a probe in the
streaming thread, immediately ahead of its frame.

**`vaenc`** (C, `vaenc/vaenc.c`, libva directly) runs one frame at a time on the same tick model:

```
parameter buffers → vaBeginPicture/RenderPicture/EndPicture → vaSyncBuffer → vaMapBuffer
```

It works on NV12 surfaces only, with CBR plus an HRD buffer of two frames, `intra_period` 0, one reference and
no packed headers. `--quality` sends `VAEncMiscParameterBufferQualityLevel`. Without it the driver default is
used.

**`encbench live`** (`src/live.rs`) captures with Mutter `ScreenCast.RecordMonitor("HDMI-1", cursor-mode 2)`
through zbus and encodes every frame Mutter delivers:

```
pipewiresrc path=<node> always-copy=false ! vapostproc ! NV12 VAMemory 2752×2064 ! vah265enc
```

It records the memory type of every captured buffer and the negotiated caps. Mutter sends frames only on damage,
so `--keepalive-ms` re-sends the last frame to time an idle desktop at a steady rate (the content is then
static). `--shm` forces system-memory caps (the fallback). The session is stopped and the D-Bus connection
closed at the end.

**Helpers.**
- `sweep.sh` and `vaenc-sweep.sh` run one option set per stdin line.
- `gpu-sample.sh` samples `pp_dpm_vclk`/`dclk`/`sclk` and the busy counters during a run.
- `range-check.py` checks the range `vapostproc` converts with.

### Reproduce

```
cd spikes/linux-encoder
cargo build --release && make -C vaenc
./target/release/encbench synth --seconds 10 --tu 2 --ring-format NV12      # encode only
./target/release/encbench synth --seconds 10 --tu 2                         # BGRx: convert + encode
./target/release/encbench synth --seconds 10 --tu 2 --csc-at-capture        # convert on capture
./target/release/encbench synth --seconds 10 --tu 2 --ring-format NV12 --idr-every 120 --refine-every 60
./target/release/encbench live  --seconds 10 --tu 2 --keepalive-ms 5        # RecordMonitor, DMA-BUF
./target/release/encbench live  --seconds 10 --tu 2 --keepalive-ms 16 --shm
./vaenc/vaenc --query
./vaenc/vaenc --seconds 10 --idr-every 120
./vaenc/vaenc --seconds 4 --rc cqp --qp 30 --refine-every 60 --refine-qp 18
./gpu-sample.sh ./target/release/encbench synth --seconds 4
python3 -I range-check.py
```

`encbench` options:
- Size, rate and content: `--width --height --fps --seconds --content text|smpte|zone-plate|ball --ring --step`.
- Encoder: `--rc cbr|vbr|cqp|qvbr --bitrate <kbps> --tu 1..7 --ref --keyint --cpb-frames N`, and `--enc prop=value`
  for any other `vah265enc` property.
- Request model: `--inflight N --queue`.
- Keyframes and refinement: `--idr-every N --refine-every N --refine-count 2 --refine-set p=v,... --refine-reset p=v,...`.
- Output: `--colorimetry 1:3:7:1 --dump file.h265 --codec h264`.

The defaults are 2752×2064, 120 Hz, CBR 60 Mbps, `b-frames=0`, `ref-frames=1`, `key-int-max=1024` and TU 7.

## Results

All at 2752×2064, 120 Hz ticks, one request outstanding, `text` content, CBR 60 Mbps, no B-frames, one
reference, unless stated otherwise.

### Encode alone (NV12 input)

| Path | p50 ms | p95 ms | fps | CPU (one core) | load | run |
|---|---|---|---|---|---|---|
| libva, driver default preset | 7.33 | 7.86 | 120.0 | 0.9 % | 0.08 | 10 s |
| libva, quality level 32 | 7.29 | 7.61 | 120.0 | 0.8 % | 0.82 | 4 s |
| libva, quality level 1 | 8.26 | 8.73 | 119.3 | 0.6 % | 1.06 | 4 s |
| libva, quality level 4 or 7 | 9.02 | 9.51–9.57 | 110.0 | 0.8 % | 0.97 / 0.90 | 4 s |
| `vah265enc` TU 2 | 7.32 | 7.67 | 119.9 | 2.5 % | 0.22 | 10 s |
| `vah265enc` TU 3 | 7.31 | 7.62 | 120.0 | 2.6 % | 0.27 | 4 s |
| `vah265enc` TU 1 | 8.51 | 9.69 | 116.0 | 3.1 % | 1.55 | 4 s |
| `vah265enc` TU 4 (its default) | 9.19 | 10.02 | 106.9 | 3.3 % | 1.55 | 4 s |
| `vah265enc` TU 5 / 6 | 9.15 / 9.08 | 10.38 / 9.70 | 107–108 | 2.5–2.8 % | 0.25 / 0.23 | 4 s |
| `vah265enc` TU 7, `zone-plate` / `smpte` | 9.48 / 9.59 | 9.97 / 9.97 | 104–105 | 3–4 % | 1.32 / 1.29 | 4 s |
| `vah264enc` (H.264, for scale), TU 7 | 18.97 | 19.24 | 52.5 | 3.1 % | 1.27 | 4 s |
| libva at 2064×1548 | 4.47 | 4.89 | 120.1 | 1.1 % | 0.70 | 4 s |
| `vah265enc` TU 7 at 2064×1548 | 5.49 | 5.77 | 120.0 | 2.8 % | 1.94 | 4 s |

- **The GStreamer overhead is nil.** TU 2 equals the libva floor to within 0.02 ms, and the CPU submit in libva
  is 0.01 ms.
- Mesa reads VA's quality level as a bitfield. By measurement, levels 2, 3, 32 and "not sent" give the fast
  preset; 1 is slower; 4–7 are slowest (consistent with bit 2 enabling a pre-encode pass, which is an inference).
  GStreamer always sends `target-usage`, so lain must set it to **2**.
- These made no difference: `num-slices=4`, `mbbrc=disabled`, `ref-frames=2` (the hardware allows one anyway),
  CBR against VBR against CQP.
- Pipelining (`--queue --inflight 2`, TU 7) raised throughput to 98.6 fps but doubled push → AU to 20.2 ms.
  It doesn't suit lain's one-outstanding rule.
- During encoding `vclk` sits at its top state, 1200 MHz. `vcn_busy_percent` always reads 0 on VCN 3.

### Convert + encode (BGRx input, as captured)

| Path | p50 ms | p95 ms | fps | CPU | load |
|---|---|---|---|---|---|
| TU 2, convert on request (vapostproc inline), 10 s | 12.94 | 13.86 | 73.4 | 5.4 % | 0.20 |
| same, another 4 s run | 11.46 | 12.84 | 83.7 | 5.4 % | 0.10 |
| TU 2, convert on capture, newest converted frame encoded, 10 s | 10.04 | 13.88 | 91.9 | 4.2 % | 0.27 |
| TU 7, convert on request, 10 s | 13.13 | 14.64 | 73.5 | 3.0 % | 1.55 |
| TU 7, convert on request, 2064×1548 | 8.61 | 8.93 | 116.1 | 4.2 % | 2.11 |
| TU 7, convert on request, 1920×1080 | 6.21 | 6.68 | 119.2 | 4.1 % | 1.32 |

- The conversion runs on the GFX engine, at a cost that varies with the GFX clock: `sclk` swings between 600 and
  2200 MHz under this bursty load.
- "vapostproc in → encoder in" is 0.01 ms, because VPP work is queued, not waited for. Its cost shows up inside
  the encode span.
- Converting on capture overlaps the conversion with the previous encode, but converts at 120 Hz on a two-CU iGPU
  that also composites the desktop. The encode itself slows (p50 10 ms rather than 7.3 ms).

### Real capture: RecordMonitor HDMI-1, 3840×2160 at 60 Hz → 2752×2064, TU 2

| Path | capture → AU p50 | p95 | fps delivered | CPU | load |
|---|---|---|---|---|---|
| DMA-BUF, keepalive 5 ms | 11.37 | 12.23 | 54.7 | 4.9 % | 0.27 |
| DMA-BUF, keepalive 16 ms | 11.72 | 12.78 | 35.6 | 5.0 % | 0.21 |
| shared memory (forced) | 17.35 | 19.39 | 27.2 | 10.2 % | 0.22 |

- Negotiated caps: `video/x-raw(memory:DMABuf), format=DMA_DRM, drm-format=AR24:0x0200000000401b03`. Every
  buffer came from `GstDmaBufAllocator`, and `vapostproc` produced `video/x-raw(memory:VAMemory),format=NV12`
  directly. **Zero-copy holds**.
- The shared-memory fallback (`BGRA` in memfd) costs an upload: +6 ms and twice the CPU.
- The idle desktop delivered 4 frames in 10 s without keepalive, which is why keepalive was used.

### Forced IDR

**libva.** All 9 forced IDRs were IRAP on exactly the requested frame. They cost 7.22 ms p50 and 7.71 ms p95, as
much as a P-frame, at 214–290 KB under CBR with a two-frame HRD buffer.

Mesa writes **no VPS/SPS/PPS** when the application sends no packed headers: no NAL type 32 appeared in any
output. A libva encoder must therefore write VPS/SPS/PPS itself and pass them as packed headers. That wasn't
tried here.

**`vah265enc`.** A `force-key-unit` event pushed in-stream ahead of the frame gives an IDR, with VPS, SPS and PPS,
on that frame. IDRs then take 12.4–16.2 ms and are 1.35–2.0 MB on `text` (about 25 frames' worth of bitrate),
because GStreamer enforces a CPB of at least 2 s: its log reads "Too small cpb_size: 1000 … Adjust cpb_size to:
120000".

Its coded buffer is 2,138,808 bytes. An IDR larger than that comes out **corrupt**: a 138–250 KB access unit with
no start code at all. With an IDR every 120 frames this happened 9 times in 9, and with one every 30 frames, once
in 15. Late IDRs are worse because the CPB has filled. lain's GOP is infinite, with an IDR only on request, so
this is exactly lain's case.

`min-qp=22` avoided the corruption in these runs (15 of 15 at every 30 frames, 3 of 3 at every 240; IDRs about
1.67 MB). That's a mitigation, not a bound. On `smpte`, IDRs were 92 KB and fine.

### Per-frame quality for refinement

**libva: per-frame QP works.**
- CQP: `pic_init_qp` is set per frame. Re-encoding the last frame at QP 18 in a QP 30 stream gives 806–843 KB,
  then 33–35 KB for the second refinement, in 8.4–9.2 ms.
- CBR: the rate-control misc buffer is sent per frame, and `max_qp` caps that frame's QP. The effect depends on
  the QP the frame was first coded at: 37–450 KB.
- ROI with QP deltas is also supported (not tried).

**`vah265enc`: no clean per-frame QP.**
- `qpp` (CQP) is applied in PLAYING by restarting the sequence: VPS/SPS/PPS plus an IDR on the changed frame,
  and again on the reset.
- `max-qp` and `bitrate` take effect several frames late.
- A `bitrate` change once produced an AU with no start code.

**What works is the Swift host's approach**: re-encode the same surface and let CBR spend the spare budget. With
TU 2 the refinements took 7.23 ms p50 and 8.00 ms p95, at 22 KB mean (10 s run, load 0.03).

### Colour

- `vapostproc` converts to **limited range** by default: white gives Y 235, black Y 16.
- With caps `colorimetry=1:3:7:1` (full range, BT.709 matrix, sRGB transfer, BT.709 primaries) it gives true
  full range: white 255, black 0 (`range-check.py`).
- `vah265enc` writes no colour description in the VUI: `h265parse` reports no colorimetry. lain sends the tags in
  `VideoConfig`. Whether the client also needs them in the VUI is an open question.

## Recommendation for `lain-linux-video`

**Capture and convert: GStreamer.**

```
pipewiresrc path=<node> always-copy=false
  ! vapostproc
  ! video/x-raw(memory:VAMemory),format=NV12,width=W,height=H,colorimetry=1:3:7:1
```

DMA-BUF in and VA surfaces out, zero-copy, with scaling for free. Use shared memory only as the fallback
(negotiated, not forced). The `pipewire` crate isn't needed for this; it still needs `libclang-dev` to build.

**Encode: libva directly, as the target**, through a hand-written FFI module for the subset used (no bindgen):
config, surfaces, context, buffers, picture submit, `vaSyncBuffer`, map. It is as fast as the best GStreamer
setting, and it is the only way here to get:
- an IDR on the exact frame at P-frame cost, with its size bounded by a small HRD buffer;
- QP per frame for refinement;
- a coded buffer lain sizes itself, with overflow reported in the segment status.

Its costs:
- writing VPS/SPS/PPS as packed headers;
- getting the NV12 surface from the capture side.

The second is either the VA surface of GStreamer's `VAMemory` (sharing GStreamer's `VADisplay`, which needs
`libgstva`'s C API) or `vapostproc` writing DMA-BUF NV12 that lain's own `VADisplay` imports. **Neither handoff
was tried.**

**Interim or fallback: `vah265enc`**, which reaches Swift parity apart from keyframe size. Settings:

```
target-usage=2  rate-control=cbr  bitrate=60000  b-frames=0  ref-frames=1  key-int-max=1024  min-qp=22
```

Refinement is a plain re-encode, and keyframes use the in-stream `force-key-unit` event. Validate every AU
(starts with a start code, and an IDR carries VPS) and turn a bad one into `EncodeFailed`. The core then asks for
a keyframe again. Accept 1.3–2 MB keyframes.

**`VideoSession` mapping.**
- `start`: build the capture pipeline on `lain-gnome`'s node and the encoder. An appsink callback stores each
  capture in a **one-slot, latest-wins** holder and emits `Captured { capture, capture_ns }`.
  - `capture_ns` is the arrival time on `CLOCK_MONOTONIC`.
  - Keep at least three surfaces in the pool, so holding the newest never stalls capture.
- `encode(request)` runs on one encoder thread. The core keeps one request outstanding.
  - It takes whatever is in the slot when the encoder starts, never an older frame. An empty slot gives
    `EncodeFailed`.
  - `keyframe` gives an IDR with parameter sets in the Annex-B output.
  - `refinement` re-encodes the surface last encoded: at a lower QP with libva, as is with GStreamer.
  - `submit_ns` and `encode_done_ns` are taken around submit and map.
- **Where to convert.** Converting on capture gives the lower request latency at 2752×2064 (p50 10.0 ms against
  11.5–12.9 ms) and 92 fps against 74–84 fps, at the price of GFX work for frames that are never encoded.
  Converting on request wastes nothing. Both fit the contract. Pick by measuring on `RecordVirtual` at 120 Hz in
  wave 3.
- `info()`: 4:2:0, 8-bit, `ColorTags::SRGB_FULL_RANGE`, which is true only with `colorimetry=1:3:7:1` on the
  conversion caps.
- **Expect about 75–90 fps end to end at 2752×2064** on this iGPU. 120 fps needs a smaller encode size (2064×1548:
  8.6 ms with conversion) or a cheaper conversion.

## Open questions

- Is the conversion cost mostly GFX clock ramping? Re-run the BGRx rows with
  `echo high | sudo tee /sys/class/drm/card3/device/power_dpm_force_performance_level` (needs sudo; not tried).
- Does Mesa accept application VPS/SPS/PPS as packed headers while still writing slice headers itself? This
  decides how much bitstream writing a libva encoder needs.
- Which NV12 surface handoff from GStreamer to lain's libva encoder works: shared `VADisplay` or DMA-BUF import?
- Does the iPad client depend on the HEVC VUI colour description, or only on `VideoConfig`?
- Is `key-int-max=1024` a hard GOP limit in `vah265enc`? No IRAP appeared in 1,200 frames, but an I-slice
  TRAIL picture wouldn't have been counted.
- The numbers come from a desktop in use. Re-measure on a quiet machine (load is given for each row).

## What this spike changed on the desktop

- **Capture.** Four short `RecordMonitor` sessions on HDMI-1 (about 10 s each, cursor as metadata), each stopped
  explicitly, with its D-Bus connection closed when the process exited.
- **Nothing else.** No virtual monitor, no input, and no setting or GPU power state changed.
- **Files.** Only in this directory: `target/` and `out/` (encoded dumps), both gitignored.
