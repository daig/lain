//! GPU tests on synthetic content only (the brief's agent-run list): GBM buffers at Mutter's modifier, VA
//! surfaces, the encoder at 2752×2064, a forced IDR, a refinement, a discarded access unit, the conversion against
//! the f64 CPU reference, the engine end to end without PipeWire, and no NVIDIA node opened. All `#[ignore]`d;
//! run one at a time through `rust/scripts/gpu-run.sh` (which pins Mesa and fences off the NVIDIA devices), e.g.
//!
//! ```text
//! scripts/gpu-run.sh encode <cargo> test -p lain-linux-video -- --ignored --exact gpu_tests::encode_2752x2064 \
//!     --test-threads=1 --nocapture
//! ```
//!
//! Streams for the decode check (`spikes/linux-convert/e2e/decode-check.py` under `spikes/linux-encoder/fence.sh`)
//! are written to `$LAIN_VIDEO_DUMP_DIR`, else `rust/target/lain-video-gpu/`.

use std::path::PathBuf;
use std::sync::mpsc as std_mpsc;
use std::time::{Duration, Instant};

use lain_platform::{EncodeRequest, VideoEvent, VideoSession};

use crate::device;
use crate::encoder::{EncoderSettings, PictureKind};
use crate::engine::{CaptureFrame, EngineConfig, Gpu};
use crate::frame::{DmaBufPlane, Picture, Pixels, max_error, reference_nv12, synthetic_bgrx};
use crate::gbm::{Bo, DRM_FORMAT_XRGB8888, MUTTER_MODIFIER};
use crate::gpu::{GpuPipeline, GpuSettings};
use crate::va::Nv12Picture;

const W: u32 = 2752;
const H: u32 = 2064;

fn settings(width: u32, height: u32) -> GpuSettings {
    GpuSettings { encoder: EncoderSettings { width, height, fps: 120, bitrate: 60_000_000 }, modifier: MUTTER_MODIFIER }
}

fn pipeline(width: u32, height: u32) -> GpuPipeline {
    let node = device::select_system_render_node(None).expect("the AMD render node");
    println!("render node {} ({:?}, boot_vga {})", node.path.display(), node.pci, node.boot_vga);
    GpuPipeline::new(&node, settings(width, height)).expect("the GPU pipeline")
}

fn dump_dir() -> PathBuf {
    let dir = std::env::var_os("LAIN_VIDEO_DUMP_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../target/lain-video-gpu")));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn percentile(v: &mut [u64], q: f64) -> f64 {
    v.sort_unstable();
    if v.is_empty() {
        return 0.0;
    }
    v[((v.len() - 1) as f64 * q).round() as usize] as f64 / 1e6
}

/// Prints p50/p95/max/mean of nanosecond values in ms.
fn summary(label: &str, v: &mut [u64]) {
    let mean = v.iter().sum::<u64>() as f64 / v.len().max(1) as f64 / 1e6;
    println!(
        "  {label}: n={} p50={:.2} p95={:.2} max={:.2} mean={:.2} ms",
        v.len(),
        percentile(v, 0.5),
        percentile(v, 0.95),
        percentile(v, 1.0),
        mean
    );
}

/// Prints p50/p95/max/mean of byte counts in KB.
fn sizes_summary(label: &str, v: &mut [u64]) {
    let kb = |x: f64| x * 1e6 / 1000.0;
    let mean = v.iter().sum::<u64>() as f64 / v.len().max(1) as f64 / 1000.0;
    println!(
        "  {label}: n={} p50={:.1} p95={:.1} max={:.1} mean={mean:.1} KB",
        v.len(),
        kb(percentile(v, 0.5)),
        kb(percentile(v, 0.95)),
        kb(percentile(v, 1.0)),
    );
}

fn nal_types(au: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 3 < au.len() {
        if au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1 {
            out.push((au[i + 3] >> 1) & 0x3F);
            i += 3;
        } else {
            i += 1;
        }
    }
    out
}

/// What the synthetic NV12 frames show.
#[derive(Clone, Copy)]
enum Content {
    /// The scrolling-terminal pattern through the CPU reference: per-pixel noise inside the glyph cells, close to
    /// incompressible at 60 Mbps (the timing's worst case; its PSNR is low by nature).
    Terminal,
    /// `hevcfix.c`'s fixture content: a moving gradient and a white square (what the PSNR checks use).
    Gradient,
}

fn gradient_nv12(width: u32, height: u32, f: u32) -> Nv12Picture {
    let (w, h) = (width as usize, height as usize);
    let mut data = vec![0u8; w * h * 3 / 2];
    let (sx, sy) = ((f as usize * 6) % (w - 16), (f as usize * 4) % (h - 16));
    let f = f as usize;
    for y in 0..h {
        for x in 0..w {
            let in_square = (sx..sx + 16).contains(&x) && (sy..sy + 16).contains(&y);
            data[y * w + x] = if in_square { 235 } else { (16 + (x * 3 + y * 2 + f * 5) % 200) as u8 };
        }
    }
    for y in 0..h / 2 {
        for x in 0..w / 2 {
            let at = w * h + y * w + 2 * x;
            data[at] = (112 + (x + f) % 32) as u8;
            data[at + 1] = (112 + (2 * y + f) % 32) as u8;
        }
    }
    Nv12Picture { width, height, data }
}

/// `picture` in the top-left of a `cw × ch` NV12 picture, the rest black (Y 16, CbCr 128).
fn pad_nv12(picture: &Nv12Picture, cw: u32, ch: u32) -> Nv12Picture {
    let (w, h, cw_, ch_) = (picture.width as usize, picture.height as usize, cw as usize, ch as usize);
    let mut data = vec![16u8; cw_ * ch_];
    data.resize(cw_ * ch_ * 3 / 2, 128);
    for y in 0..h {
        data[y * cw_..y * cw_ + w].copy_from_slice(&picture.data[y * w..y * w + w]);
    }
    for y in 0..h / 2 {
        let (src, dst) = (w * h + y * w, cw_ * ch_ + y * cw_);
        data[dst..dst + w].copy_from_slice(&picture.data[src..src + w]);
    }
    Nv12Picture { width: cw, height: ch, data }
}

/// Synthetic NV12 frames, one per surface (frame i in surface i).
fn fill_surfaces(pipe: &GpuPipeline, width: u32, height: u32, content: Content) -> Vec<Nv12Picture> {
    let (w, h) = (width as usize, height as usize);
    let mut pictures = Vec::new();
    for (i, &surface) in pipe.surface_ids().iter().enumerate() {
        let picture = match content {
            Content::Terminal => {
                Nv12Picture { width, height, data: reference_nv12(&synthetic_bgrx(w, h, i as u32, false), w, h) }
            }
            Content::Gradient => gradient_nv12(width, height, i as u32),
        };
        // The whole surface, at the coded size, padding black: radeonsi's vaPutImage crashed (SIGSEGV) putting a
        // 1366×770 image into a 1408×784 surface (2026-11-01).
        let (cw, ch) = pipe.settings().encoder.headers().coded_size();
        pipe.va().put_nv12(surface, &pad_nv12(&picture, cw, ch)).expect("vaPutImage");
        pictures.push(picture);
    }
    pictures
}

/// One encoded picture of a run.
struct Coded {
    au: Vec<u8>,
    /// Submit → AU, ns.
    time: u64,
    surface: usize,
    /// The driver's average QP (`VA_CODED_BUF_STATUS_PICTURE_AVE_QP_MASK`).
    qp: u32,
}

/// Encodes one picture of `surface` and validates it.
fn encode_one(pipe: &mut GpuPipeline, surface: usize, kind: PictureKind) -> Coded {
    let t0 = Instant::now();
    pipe.submit_encode(surface, kind).expect("submit");
    let picture = loop {
        if let Some(r) = pipe.encoder().poll(1_000_000) {
            break r.expect("an access unit");
        }
        assert!(t0.elapsed() < Duration::from_secs(1), "the encode never finished");
    };
    let time = t0.elapsed().as_nanos() as u64;
    crate::au::validate(&picture.annexb, kind.idr).unwrap_or_else(|e| panic!("{e}"));
    Coded { au: picture.annexb, time, surface, qp: picture.status & 0xFF }
}

/// Encodes `count` pictures cycling through the surfaces (`kinds(i)` says what each is).
fn encode_run(pipe: &mut GpuPipeline, count: usize, kinds: impl Fn(usize) -> PictureKind) -> Vec<Coded> {
    let n = pipe.surfaces();
    (0..count).map(|i| encode_one(pipe, i % n, kinds(i))).collect()
}

/// Writes a stream and the reference NV12 of one of its pictures for decode-check.py.
fn dump(name: &str, aus: &[&[u8]], reference: &Nv12Picture) -> (PathBuf, PathBuf) {
    let dir = dump_dir();
    let stream = dir.join(format!("{name}.h265"));
    let nv12 = dir.join(format!("{name}.nv12"));
    std::fs::write(&stream, aus.concat()).unwrap();
    std::fs::write(&nv12, &reference.data).unwrap();
    (stream, nv12)
}

#[test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
fn encode_2752x2064() {
    let mut pipe = pipeline(W, H);
    fill_surfaces(&pipe, W, H, Content::Terminal);
    let aus = encode_run(&mut pipe, 600, |_| PictureKind { idr: false, refinement: false });
    let first = &aus[0].au;
    let types = nal_types(first);
    assert_eq!(&types[..3], &[32, 33, 34], "the first picture carries VPS, SPS and PPS");
    assert!(types.contains(&19), "and is an IDR");
    assert!(
        aus[1..].iter().all(|c| nal_types(&c.au) == [1]),
        "then one TRAIL_R slice each, no filler (bit stuffing off)"
    );
    let mut times: Vec<u64> = aus[1..].iter().map(|c| c.time).collect();
    let mut sizes: Vec<u64> = aus[1..].iter().map(|c| c.au.len() as u64).collect();
    let mut qps: Vec<u64> = aus[1..].iter().map(|c| u64::from(c.qp) * 1_000_000).collect();
    println!(
        "encode 2752×2064, CBR 60 Mbps, 120 fps budget (back to back, scrolling-terminal content cycling 4 surfaces):"
    );
    println!("  IDR: {} bytes in {:.2} ms, average QP {}", first.len(), aus[0].time as f64 / 1e6, aus[0].qp);
    summary("P-frame encode (submit → AU)", &mut times);
    sizes_summary("P-frame size", &mut sizes);
    summary("P-frame average QP (shown as ms)", &mut qps);
    let total: usize = aus.iter().map(|c| c.au.len()).sum();
    println!(
        "  {} AUs, {:.1} Mbit total ({:.1} Mbps at 120 fps)",
        aus.len(),
        total as f64 * 8e-6,
        total as f64 * 8.0 * 120.0 / aus.len() as f64 / 1e6
    );
    assert!(percentile(&mut times, 0.5) < 16.0, "an encode takes well under two frames");
}

#[test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
fn forced_idr_decodes() {
    let mut pipe = pipeline(W, H);
    let pictures = fill_surfaces(&pipe, W, H, Content::Gradient);
    let idr_at = 40;
    let aus = encode_run(&mut pipe, 60, |i| PictureKind { idr: i == idr_at, refinement: false });
    for (i, c) in aus.iter().enumerate() {
        let irap = nal_types(&c.au).iter().any(|t| (16..=23).contains(t));
        assert_eq!(irap, i == 0 || i == idr_at, "AU {i}: IRAP only on frames 0 and {idr_at}");
        if i == idr_at {
            println!(
                "forced IDR on frame {i} of 60: {} bytes in {:.2} ms, average QP {}, NAL types {:?} (P-frames around it: {} and {} bytes)",
                c.au.len(),
                c.time as f64 / 1e6,
                c.qp,
                nal_types(&c.au),
                aus[i - 1].au.len(),
                aus[i + 1].au.len()
            );
            assert_eq!(&nal_types(&c.au)[..3], &[32, 33, 34]);
        }
    }
    // The stream from the forced IDR on decodes by itself; its last picture is surface 59 % 4.
    let tail: Vec<&[u8]> = aus[idr_at..].iter().map(|c| c.au.as_slice()).collect();
    let last = &pictures[aus[59].surface];
    let (stream, nv12) = dump("forced-idr", &tail, last);
    println!("decode check: decode-check.py {} {} {W} {H} {}", stream.display(), nv12.display(), 59 - idr_at);
    let whole: Vec<&[u8]> = aus.iter().map(|c| c.au.as_slice()).collect();
    let (stream, nv12) = dump("forced-idr-whole", &whole, last);
    println!("decode check: decode-check.py {} {} {W} {H} 59", stream.display(), nv12.display());
}

#[test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
fn refinement() {
    let mut pipe = pipeline(W, H);
    let pictures = fill_surfaces(&pipe, W, H, Content::Gradient);
    // 30 pictures, then three refinements of the last one's surface (an idle desktop).
    let mut aus = encode_run(&mut pipe, 30, |_| PictureKind { idr: false, refinement: false });
    let last = aus[29].surface;
    for _ in 0..3 {
        aus.push(encode_one(&mut pipe, last, PictureKind { idr: false, refinement: true }));
    }
    println!("refinement (QP {}):", crate::encoder::REFINEMENT_QP);
    for (i, c) in aus.iter().enumerate().skip(28) {
        println!("  picture {i}: {} bytes in {:.2} ms, average QP {}", c.au.len(), c.time as f64 / 1e6, c.qp);
    }
    let all: Vec<&[u8]> = aus.iter().map(|c| c.au.as_slice()).collect();
    let (stream, nv12) = dump("refinement", &all, &pictures[last]);
    for i in [29, 30, 32] {
        println!("decode check: decode-check.py {} {} {W} {H} {i}", stream.display(), nv12.display());
    }
}

#[test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
fn discarded_au_then_recovery() {
    let mut pipe = pipeline(W, H);
    let pictures = fill_surfaces(&pipe, W, H, Content::Gradient);
    // Picture 20's AU is lost (as the engine discards a bad one); picture 21 is the IDR the engine forces.
    let aus = encode_run(&mut pipe, 40, |i| PictureKind { idr: i == 21, refinement: false });
    let kept: Vec<&[u8]> = aus.iter().enumerate().filter(|(i, _)| *i != 20).map(|(_, c)| c.au.as_slice()).collect();
    let (stream, nv12) = dump("discarded", &kept, &pictures[aus[39].surface]);
    println!("discarded AU 20, IDR on 21: {} AUs kept", kept.len());
    println!("decode check: decode-check.py {} {} {W} {H} {}", stream.display(), nv12.display(), kept.len() - 1);
    assert!(nal_types(kept[20]).contains(&19), "the AU after the gap is the IDR");
}

#[test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
fn conversion_matches_the_cpu_reference() {
    let mut pipe = pipeline(W, H);
    let (w, h) = (W as usize, H as usize);
    let gbm = pipe.gbm().clone();
    let bo: Bo = gbm.create_bo(W, H, DRM_FORMAT_XRGB8888, MUTTER_MODIFIER).expect("a GBM buffer at Mutter's modifier");
    println!("GBM {} buffer: modifier {:#x}, stride {}", gbm.backend_name(), bo.modifier(), bo.stride());
    let plane = |bo: &Bo| DmaBufPlane {
        fd: bo.fd().unwrap(),
        fourcc: DRM_FORMAT_XRGB8888,
        modifier: bo.modifier(),
        offset: bo.offset(),
        stride: bo.stride(),
        size: {
            let fd = bo.fd().unwrap();
            rustix::fs::seek(&fd, rustix::fs::SeekFrom::End(0)).unwrap()
        },
    };
    let surface = pipe.surface_ids()[0];
    // The text-like content, then every 24-bit colour (frames 0–2), then random pixels (frame 3).
    let cases = [(0, false), (5, false), (0, true), (1, true), (2, true), (3, true)];
    let mut worst = (0, 0);
    for (frame, all) in cases {
        let bgrx = synthetic_bgrx(w, h, frame, all);
        pipe.converter().fill_dmabuf(&plane(&bo), &bgrx).expect("filling the buffer");
        pipe.start_conversion(&Picture { width: W, height: H, pixels: Pixels::DmaBuf(plane(&bo)) }, 0).unwrap();
        while !pipe.poll_conversion(1_000_000).unwrap() {}
        let got = pipe.va().get_nv12(surface, W, H).unwrap();
        let want = reference_nv12(&bgrx, w, h);
        let (ey, ec, off) = max_error(&got.data, &want, w, h);
        println!(
            "  frame {frame} ({}): Y max {ey}, CbCr max {ec}, {off} samples off",
            if all { "all colours" } else { "terminal" }
        );
        worst = (worst.0.max(ey), worst.1.max(ec));
        // The shared-memory path converts the same.
        if frame == 0 && !all {
            let pixels = Pixels::Memory { data: bgrx.clone(), stride: W * 4 };
            pipe.start_conversion(&Picture { width: W, height: H, pixels }, 1).unwrap();
            while !pipe.poll_conversion(1_000_000).unwrap() {}
            let shm = pipe.va().get_nv12(pipe.surface_ids()[1], W, H).unwrap();
            let (sy, sc, _) = max_error(&shm.data, &want, w, h);
            println!("  frame 0 through shared memory: Y max {sy}, CbCr max {sc}");
            assert!(sy <= 1 && sc <= 1);
        }
    }
    assert!(worst.0 <= 1 && worst.1 <= 1, "max error 1 (f32 rounding at ties), got {worst:?}");

    // Timing: 300 conversions back to back of the same buffer.
    let mut wall = Vec::new();
    let mut gpu = Vec::new();
    let picture = Picture { width: W, height: H, pixels: Pixels::DmaBuf(plane(&bo)) };
    for i in 0..300 {
        let t0 = Instant::now();
        pipe.start_conversion(&picture, i % 2).unwrap();
        while !pipe.poll_conversion(1_000_000).unwrap() {}
        wall.push(t0.elapsed().as_nanos() as u64);
        gpu.push(pipe.converter().last_timing().gpu_ns);
    }
    println!("conversion 2752×2064, back to back:");
    summary("GPU (timer queries)", &mut gpu);
    summary("CPU submit → fence", &mut wall);
}

#[test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
fn opens_only_the_amd_node() {
    let pipe = pipeline(W, H);
    let mut dri = Vec::new();
    for entry in std::fs::read_dir("/proc/self/fd").unwrap() {
        let Ok(target) = std::fs::read_link(entry.unwrap().path()) else { continue };
        let t = target.display().to_string();
        assert!(!t.starts_with("/dev/nvidia"), "an NVIDIA device is open: {t}");
        if t.starts_with("/dev/dri/") {
            dri.push(t);
        }
    }
    println!("open DRM nodes: {dri:?}");
    assert!(!dri.is_empty() && dri.iter().all(|d| *d == pipe.node().path.display().to_string()), "{dri:?}");
}

/// The GPU pipeline plus a ring of filled GBM buffers, as the video thread's `Gpu` (the buffers live there, with
/// the GL context they were filled on).
struct WithRing {
    pipe: GpuPipeline,
    _ring: Vec<Bo>,
}

impl Gpu for WithRing {
    fn surfaces(&self) -> usize {
        self.pipe.surfaces()
    }
    fn start_conversion(&mut self, picture: &Picture, surface: usize) -> Result<(), String> {
        self.pipe.start_conversion(picture, surface)
    }
    fn poll_conversion(&mut self, timeout_ns: u64) -> Result<bool, String> {
        self.pipe.poll_conversion(timeout_ns)
    }
    fn cancel_conversion(&mut self) {
        self.pipe.cancel_conversion()
    }
    fn submit_encode(&mut self, surface: usize, kind: PictureKind) -> Result<(), String> {
        self.pipe.submit_encode(surface, kind)
    }
    fn poll_encode(&mut self, timeout_ns: u64) -> Option<Result<Vec<u8>, String>> {
        self.pipe.poll_encode(timeout_ns)
    }
    fn rebuild_encoder(&mut self) -> Result<(), String> {
        self.pipe.rebuild_encoder()
    }
}

/// The whole session on the real GPU without PipeWire: 120 Hz synthetic DMA-BUF pictures into the inbox, the
/// core's request pattern (one request outstanding, the newest capture, a keyframe now and then), for 5 s.
#[tokio::test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
async fn engine_end_to_end_synthetic() {
    let (ring_tx, ring_rx) = std_mpsc::channel::<Vec<DmaBufPlane>>();
    let make = move || -> Result<WithRing, String> {
        let node = device::select_system_render_node(None).map_err(|e| e.to_string())?;
        let mut pipe = GpuPipeline::new(&node, settings(W, H))?;
        let gbm = pipe.gbm().clone();
        let mut ring = Vec::new();
        let mut planes = Vec::new();
        for i in 0..6 {
            let bo = gbm.create_bo(W, H, DRM_FORMAT_XRGB8888, MUTTER_MODIFIER)?;
            let fd = bo.fd()?;
            let size = rustix::fs::seek(&fd, rustix::fs::SeekFrom::End(0)).map_err(|e| e.to_string())?;
            let plane = DmaBufPlane {
                fd,
                fourcc: DRM_FORMAT_XRGB8888,
                modifier: bo.modifier(),
                offset: bo.offset(),
                stride: bo.stride(),
                size,
            };
            pipe.converter().fill_dmabuf(&plane, &synthetic_bgrx(W as usize, H as usize, i, false))?;
            planes.push(plane);
            ring.push(bo);
        }
        let _ = ring_tx.send(planes);
        Ok(WithRing { pipe, _ring: ring })
    };
    let (_ended_tx, ended) = tokio::sync::watch::channel(None);
    let info = crate::backend::stream_info(&lain_platform::EncodeConfig {
        width: W,
        height: H,
        frame_rate: 120,
        bitrate: 60_000_000,
        chroma: lain_platform::Chroma::Yuv420,
        bit_depth: 8,
    });
    let (session, mut events, inbox) =
        crate::backend::start_session(make, info, ended, EngineConfig::default(), None).await.expect("a session");
    let planes = ring_rx.recv().unwrap();
    // The capture side: a picture every 8.33 ms, cycling the ring.
    let feeder = std::thread::spawn(move || {
        let start = Instant::now();
        let mut i = 0u32;
        while start.elapsed() < Duration::from_secs(5) {
            let due = start + Duration::from_nanos(u64::from(i) * 1_000_000_000 / 120);
            if let Some(wait) = due.checked_duration_since(Instant::now()) {
                std::thread::sleep(wait);
            }
            let p = &planes[i as usize % planes.len()];
            let plane = DmaBufPlane {
                fd: p.fd.try_clone().unwrap(),
                fourcc: p.fourcc,
                modifier: p.modifier,
                offset: p.offset,
                stride: p.stride,
                size: p.size,
            };
            let picture = Picture { width: W, height: H, pixels: Pixels::DmaBuf(plane) };
            inbox.push_frame(CaptureFrame::new(picture, lain_platform::clock::now_ns(), None));
            i += 1;
        }
        i
    });
    // The core: one request outstanding, for the newest capture; a keyframe every 120 frames.
    let (mut outstanding, mut next_id, mut newest_seen, mut requested) = (false, 1u32, 0u64, 0u64);
    let (mut latency, mut encode, mut sizes, mut keyframes, mut failed) = (Vec::new(), Vec::new(), Vec::new(), 0, 0);
    let t0 = Instant::now();
    let mut captured = 0u64;
    let mut encoded_captures = std::collections::HashSet::new();
    while t0.elapsed() < Duration::from_millis(5200) {
        let Ok(Some(event)) = tokio::time::timeout(Duration::from_millis(200), events.recv()).await else { break };
        match event {
            VideoEvent::Captured { capture, .. } => {
                captured += 1;
                newest_seen = capture;
            }
            VideoEvent::Encoded(f) => {
                outstanding = false;
                encoded_captures.insert(f.capture);
                if t0.elapsed() > Duration::from_millis(500) {
                    latency.push(f.encode_done_ns - f.capture_ns);
                    encode.push(f.encode_done_ns - f.submit_ns);
                    sizes.push(f.annexb.len() as u64);
                }
                keyframes += u32::from(f.keyframe);
            }
            VideoEvent::EncodeFailed { .. } => {
                outstanding = false;
                failed += 1;
            }
            other => panic!("{other:?}"),
        }
        if !outstanding && newest_seen > requested {
            requested = newest_seen;
            session.encode(EncodeRequest { frame_id: next_id, keyframe: next_id % 120 == 0, refinement: false });
            next_id += 1;
            outstanding = true;
        }
    }
    let pushed = feeder.join().unwrap();
    session.stop().await;
    let stats = session.stats();
    println!("engine end to end, synthetic 120 Hz DMA-BUF pictures at 2752×2064, 5 s:");
    println!(
        "  pushed {pushed}, captured {captured}, replaced unconverted {}, encoded {} ({:.1}/s), failed {failed}, keyframes {keyframes}",
        stats.replaced,
        stats.encoded,
        stats.encoded as f64 / 5.0
    );
    println!(
        "  captures never encoded (newest wins): {} ({:.1}/s)",
        captured - encoded_captures.len() as u64,
        (captured - encoded_captures.len() as u64) as f64 / 5.0
    );
    summary("capture → AU", &mut latency);
    summary("submit → AU", &mut encode);
    sizes_summary("AU size", &mut sizes);
    assert_eq!(failed, 0);
    assert!(stats.encoded as f64 / 5.0 > 100.0, "about 120 encodes a second");
}

/// The SPS the driver wrote into an IDR's access unit, parsed (Mesa writes its own: `crate::bitstream`'s doc).
fn output_sps(au: &[u8]) -> crate::bitstream::tests::ParsedSps {
    let sets = lain_media::hevc::parameter_sets(au).expect("the IDR's parameter sets");
    let sps = sets.iter().find(|n| (n[0] >> 1) & 0x3F == 33).expect("an SPS");
    crate::bitstream::tests::parse_sps(&[&[0, 0, 0, 1], sps.as_slice()].concat())
}

/// Mesa's SPS describes exactly the visible size at every size (it codes at VCN's 64 × 16 and keeps the packed
/// SPS's conformance window), and keeps the level, the VUI colour, range and timing. The 2420×1668 stream is
/// dumped for the decode check.
#[test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
fn the_stream_is_the_display_size() {
    for (w, h) in [(1366, 770), (1920, 1080), (2732, 2048), (2420, 1668), (W, H)] {
        let mut pipe = pipeline(w, h);
        let pictures = fill_surfaces(&pipe, w, h, Content::Gradient);
        let aus = encode_run(&mut pipe, 8, |i| PictureKind { idr: i == 0, refinement: false });
        let sps = output_sps(&aus[0].au);
        let ours = settings(w, h).encoder.headers();
        println!(
            "{w}×{h}: Mesa's SPS coded {:?}, window {:?}, visible {:?}, level {}, depths {:?}, colour {:?}, full \
             range {}, timing {:?} (ours coded {:?})",
            sps.coded,
            sps.crop,
            sps.visible(),
            sps.level,
            sps.depths,
            sps.colour,
            sps.full_range,
            sps.timing,
            ours.coded_size()
        );
        assert_eq!(sps.visible(), (w, h), "{w}×{h}");
        assert_eq!(sps.coded, ours.coded_size(), "Mesa codes at the size the packed SPS says");
        assert_eq!(sps.level, u32::from(ours.level_idc));
        assert_eq!((sps.colour, sps.full_range, sps.timing), ((1, 13, 1), true, (1, 120)));
        if (w, h) == (2420, 1668) {
            let all: Vec<&[u8]> = aus.iter().map(|c| c.au.as_slice()).collect();
            let (stream, nv12) = dump("size-2420x1668", &all, &pictures[aus[7].surface]);
            println!("decode check: decode-check.py {} {} {w} {h} 7", stream.display(), nv12.display());
        }
    }
}

/// A refinement that is also an IDR (a keyframe asked for on an idle desktop, or the engine's IDR after a
/// failure), then ordinary P-frames: the stream must decode on, whatever init QP Mesa's PPS took.
#[test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
fn refinement_idr_then_p_frames() {
    let mut pipe = pipeline(W, H);
    let pictures = fill_surfaces(&pipe, W, H, Content::Gradient);
    let aus = encode_run(&mut pipe, 20, |i| PictureKind { idr: i == 0 || i == 10, refinement: i == 10 });
    for (i, c) in aus.iter().enumerate().skip(8).take(5) {
        println!("  picture {i}: {} bytes, average QP {}, NAL types {:?}", c.au.len(), c.qp, nal_types(&c.au));
    }
    let pps = |au: &[u8]| {
        let sets = lain_media::hevc::parameter_sets(au).unwrap();
        sets.iter().find(|n| (n[0] >> 1) & 0x3F == 34).unwrap().clone()
    };
    println!("PPS after the plain IDR {:02x?}, after the refinement IDR {:02x?}", pps(&aus[0].au), pps(&aus[10].au));
    let all: Vec<&[u8]> = aus.iter().map(|c| c.au.as_slice()).collect();
    let (stream, nv12) = dump("refinement-idr", &all, &pictures[aus[19].surface]);
    println!("decode check: decode-check.py {} {} {W} {H} 19", stream.display(), nv12.display());
    let (stream, nv12) = dump("refinement-idr-at-10", &all, &pictures[aus[10].surface]);
    println!("decode check: decode-check.py {} {} {W} {H} 10", stream.display(), nv12.display());
}

/// A conversion that reports a GL error leaves no fence behind: the next one starts (the converter used to keep
/// it, and refuse every later conversion as "already in flight"). At a size VCN pads (1366×770 in 1408×784
/// surfaces), the conversion still matches the CPU reference in the visible area.
#[test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
fn a_gl_error_does_not_wedge_the_converter() {
    let (w, h) = (1366, 770);
    let mut pipe = pipeline(w, h);
    let gbm = pipe.gbm().clone();
    let bo = gbm.create_bo(w, h, DRM_FORMAT_XRGB8888, MUTTER_MODIFIER).expect("a GBM buffer");
    let size = rustix::fs::seek(bo.fd().unwrap(), rustix::fs::SeekFrom::End(0)).unwrap();
    let plane = || DmaBufPlane {
        fd: bo.fd().unwrap(),
        fourcc: DRM_FORMAT_XRGB8888,
        modifier: bo.modifier(),
        offset: bo.offset(),
        stride: bo.stride(),
        size,
    };
    pipe.converter().fill_dmabuf(&plane(), &synthetic_bgrx(w as usize, h as usize, 0, false)).unwrap();
    let picture = Picture { width: w, height: h, pixels: Pixels::DmaBuf(plane()) };
    pipe.start_conversion(&picture, 0).unwrap();
    while !pipe.poll_conversion(1_000_000).unwrap() {}
    // The import is cached now, so the pending error is first seen after the dispatch.
    pipe.converter().inject_gl_error();
    let err = pipe.start_conversion(&picture, 1).unwrap_err();
    println!("with a GL error pending: {err}");
    assert!(err.contains("dispatching"), "{err}");
    pipe.start_conversion(&picture, 2).expect("the next conversion starts");
    while !pipe.poll_conversion(1_000_000).unwrap() {}
    // Read the whole coded surface back, then compare its visible area.
    let (cw, ch) = pipe.settings().encoder.headers().coded_size();
    let got = pipe.va().get_nv12(pipe.surface_ids()[2], cw, ch).unwrap();
    let (wu, hu, cwu, chu) = (w as usize, h as usize, cw as usize, ch as usize);
    let mut visible = Vec::with_capacity(wu * hu * 3 / 2);
    for y in 0..hu {
        visible.extend_from_slice(&got.data[y * cwu..y * cwu + wu]);
    }
    for y in 0..hu / 2 {
        let at = cwu * chu + y * cwu;
        visible.extend_from_slice(&got.data[at..at + wu]);
    }
    let want = reference_nv12(&synthetic_bgrx(wu, hu, 0, false), wu, hu);
    let (ey, ec, off) = max_error(&visible, &want, wu, hu);
    println!("{w}×{h} in {cw}×{ch} surfaces: Y max {ey}, CbCr max {ec}, {off} samples off");
    assert!(ey <= 1 && ec <= 1);
}

/// A rebuild with a picture still in flight tears the session down without waiting it out (the engine's video
/// thread can't stop for long), and the rebuilt session's IDR decodes.
#[test]
#[ignore = "GPU: run through rust/scripts/gpu-run.sh"]
fn rebuild_with_a_picture_in_flight() {
    let mut pipe = pipeline(W, H);
    let pictures = fill_surfaces(&pipe, W, H, Content::Terminal);
    let mut aus = encode_run(&mut pipe, 5, |i| PictureKind { idr: i == 0, refinement: false });
    let mut worst = Duration::ZERO;
    for round in 0..5 {
        pipe.submit_encode(round % 4, PictureKind { idr: false, refinement: false }).expect("submit");
        let t = Instant::now();
        pipe.rebuild_encoder().expect("rebuild");
        let took = t.elapsed();
        worst = worst.max(took);
        println!("  rebuild {round} with a picture in flight: {:.2} ms", took.as_secs_f64() * 1e3);
    }
    assert!(worst < Duration::from_millis(200), "a rebuild waits at most REBUILD_WAIT_NS for the picture: {worst:?}");
    // A fresh session: an IDR and P-frames, decodable on their own.
    let start = aus.len();
    aus.extend(encode_run(&mut pipe, 6, |i| PictureKind { idr: i == 0, refinement: false }));
    assert!(nal_types(&aus[start].au).contains(&19));
    let tail: Vec<&[u8]> = aus[start..].iter().map(|c| c.au.as_slice()).collect();
    let (stream, nv12) = dump("rebuild-in-flight", &tail, &pictures[aus[start + 5].surface]);
    println!("decode check: decode-check.py {} {} {W} {H} 5", stream.display(), nv12.display());
}
