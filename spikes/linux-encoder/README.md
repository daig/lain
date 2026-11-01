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
  on the GFX engine (VA-API VPP, through `vapostproc`) adds 3.5–5.6 ms to the encode span. Measured from the tick
  that captured the frame, converting on request gives **p50 15.5 / p95 19.4 ms at 74–88 fps**; converting every
  frame on capture gives 120 fps but **p50 19.7 / p95 22.0 ms**. At 2064×1548 the encode span with conversion is
  8.6 ms at 116 fps.
- Capture is **zero-copy**: `pipewiresrc` negotiates DMA-BUF (`AR24`, AMD tiled modifier `0x0200000000401b03`),
  and `vapostproc` imports, converts and scales it on the GPU, at 5 % of one CPU core.
- **The GStreamer path doesn't keep off the NVIDIA cards by itself.** The VA plugin opens every render node when it
  loads (renderD128 and renderD129 included); a pinned display context only decides which device the elements
  use. libva directly opens only the node it is given.
- **Control differs a lot.** libva gives an IDR on exactly the requested frame at the cost of a P-frame (7.2 ms,
  about 250 KB under a two-frame HRD), and any QP per frame. `vah265enc` has four problems:
  - It enforces a CPB of at least 2 s, so forced IDRs are 1.35–2.0 MB and take 13–16 ms.
  - Above its 2.14 MB coded buffer it emits a **corrupt access unit**: every late forced IDR on text content.
  - It has no per-frame QP: changing a QP property restarts the sequence with an IDR, or takes effect frames later.
  - Its GOP is at most 1024 frames (`key-int-max` range 0–1024): it inserts an IDR every 1024 frames, unrequested,
    and on `text` that IDR is one of the corrupt ones.
- FFmpeg `hevc_vaapi` was **not tried**: its development headers aren't installed (`pkg-config libavcodec`:
  not found, no `/usr/include/libavcodec`, no `ffmpeg` binary; checked 2026-10-31).

## Machine

Ryzen 9 9950X, Radeon iGPU at PCI `0000:79:00.0`, `/dev/dri/renderD130`, `card3`: GC 10.3.6 and **VCN 3.1.2, one
instance** (from `ip_discovery`). Mesa 26.0.8 (radeonsi, `raphael_mendocino`), libva 1.23, GStreamer 1.28.2,
PipeWire GStreamer plugin 1.6.2, kernel 7.0.0-38, GNOME 50.1 on Wayland. HDMI-1 is 3840×2160 at 60 Hz.

**The NVIDIA nodes.** `vaenc` opens only renderD130 (checked with `nvidia-guard.sh`). `encbench` is different. The
GStreamer VA plugin's `plugin_init` enumerates every DRM render node through udev and opens each one
(`gst_va_display_drm_new_from_path`, called from `gst_plugin_load_by_name`), so **any process that loads it opens
renderD128 and renderD129** and tries to load a VA driver for them. That only fails because no NVIDIA VA driver is
installed; with `nvidia-vaapi-driver` present, the probe would initialise the reserved GPUs. The first version of
this spike claimed the NVIDIA nodes were never opened; that was wrong (round-1 review, confirmed with
`nvidia-guard.sh`). Since then:
- `encbench` picks the AMD node by PCI vendor from sysfs, picks the VA element factories whose `device-path` is that
  node, and gives every pipeline a `gst.va.display.handle` context holding a `GstVaDisplayDrm` built on it, before
  the pipeline leaves NULL (`src/va.rs`). That pins which device the elements use. It **doesn't stop the probe** at
  plugin load: no environment variable or API filters the device list.
- Every `encbench` run in the tables from round 2 on ran under `fence.sh`, which bind-mounts `/dev/null` over every
  non-AMD GPU node in a private mount namespace (bubblewrap), so the probe's opens fail and nothing reaches the
  NVIDIA cards. A systemd user unit with `InaccessiblePaths=` did **not** hide the nodes here (unprivileged user
  namespaces are restricted on this Ubuntu).
- `nvidia-guard.sh <command>` runs a command under strace, fails any open of a non-AMD GPU node with EACCES at
  syscall entry (so the device is never opened), and reports it. `./nvidia-guard.sh ./target/release/encbench
  synth --seconds 1` reports the two probe opens; `./nvidia-guard.sh ./vaenc/vaenc --query` reports none.

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
newest tick not yet encoded is submitted, so a slow encode skips content rather than queueing it. Both tools
follow it (`vaenc` did not before round 2: it encoded every tick in turn and fell behind instead of skipping).
fps is **content** encodes per second of wall time; refinements are counted separately.

**Two latencies.** "Capture → AU" starts when the frame encoded was captured: its tick (convert on request), or
the moment its BGRx frame was pushed into the conversion (`--csc-at-capture`). It includes the time the frame
waited for the previous encode to finish, up to one tick. It is the figure to compare across modes. "push → AU"
starts when the frame is submitted, so it leaves that wait out, and in `--csc-at-capture` mode the conversion too.
The round-1 README compared push → AU across the two modes, which favoured converting on capture; it was wrong.

**`encbench synth`** (Rust, gstreamer-rs 0.25, `src/synth.rs`) builds this pipeline:

```
appsrc ! vapostproc ! video/x-raw(memory:VAMemory),format=NV12 ! vah265enc ! fakesink
```

Pad probes time each stage. "Encode" runs from the buffer arriving at the `vah265enc` sink pad to the AU
leaving its src pad. "push → AU" runs from `appsrc.push_buffer` to the AU leaving the encoder. Outputs are
matched to inputs in order, because the encoder rewrites timestamps.

`--ring-format NV12` makes the ring NV12, so `vapostproc` passes through and the encode is measured alone.
`--csc-at-capture` converts every tick's frame on a capture thread (appsrc → vapostproc → a latest-wins appsink)
and encodes the newest converted frame. `--csc-queue N` (default 2) is how many BGRx frames may wait for that
conversion; 1 made no difference (p50 19.70 against 19.73 ms). A forced IDR is a `force-key-unit` event pushed from a probe in the
streaming thread, immediately ahead of its frame.

**`vaenc`** (C, `vaenc/vaenc.c`, libva directly) runs one frame at a time on the same tick model (newest tick,
skipping; refinements straight after their frame):

```
parameter buffers → vaBeginPicture/RenderPicture/EndPicture → vaSyncBuffer → vaMapBuffer
```

It works on NV12 surfaces only, with CBR plus an HRD buffer of two frames, `intra_period` 0, one reference and
no packed headers. `--quality` sends `VAEncMiscParameterBufferQualityLevel`. Without it the driver default is
used.

**`encbench live`** (`src/live.rs`) captures with Mutter `ScreenCast.RecordMonitor("HDMI-1", cursor-mode 2)`
through zbus and encodes every frame Mutter delivers:

```
pipewiresrc path=<node> always-copy=false ! vapostproc ! NV12 VAMemory 2752×2064, PAR 1/1
  [! capssetter framerate=N/1] ! vah265enc
```

It records the memory type of every captured buffer and the negotiated caps. Mutter sends frames only on damage,
so `--keepalive-ms` re-sends the last frame to time an idle desktop at a steady rate (the content is then
static). `--shm` forces system-memory caps (the fallback). `--enc-fps N` sets `framerate=N/1` on the encoder's
input caps. Its latency runs from the buffer leaving `pipewiresrc` (arrival, `do-timestamp=true`), not from the
compositor's capture time. The session is stopped and the D-Bus connection
closed at the end.

**Helpers.**
- `sweep.sh` and `vaenc-sweep.sh` run one option set per stdin line.
- `gpu-sample.sh` samples `pp_dpm_vclk`/`dclk`/`sclk` and the busy counters during a run.
- `range-check.py` checks the range `vapostproc` converts with.
- `fence.sh` runs a command with the non-AMD GPU nodes masked; `nvidia-guard.sh` reports any attempt to open
  one (see Machine).

### Reproduce

```
cd spikes/linux-encoder
cargo build --release && make -C vaenc
E="./fence.sh ./target/release/encbench"                                     # NVIDIA nodes masked
$E synth --seconds 10 --tu 2 --ring-format NV12      # encode only
$E synth --seconds 10 --tu 2                         # BGRx: convert on request + encode
$E synth --seconds 10 --tu 2 --csc-at-capture        # convert on capture
$E synth --seconds 10 --tu 2 --ring-format NV12 --idr-every 120 --refine-every 60
$E synth --seconds 3 --width 640 --height 480 --tu 2 --ring-format NV12 --keyint 100   # periodic IDRs
$E live  --seconds 10 --tu 2 --keepalive-ms 5        # RecordMonitor, DMA-BUF, variable-rate caps
$E live  --seconds 10 --tu 2 --keepalive-ms 5 --enc-fps 120
$E live  --seconds 10 --tu 2 --keepalive-ms 16 --shm
./nvidia-guard.sh ./vaenc/vaenc --seconds 2
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
- Request model: `--inflight N --queue --csc-at-capture --csc-queue N`.
- Device: `--render-node /dev/dri/renderD130` (refused unless its PCI vendor is 0x1002; default: the AMD node).
- Live: `--connector HDMI-1 --cursor-mode 2 --keepalive-ms N --shm --enc-fps N`.
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
| libva, quality level 4 or 7 | 9.02 | 9.51–9.57 | 108.2 / 108.7 | 0.7 % | 0.38 / 0.35 | 4 s |
| `vah265enc` TU 2 | 7.32 | 7.67 | 119.9 | 2.5 % | 0.22 | 10 s |
| `vah265enc` TU 2, round 2: capture (tick) → AU | 7.39–7.45 | 9.11–9.22 | 119.9 | 2.8–3.6 % | 0.24 / 0.42 | 10 s |
| `vah265enc` TU 3 | 7.31 | 7.62 | 120.0 | 2.6 % | 0.27 | 4 s |
| `vah265enc` TU 1 | 8.51 | 9.69 | 116.0 | 3.1 % | 1.55 | 4 s |
| `vah265enc` TU 4 (its default) | 9.19 | 10.02 | 106.9 | 3.3 % | 1.55 | 4 s |
| `vah265enc` TU 5 / 6 | 9.15 / 9.08 | 10.38 / 9.70 | 107–108 | 2.5–2.8 % | 0.25 / 0.23 | 4 s |
| `vah265enc` TU 7, `zone-plate` / `smpte` | 9.48 / 9.59 | 9.97 / 9.97 | 104–105 | 3–4 % | 1.32 / 1.29 | 4 s |
| `vah264enc` (H.264, for scale), TU 7 | 18.97 | 19.24 | 52.5 | 3.1 % | 1.27 | 4 s |
| libva at 2064×1548 | 4.47 | 4.89 | 120.1 | 1.1 % | 0.70 | 4 s |
| `vah265enc` TU 7 at 2064×1548 | 5.49 | 5.77 | 120.0 | 2.8 % | 1.94 | 4 s |

- The p50/p95 columns are the encode span (libva: parameters → AU mapped), except where marked capture → AU.
- The libva quality 4/7 latencies are from round 1; the fps was re-measured in round 2 on the newest-tick model
  (45–47 of 480 ticks skipped). Round 1's 110 fps came from a model that never skipped a tick.
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

Round 2, all 10 s, TU 2, under `fence.sh`, both latencies (see Method):

| Path | capture → AU p50 / p95 ms | push → AU p50 / p95 ms | fps | CPU | load |
|---|---|---|---|---|---|
| convert on request (vapostproc inline) | **15.49 / 19.41** | 11.48 / 12.53 | 87.5 | 4.5 % | 0.22 |
| convert on capture, newest converted frame encoded | **19.73 / 21.97** | 8.13 / 9.65 | 119.9 | 4.4 % | 0.18 |
| same, `--csc-queue 1` | 19.70 / 21.83 | 8.15 / 9.45 | 119.9 | 4.3 % | 0.29 |

Round 1 (push → AU only, which isn't comparable across the two modes):

| Path | push → AU p50 ms | p95 ms | fps | CPU | load |
|---|---|---|---|---|---|
| TU 2, convert on request (vapostproc inline), 10 s | 12.94 | 13.86 | 73.4 | 5.4 % | 0.20 |
| same, another 4 s run | 11.46 | 12.84 | 83.7 | 5.4 % | 0.10 |
| TU 2, convert on capture, 10 s (capture → AU in a reviewer's re-run: 23.74 / 26.61) | 10.04 | 13.88 | 91.9 | 4.2 % | 0.27 |
| TU 7, convert on request, 10 s | 13.13 | 14.64 | 73.5 | 3.0 % | 1.55 |
| TU 7, convert on request, 2064×1548 | 8.61 | 8.93 | 116.1 | 4.2 % | 2.11 |
| TU 7, convert on request, 1920×1080 | 6.21 | 6.68 | 119.2 | 4.1 % | 1.32 |

- The conversion runs on the GFX engine, at a cost that varies with the GFX clock: `sclk` swings between 600 and
  2200 MHz under this bursty load.
- "vapostproc in → encoder in" is 0.01 ms, because VPP work is queued, not waited for. Its cost shows up inside
  the encode span.
- **Converting on request has the lower end-to-end latency** (capture → AU p50 15.5 against 19.7 ms; p95 19.4
  against 22.0). Converting on capture keeps up with 120 Hz, but each frame then waits for the conversion, for the
  previous encode, and in the latest slot, and the encode itself slows (8.1 ms here, 10 ms in round 1, against 7.3)
  because the GFX engine converts at 120 Hz beside the encoder on a two-CU iGPU that also composites the desktop.
  The two-buffer leaky queue in front of the conversion isn't what inflates it: one buffer gives the same.
- Run-to-run spread is large with conversion in the path (73–88 fps on request; 92 or 120 fps on capture), as the
  desktop's own GFX load changes.

### Real capture: RecordMonitor HDMI-1, 3840×2160 at 60 Hz → 2752×2064, TU 2

| Path | pipewiresrc out → AU p50 | p95 | fps delivered | CPU | load |
|---|---|---|---|---|---|
| DMA-BUF, keepalive 5 ms | 11.37 | 12.23 | 54.7 | 4.9 % | 0.27 |
| round 2, PAR 1/1, framerate 0/1 as negotiated (AU mean 112.7 KB, 55.0 Mbps) | 10.74 | 12.55 | 61.0 | not recorded | 0.30 |
| round 2, PAR 1/1, `--enc-fps 120` (AU mean 50.0 KB, 23.9 Mbps) | 10.65 | 12.71 | 59.9 | not recorded | 0.33 |
| DMA-BUF, keepalive 16 ms | 11.72 | 12.78 | 35.6 | 5.0 % | 0.21 |
| shared memory (forced) | 17.35 | 19.39 | 27.2 | 10.2 % | 0.22 |

- Negotiated caps: `video/x-raw(memory:DMABuf), format=DMA_DRM, drm-format=AR24:0x0200000000401b03`. Every
  buffer came from `GstDmaBufAllocator`, and `vapostproc` produced `video/x-raw(memory:VAMemory),format=NV12`
  directly. **Zero-copy holds**.
- The shared-memory fallback (`BGRA` in memfd) costs an upload: +6 ms and twice the CPU.
- The idle desktop delivered 4 frames in 10 s without keepalive, which is why keepalive was used.
- **What this latency is.** It runs from the buffer leaving `pipewiresrc` (arrival time), and almost every frame
  was a keepalive re-send of static content. It leaves out Mutter's render-to-PipeWire time and real
  damage-driven frames, so it isn't comparable to Swift's capture → AU, which starts at SCK's `displayTime`
  (`FrameSource.swift`). Wave 3 must measure with changing content and the compositor's timestamp.
- **The stream is variable-rate.** Mutter's caps are `framerate=0/1, max-framerate=60/1`, and `vapostproc` passes
  that on. `vah265enc` then budgets CBR as if at 30 fps: with `bitrate=60000`, about 250 KB per frame, against
  62 KB at 120 fps. Measured: AU mean 112.7 KB at 0/1 against 50.0 KB with `framerate=120/1` set on the encoder's
  input caps (`capssetter`), on the same static desktop, at the same encode time. (A reviewer saw the same in a
  synthetic run: 29.25 MB against 6.75 MB for 1,200 frames at 6 Mbps.) None of the synthetic rows were affected:
  their caps carry `framerate=120/1`.
- **Aspect ratio.** Scaling 16:9 into 2752×2064 (4:3) gave `pixel-aspect-ratio=4/3` caps in round 1: a stretched
  image with a non-square PAR. Round 2 puts `pixel-aspect-ratio=1/1` on the conversion caps; the image is still
  stretched here (the spike captures a 16:9 monitor), which `RecordVirtual` at the iPad's own size avoids.

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

**`vah265enc` has no infinite GOP.** `key-int-max` ranges 0–1024 (0 means automatic), and the element starts a new
GOP with an IDR every `key-int-max` frames (its log: "system_frame_number: 1024, an IDR frame, starts a new GOP").
Round 1 said "no IRAP appeared in 1,200 frames"; that was wrong. The IDR at frame 1024 came out corrupt (no start
code), and the tool counted only AUs it could parse. Now it counts corrupt AUs too:
- 2752×2064, `text`, 10 s: the AU of encoder frame 1024 is corrupt.
- Same with `min-qp=22`: frame 1024 is an unrequested 1.65 MB IDR.
- 640×480, `--keyint 100`: frames 100, 200 and 300 are all corrupt (62–124 KB; the coded buffer scales with the
  picture size).
- `gst-launch-1.0 videotestsrc` (smpte) at 640×480: IDRs at 0, 1024 and 2048, all intact.

So with `vah265enc`, every 1024th encode (9–14 s at 75–120 fps) is an IDR nobody asked for, and on text it is
corrupt unless `min-qp` keeps it under the coded buffer.

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
- `vah265enc` writes no colour description in the VUI: `h265parse` reports no colorimetry. That is harmless: the
  iPad client takes colour only from `VideoConfig`. `HEVC.swift` builds the format description with
  `ColorTags.extensions(config)` (full range, primaries, transfer and matrix from `VideoConfig`), and
  `VideoRenderer.swift` picks the range from `FrameFormat(config)`, that is `VideoConfig.fullRange`; neither reads
  the SPS VUI. It holds as long
  as the conversion caps carry `colorimetry=1:3:7:1` and `info()` reports `SRGB_FULL_RANGE`.
- Without colorimetry on the caps, the live path converted to `colorimetry=2:3:4:1` (limited range, BT.709).

## Recommendation for `lain-linux-video`

**Keep the GStreamer VA plugin out of the process if the "never NVIDIA" rule must be enforced.** Loading that
plugin opens every render node (see Machine). A pinned display context fixes which device the elements use, not
what the plugin probes. The cleanest way to keep lain off the NVIDIA cards is to keep everything VA in lain's own
code on the AMD node it opened:
- capture with `pipewiresrc` (the PipeWire plugin, which has no VA in it) or the `pipewire` crate, negotiating
  DMA-BUF;
- import the DMA-BUF into lain's `VADisplay` (`vaCreateSurfaces` with a DRM PRIME 2 descriptor);
- convert BGRx → NV12 with libva VPP (what `vapostproc` does underneath, so the same GFX cost is expected; not
  measured);
- encode with libva.

None of the import or the VPP was tried here. If the VA plugin is used anyway, the host must run with the non-AMD
nodes masked (`fence.sh` shows how: a private mount namespace through bubblewrap). Here a systemd user unit's
`InaccessiblePaths=` did not take effect. The registry scan in `gst-plugin-scanner` probes the same way.

**Capture and convert, as measured: GStreamer.**

```
pipewiresrc path=<node> always-copy=false
  ! vapostproc
  ! video/x-raw(memory:VAMemory),format=NV12,width=W,height=H,pixel-aspect-ratio=1/1,colorimetry=1:3:7:1
  ! capssetter caps="video/x-raw(memory:VAMemory),framerate=<EncodeConfig.frame_rate>/1"   # GStreamer encoder only
```

DMA-BUF in and VA surfaces out, zero-copy, with scaling for free. Use shared memory only as the fallback
(negotiated, not forced). Pin the device:
- name the per-device factories whose `device-path` is the AMD node, not the plain `vapostproc` / `vah265enc`,
  which belong to whichever device the registry listed first;
- give the pipeline a `gst.va.display.handle` context built with `gst_va_display_drm_new_from_path(<AMD node>)`
  and `gst_context_set_va_display` before it leaves NULL (`src/va.rs` does both; `libgstva-1.0` has no
  development package here, so the two functions are declared by hand);
- check the node's PCI vendor (`/sys/class/drm/renderDN/device/vendor` = `0x1002`) before anything opens it.

The `pipewire` crate isn't needed for this; it still needs `libclang-dev` to build.

**Encode: libva directly, as the target**, through a hand-written FFI module for the subset used (no bindgen):
config, surfaces, context, buffers, picture submit, `vaSyncBuffer`, map. It is as fast as the best GStreamer
setting, opens only the node it is given, and it is the only way here to get:
- an infinite GOP (`intra_period` and `intra_idr_period` 0), with an IDR only on request;
- an IDR on the exact frame at P-frame cost, with its size bounded by a small HRD buffer;
- QP per frame for refinement;
- a coded buffer lain sizes itself, with overflow reported in the segment status.

Its costs:
- writing VPS/SPS/PPS as packed headers;
- getting the NV12 surface from the capture side (above: DMA-BUF import into lain's display, or the VA surface of
  GStreamer's `VAMemory` through `libgstva`'s C API). **Neither handoff was tried.**

**Interim or fallback: `vah265enc`**, which reaches Swift parity apart from keyframes. Settings:

```
target-usage=2  rate-control=cbr  bitrate=60000  b-frames=0  ref-frames=1  key-int-max=1024  min-qp=22
```

and an explicit framerate on its input caps (above): without it CBR is budgeted at 30 fps, which roughly doubled
live AU sizes. Refinement is a plain re-encode, and keyframes use the in-stream `force-key-unit` event. What the
backend must handle:
- **Unrequested IDRs every 1024 frames.** They are inherent: `key-int-max` can't exceed 1024. Report every IRAP
  AU as a keyframe in `Encoded`, requested or not, and keep `min-qp`, or the periodic IDR overflows the coded
  buffer on text.
- **Bad AUs.** Validate every AU: it starts with a start code, and an IDR carries a VPS. Turn a bad one into
  `EncodeFailed`, **and force an IDR on the next encode itself.** The encoder has already used the discarded
  picture as its reference, so the P-frames after it reference a picture the client never got. The core won't
  ask: on a failed encode Swift only counts it and frees the gate (`HostVideoPipeline.encoded`:
  `gate?.encodeFailed()`, no keyframe request), and `lain-media`'s brief mirrors that ("EncodeFailed frees the
  gate"). The bad AUs are mostly forced IDRs,
  so the client asked for an IDR, got `EncodeFailed`, and would then get P-frames off a missing IDR. (Either the
  backend does this, or `lain-platform` and `lain-media` define it; the contract says nothing today.)
- Accept 1.3–2 MB keyframes.

**`VideoSession` mapping** (as `lain-platform`'s `video.rs` documents it).
- `start`: build the capture pipeline on `lain-gnome`'s node and the encoder. An appsink callback stores each
  capture in a **one-slot, latest-wins** holder and emits `Captured { capture, capture_ns }`.
  - `capture_ns`: the compositor's time for the frame if PipeWire gives one (the buffer's `spa_meta_header` PTS,
    or `pipewiresrc`'s PTS without `do-timestamp`), mapped to `CLOCK_MONOTONIC`; else the arrival time. Swift
    uses SCK's `displayTime` and falls back to arrival (`FrameSource.swift`). This spike only measured arrival.
  - Keep at least three surfaces in the pool, so holding the newest never stalls capture.
- **The slot keeps the newest capture after it is encoded.** Only a newer capture replaces it, and it is empty
  only before the first capture. Every request, keyframe and refinement included, encodes what is in it, never
  an older frame. An empty slot (nothing captured yet) gives `EncodeFailed`. This matters on an idle desktop:
  Mutter delivers nothing while nothing changes (4 frames in 10 s), and Swift answers a keyframe request by
  re-offering the last capture (`HostVideoPipeline.requestKeyframe`), so a slot emptied by the previous encode
  would leave the client without its IDR.
- `encode(request)` runs on one encoder thread. The core keeps one request outstanding.
  - `keyframe` gives an IDR with parameter sets in the Annex-B output.
  - `refinement` re-encodes the newest capture (the slot): at a lower QP with libva, as is with GStreamer.
    `lain-media` puts the refinement flag on the wire only when the encoded capture is the one the refinement
    was for, so re-encoding an older surface would be wrong.
  - `submit_ns` and `encode_done_ns` are taken around submit and map.
- **Where to convert: on request.** Measured from capture, it has the lower latency at 2752×2064 (p50 15.5 / p95
  19.4 ms against 19.7 / 22.0 ms on capture), and wastes no GFX work on frames never encoded. Converting on
  capture sustains 120 fps here, against 74–88 fps on request. Confirm on `RecordVirtual` at 120 Hz in wave 3.
- `info()`: 4:2:0, 8-bit, `ColorTags::SRGB_FULL_RANGE`, which is true only with `colorimetry=1:3:7:1` on the
  conversion caps.
- **Expect about 75–90 fps on request at 2752×2064** on this iGPU (capture → AU p50 about 15 ms). 120 fps needs a
  smaller encode size (2064×1548: 8.6 ms with conversion), a cheaper conversion, or conversion on capture at
  about 4 ms more latency.

**Wave-3 acceptance items this spike didn't cover.**
- Decode-verify the output (for example with `vah265dec`, or the iPad) after a forced IDR, after a refinement,
  and after a discarded AU. Nothing here was decoded: the libva AUs had no parameter sets, and the `vah265enc`
  dumps were only scanned for NAL types.
- Refinement quality: PSNR of the refined frame against the source, with `min-qp=22` (which floors refinement
  quality on the GStreamer path) and with libva's per-frame QP.
- `StoppedByUser`: how a desktop-side stop shows up through `pipewiresrc` and Mutter (stream removed, session
  `Closed`), on `RecordVirtual`.
- Stream renegotiation on resize, on `RecordVirtual`.
- PipeWire buffer-pool pressure when the slot holds a `pipewiresrc` buffer for convert on request.
- DMA-BUF negotiation into an appsink or lain's own import (here `vapostproc` was downstream to accept it).
- The libva packed VPS/SPS/PPS and the NV12 handoff (above).
- Latency with changing content and the compositor's timestamp, and live AU sizes and bitrate with the framerate
  set.
- No NVIDIA device opened: run the live tests under `nvidia-guard.sh` (or an equivalent strace check).

## Open questions

- Is the conversion cost mostly GFX clock ramping? Re-run the BGRx rows with
  `echo high | sudo tee /sys/class/drm/card3/device/power_dpm_force_performance_level` (needs sudo; not tried).
- Does Mesa accept application VPS/SPS/PPS as packed headers while still writing slice headers itself? This
  decides how much bitstream writing a libva encoder needs.
- Which NV12 surface handoff to lain's libva encoder works: DMA-BUF import into lain's display, or GStreamer's
  shared `VADisplay`?
- The numbers come from a desktop in use. Re-measure on a quiet machine (load is given for each row).

Closed in round 2: the VUI colour description (the client doesn't read it; see Colour) and `key-int-max`
(a hard 1024-frame limit; see Forced IDR).

## What this spike changed on the desktop

- **Capture.** Four short `RecordMonitor` sessions on HDMI-1 in round 1 and two in round 2 (about 10 s each,
  cursor as metadata), each stopped explicitly, with its D-Bus connection closed when the process exited.
- **NVIDIA nodes.** Round 1's `encbench` runs opened renderD128 and renderD129 through the VA plugin's probe (no
  VA driver loaded on them). Round 2 ran `encbench` and `gst-launch-1.0` only under `fence.sh`, or under
  `nvidia-guard.sh`, which fails the open before it happens.
- **Nothing else.** No virtual monitor, no input, and no setting or GPU power state changed. A systemd transient
  user unit (`systemd-run --user --wait stat …`) ran once to test `InaccessiblePaths=` and exited.
- **Files.** In this directory: `target/` and `out/` (encoded dumps), both gitignored. GStreamer rewrote its own
  registry cache (`~/.cache/gstreamer-1.0/`) when the visible devices changed under `fence.sh`; it rebuilds itself.
