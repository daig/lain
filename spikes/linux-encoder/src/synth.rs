//! Synthetic, GPU-resident content encoded on a fixed tick, the way lain's core drives a `VideoSession`.
//!
//! A ring of `--ring` frames is made once in VA surfaces (BGRx, like a screen capture), so the encode loop
//! never touches pixels on the CPU. Tick k (at `--fps`) "captures" ring frame k mod ring. Whenever fewer
//! than `--inflight` requests are outstanding (default 1, lain's rule) the newest tick not yet encoded is
//! pushed: appsrc → vapostproc (BGRx → NV12 on the GPU) → vah265enc → fakesink. Pad probes time each
//! stage.

use std::collections::HashMap;
use std::io::Write;
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use gstreamer_video as gst_video;

use crate::stats::{mean, summary};
use crate::va::{Va, assert_no_foreign_gpu_fds};
use crate::{Args, BusySampler, bus_error, configure_encoder, cpu_ns, is_irap, loadavg, nal_types, now_ns};

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Kind {
    Normal,
    Idr,
    Refine,
}

#[derive(Default, Clone)]
struct Rec {
    t_push: u64,
    t_pp_in: u64,
    t_enc_in: u64,
    t_out: u64,
    size: usize,
    types: Vec<u8>,
}

/// A terminal-like tile: rows of glyph-sized high-frequency blobs in a few colours on a dark background,
/// periodic every `period` rows so the scroll wraps seamlessly.
fn text_frame(w: usize, h: usize, offset: usize, period: usize) -> Vec<u8> {
    let hash = |a: u64| {
        let mut x = a.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        x ^= x >> 29;
        x = x.wrapping_mul(0xBF58_476D_1CE4_E5B9);
        x ^ (x >> 32)
    };
    let palette: [[u8; 3]; 5] = [[220, 220, 220], [120, 220, 120], [240, 200, 90], [110, 160, 255], [230, 110, 200]];
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        let ty = (y + offset) % period;
        let line = ty / 18;
        let gy = ty % 18;
        let len = 40 + (hash(line as u64 * 7 + 1) % 300) as usize; // characters on this line
        for x in 0..w {
            let px = &mut out[(y * w + x) * 4..(y * w + x) * 4 + 4];
            let (mut b, mut g, mut r) = (40u8, 30u8, 48u8); // purple-grey background
            let col = x / 9;
            let gx = x % 9;
            if col < len && (1..15).contains(&gy) && gx < 8 {
                let glyph = hash((line as u64) << 20 | col as u64);
                if glyph % 7 != 0 {
                    // a 4×7 bitmap scaled 2×2
                    let bit = (gy - 1) / 2 * 4 + gx / 2;
                    if (glyph >> (bit % 64)) & 1 == 1 {
                        let c = palette[(hash(line as u64 * 31 + col as u64 / 12) % 5) as usize];
                        (r, g, b) = (c[0], c[1], c[2]);
                    }
                }
            }
            px[0] = b;
            px[1] = g;
            px[2] = r;
            px[3] = 255;
        }
    }
    out
}

/// Makes the ring of VA-surface frames; returns them, their caps, and the pipeline that owns their pool
/// (kept alive; every pipeline shares the pinned VA display, so no frame is copied between them).
fn make_ring(args: &Args, va: &Va, w: u32, h: u32, fps: u32) -> (Vec<gst::Buffer>, gst::Caps, gst::Pipeline) {
    let n: usize = args.get("ring", 32);
    let content = args.str("content", "text");
    let ring_format = args.str("ring-format", "BGRx");
    let raw = format!("video/x-raw,format=BGRx,width={w},height={h},framerate={fps}/1");
    let src = match content.as_str() {
        "text" => format!("appsrc name=gen format=time caps={raw}"),
        "smpte" | "ball" | "zone-plate" | "snow" => {
            let speed: i32 = args.get("speed", 16);
            let extra = if content == "zone-plate" { " kt=2" } else { "" };
            format!("videotestsrc pattern={content} horizontal-speed={speed}{extra} num-buffers={n} ! {raw}")
        }
        other => panic!("unknown --content {other}"),
    };
    let desc = format!(
        "{src} ! {} name=up ! video/x-raw(memory:VAMemory),format={ring_format} ! appsink name=sink sync=false",
        va.postproc
    );
    let pipeline = gst::parse::launch(&desc).unwrap().downcast::<gst::Pipeline>().unwrap();
    va.pin(&pipeline);
    let sink = pipeline.by_name("sink").unwrap().downcast::<gst_app::AppSink>().unwrap();
    pipeline.set_state(gst::State::Playing).expect("ring pipeline");
    if content == "text" {
        let gen_src = pipeline.by_name("gen").unwrap().downcast::<gst_app::AppSrc>().unwrap();
        let step: usize = args.get("step", 18);
        let period = n * step;
        let t = std::time::Instant::now();
        for i in 0..n {
            let mut buf = gst::Buffer::from_mut_slice(text_frame(w as usize, h as usize, i * step, period));
            buf.get_mut().unwrap().set_pts(gst::ClockTime::from_nseconds(i as u64 * 1_000_000_000 / fps as u64));
            gen_src.push_buffer(buf).unwrap();
        }
        gen_src.end_of_stream().unwrap();
        eprintln!("generated {n} text frames in {:?}", t.elapsed());
    }
    let mut ring = Vec::new();
    let mut caps = None;
    while ring.len() < n {
        let Some(sample) = sink.try_pull_sample(gst::ClockTime::from_seconds(10)) else {
            panic!("ring stalled after {} frames: {:?}", ring.len(), bus_error(&pipeline));
        };
        caps = sample.caps().map(|c| c.to_owned());
        ring.push(sample.buffer_owned().unwrap());
    }
    let caps = caps.unwrap();
    println!("ring: {n} frames of {content}, caps {caps}");
    (ring, caps, pipeline)
}

pub fn run(args: &Args, va: &Va) {
    let w: u32 = args.get("width", 2752);
    let h: u32 = args.get("height", 2064);
    let fps: u32 = args.get("fps", 120);
    let seconds: f64 = args.get("seconds", 10.0);
    let max_inflight: usize = args.get("inflight", 1);
    let idr_every: u64 = args.get("idr-every", 0);
    let refine_every: u64 = args.get("refine-every", 0);
    let refine_count: u32 = args.get("refine-count", 2);
    let refine_set: Vec<(String, String)> = parse_props(&args.str("refine-set", ""));
    let refine_reset: Vec<(String, String)> = parse_props(&args.str("refine-reset", ""));
    let colorimetry = args.str("colorimetry", "");
    let dump = args.map.get("dump").cloned();

    println!("loadavg before: {}", loadavg());
    let (ring, ring_caps, ring_pipeline) = make_ring(args, va, w, h, fps);

    let nv12 = if colorimetry.is_empty() {
        "video/x-raw(memory:VAMemory),format=NV12".to_string()
    } else {
        format!("video/x-raw(memory:VAMemory),format=NV12,colorimetry={colorimetry}")
    };
    // --codec h264 is for comparison only (lain streams HEVC). --queue puts a thread boundary between the
    // conversion and the encoder, so they can overlap when more than one request is in flight.
    let (encoder, out_caps) = match args.str("codec", "h265").as_str() {
        "h264" => (va.h264enc.as_deref().expect("no VA H.264 encoder"), "video/x-h264,profile=high"),
        _ => (va.h265enc.as_str(), "video/x-h265,profile=main"),
    };
    let queue = if args.map.contains_key("queue") { "queue max-size-buffers=2 ! " } else { "" };
    let desc = format!(
        "appsrc name=src format=time is-live=true min-latency=0 max-buffers=4 ! {} name=pp ! {nv12} ! \
         {queue}{encoder} name=enc ! {out_caps} ! fakesink name=sink sync=false async=false",
        va.postproc
    );
    let pipeline = gst::parse::launch(&desc).unwrap().downcast::<gst::Pipeline>().unwrap();
    // One pinned VA display for the ring, the conversion and the encoder: no frame is copied between them.
    va.pin(&pipeline);
    let appsrc = pipeline.by_name("src").unwrap().downcast::<gst_app::AppSrc>().unwrap();

    // --csc-at-capture: a capture thread converts every tick's BGRx frame to NV12 as it is "captured"
    // (appsrc → vapostproc → appsink), keeping only the newest converted frame; requests encode that, so
    // the conversion overlaps the previous encode instead of preceding this one.
    let csc_at_capture = args.map.contains_key("csc-at-capture");
    let latest: Arc<Mutex<Option<(u64, gst::Buffer)>>> = Arc::default();
    let cap_times: Arc<Mutex<HashMap<u64, u64>>> = Arc::default();
    let stop_capture = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut capture_thread = None;
    let mut capture_pipeline = None;
    if csc_at_capture {
        // --csc-queue: how many BGRx frames may wait for the conversion (leaky: the oldest is dropped).
        let csc_queue: u32 = args.get("csc-queue", 2);
        let cdesc = format!(
            "appsrc name=csrc format=time is-live=true min-latency=0 max-buffers={csc_queue} leaky-type=downstream ! \
             {} ! {nv12} ! appsink name=csink sync=false max-buffers=1 drop=true emit-signals=false",
            va.postproc
        );
        let cp = gst::parse::launch(&cdesc).unwrap().downcast::<gst::Pipeline>().unwrap();
        va.pin(&cp);
        let csrc = cp.by_name("csrc").unwrap().downcast::<gst_app::AppSrc>().unwrap();
        csrc.set_caps(Some(&ring_caps));
        let csink = cp.by_name("csink").unwrap().downcast::<gst_app::AppSink>().unwrap();
        let l = latest.clone();
        let fps64 = fps as u64;
        csink.set_callbacks(
            gst_app::AppSinkCallbacks::builder()
                .new_sample(move |s| {
                    let sample = s.pull_sample().map_err(|_| gst::FlowError::Eos)?;
                    let buf = sample.buffer_owned().unwrap();
                    let tick = buf.pts().unwrap().nseconds() * fps64 / 1_000_000_000;
                    *l.lock().unwrap() = Some((tick, buf));
                    Ok(gst::FlowSuccess::Ok)
                })
                .build(),
        );
        cp.set_state(gst::State::Playing).expect("capture pipeline");
        // NV12 caps for the encode pipeline's appsrc: take them from one converted frame.
        csrc.push_buffer(ring[0].copy()).unwrap();
        let caps = loop {
            if let Some(c) = csink.static_pad("sink").unwrap().current_caps() {
                break c;
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        appsrc.set_caps(Some(&caps));
        let ring_c: Vec<gst::Buffer> = ring.clone();
        let stop = stop_capture.clone();
        let ct = cap_times.clone();
        let period = 1_000_000_000 / fps as u64;
        capture_thread = Some(std::thread::spawn(move || {
            let start = now_ns();
            let mut k = 1u64;
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                let due = start + k * period;
                let now = now_ns();
                if now < due {
                    std::thread::sleep(Duration::from_nanos(due - now));
                }
                let mut b = ring_c[k as usize % ring_c.len()].copy();
                b.get_mut().unwrap().set_pts(gst::ClockTime::from_nseconds(k * period));
                ct.lock().unwrap().insert(k, now_ns());
                if csrc.push_buffer(b).is_err() {
                    break;
                }
                k += 1;
            }
        }));
        capture_pipeline = Some(cp);
        // Let the capture side reach steady state.
        std::thread::sleep(Duration::from_millis(100));
    } else {
        appsrc.set_caps(Some(&ring_caps));
    }
    let enc = pipeline.by_name("enc").unwrap();
    configure_encoder(&enc, args);
    assert_eq!(enc.property::<String>("device-path"), va.node, "encoder not on the pinned node");

    let recs: Arc<Mutex<HashMap<u64, Rec>>> = Arc::default();
    let (tx, rx) = mpsc::channel::<u64>();
    let force_pts = Arc::new(std::sync::atomic::AtomicU64::new(u64::MAX));
    let dump_file = dump.map(|p| Arc::new(Mutex::new(std::fs::File::create(p).unwrap())));
    {
        let r = recs.clone();
        pipeline.by_name("pp").unwrap().static_pad("sink").unwrap().add_probe(gst::PadProbeType::BUFFER, move |_, info| {
            if let Some(gst::PadProbeData::Buffer(b)) = &info.data {
                let t = now_ns();
                r.lock().unwrap().entry(b.pts().unwrap().nseconds()).or_default().t_pp_in = t;
            }
            gst::PadProbeReturn::Ok
        });
        // A forced keyframe: the force-key-unit event goes into the encoder's input from its streaming
        // thread, immediately ahead of the frame it is for, so it can't race the frame. (A forced IDR that
        // still comes out without a start code is vah265enc overrunning its coded buffer; see README.)
        let f = force_pts.clone();
        enc.static_pad("sink").unwrap().peer().unwrap().add_probe(gst::PadProbeType::BUFFER, move |pad, info| {
            if let Some(gst::PadProbeData::Buffer(b)) = &info.data
                && b.pts().map(|p| p.nseconds()) == Some(f.load(std::sync::atomic::Ordering::SeqCst))
            {
                let ev = gst_video::DownstreamForceKeyUnitEvent::builder().all_headers(true).build();
                if !pad.push_event(ev) {
                    eprintln!("force-key-unit event refused");
                }
            }
            gst::PadProbeReturn::Ok
        });
        // The encoder rewrites output timestamps, so outputs are matched to inputs in order (there is no
        // reordering: no B-frames).
        let order: Arc<Mutex<std::collections::VecDeque<u64>>> = Arc::default();
        let r = recs.clone();
        let o = order.clone();
        enc.static_pad("sink").unwrap().add_probe(gst::PadProbeType::BUFFER, move |_, info| {
            if let Some(gst::PadProbeData::Buffer(b)) = &info.data {
                let t = now_ns();
                let pts = b.pts().unwrap().nseconds();
                r.lock().unwrap().entry(pts).or_default().t_enc_in = t;
                o.lock().unwrap().push_back(pts);
            }
            gst::PadProbeReturn::Ok
        });
        let r = recs.clone();
        let dump_file = dump_file.clone();
        enc.static_pad("src").unwrap().add_probe(gst::PadProbeType::BUFFER, move |_, info| {
            if let Some(gst::PadProbeData::Buffer(b)) = &info.data {
                let t = now_ns();
                let map = b.map_readable().unwrap();
                if std::env::var_os("ENCBENCH_DEBUG").is_some() {
                    eprintln!("out pts {:?} dts {:?}", b.pts(), b.dts());
                }
                let Some(pts) = order.lock().unwrap().pop_front() else {
                    eprintln!("output with no input");
                    return gst::PadProbeReturn::Ok;
                };
                {
                    let mut g = r.lock().unwrap();
                    let e = g.entry(pts).or_default();
                    e.t_out = t;
                    e.size = map.len();
                    e.types = nal_types(&map);
                    if e.types.is_empty() {
                        let zeros = map.iter().filter(|b| **b == 0).count();
                        eprintln!("AU with no start code: {} B in {} memories, {zeros} zero bytes, head {:02x?}", map.len(), b.n_memory(), &map[..32.min(map.len())]);
                    }
                }
                if let Some(f) = &dump_file {
                    f.lock().unwrap().write_all(&map).unwrap();
                }
                let _ = tx.send(pts);
            }
            gst::PadProbeReturn::Ok
        });
    }
    pipeline.set_state(gst::State::Playing).expect("encode pipeline");

    // Warm-up: one frame, not counted (the first encode allocates and sends headers).
    let mut seq: u64 = 0; // PTS counter: one per push, in ticks of 1/fps
    let period = 1_000_000_000 / fps as u64;
    let push = |seq: &mut u64, buf: &gst::Buffer, recs: &Mutex<HashMap<u64, Rec>>| -> u64 {
        let mut b = buf.copy();
        let pts = *seq * period;
        b.get_mut().unwrap().set_pts(gst::ClockTime::from_nseconds(pts));
        *seq += 1;
        recs.lock().unwrap().entry(pts).or_default().t_push = now_ns();
        appsrc.push_buffer(b).expect("push");
        pts
    };
    let warm = if csc_at_capture { latest.lock().unwrap().as_ref().unwrap().1.clone() } else { ring[0].clone() };
    push(&mut seq, &warm, &recs);
    if rx.recv_timeout(Duration::from_secs(5)).is_err() {
        panic!("first frame never came out: {:?}", bus_error(&pipeline));
    }
    recs.lock().unwrap().clear();

    let total_ticks = (seconds * fps as f64) as u64;
    let mut kinds: HashMap<u64, Kind> = HashMap::new();
    let mut inflight = 0usize;
    let mut last_tick_encoded: i64 = -1;
    let mut normal_encodes = 0u64;
    let mut pending_refines = 0u32;
    let mut refine_active = false;
    let mut last_buf = ring[0].clone();
    let mut push_tick: HashMap<u64, u64> = HashMap::new();
    let mut stalled = false;
    let busy = BusySampler::start();
    let cpu0 = cpu_ns();
    let start = now_ns();
    let mut last_out = start;
    loop {
        let now = now_ns();
        let tick = ((now - start) / period) as i64;
        if tick as u64 >= total_ticks && inflight == 0 {
            break;
        }
        // The newest capture: tick k's ring frame, or (--csc-at-capture) the newest converted frame.
        let newest: Option<(i64, gst::Buffer)> = if csc_at_capture {
            latest.lock().unwrap().as_ref().map(|(t, b)| (*t as i64, b.clone()))
        } else {
            Some((tick, ring[tick as usize % ring.len()].clone()))
        };
        if inflight < max_inflight && (tick as u64) < total_ticks {
            if pending_refines > 0 && inflight == 0 {
                if !refine_active {
                    set_props(&enc, &refine_set);
                    refine_active = true;
                }
                let pts = push(&mut seq, &last_buf, &recs);
                kinds.insert(pts, Kind::Refine);
                pending_refines -= 1;
                inflight += 1;
            } else if pending_refines == 0
                && let Some((frame_tick, frame)) = newest.filter(|(t, _)| *t > last_tick_encoded)
            {
                if refine_active {
                    set_props(&enc, &refine_reset);
                    refine_active = false;
                }
                last_buf = frame;
                let idr = idr_every > 0 && normal_encodes > 0 && normal_encodes % idr_every == 0;
                if idr {
                    force_pts.store(seq * period, std::sync::atomic::Ordering::SeqCst);
                }
                let pts = push(&mut seq, &last_buf, &recs);
                kinds.insert(pts, if idr { Kind::Idr } else { Kind::Normal });
                push_tick.insert(pts, frame_tick as u64);
                last_tick_encoded = frame_tick;
                normal_encodes += 1;
                inflight += 1;
                if refine_every > 0 && normal_encodes % refine_every == 0 {
                    pending_refines = refine_count;
                }
            }
        }
        // Wait for a completion or the next tick.
        let next_tick_at = start + (tick + 1) as u64 * period;
        let mut wait = next_tick_at.saturating_sub(now_ns()).max(50_000);
        if csc_at_capture {
            wait = wait.min(250_000); // new frames arrive on the capture thread's ticks: poll
        }
        if inflight > 0 {
            match rx.recv_timeout(Duration::from_nanos(wait)) {
                Ok(_) => {
                    inflight -= 1;
                    last_out = now_ns();
                    while rx.try_recv().is_ok() {
                        inflight -= 1;
                    }
                }
                Err(_) if now_ns() - last_out > 2_000_000_000 => {
                    stalled = true;
                    eprintln!("STALL: {inflight} request(s) outstanding for 2 s: {:?}", bus_error(&pipeline));
                    break;
                }
                Err(_) => {}
            }
        } else {
            std::thread::sleep(Duration::from_nanos(wait));
        }
        if let Some(e) = bus_error(&pipeline) {
            panic!("pipeline error: {e}");
        }
    }
    let wall = now_ns() - start;
    let cpu = cpu_ns() - cpu0;
    let gfx_busy = busy.finish();
    assert_no_foreign_gpu_fds();
    let load_after = loadavg();
    stop_capture.store(true, std::sync::atomic::Ordering::Relaxed);
    if let Some(t) = capture_thread {
        let _ = t.join();
    }
    if let Some(cp) = &capture_pipeline {
        cp.set_state(gst::State::Null).unwrap();
    }
    pipeline.set_state(gst::State::Null).unwrap();
    ring_pipeline.set_state(gst::State::Null).unwrap();

    // Report.
    let recs = recs.lock().unwrap();
    if std::env::var_os("ENCBENCH_DEBUG").is_some() {
        let mut keys: Vec<_> = recs.keys().copied().collect();
        keys.sort_unstable();
        for k in keys.iter().take(6) {
            let r = &recs[k];
            eprintln!("rec {k}: push {} pp {} enc {} out {} kind {:?}", r.t_push, r.t_pp_in, r.t_enc_in, r.t_out, kinds.get(k));
        }
    }
    let mut by_kind: HashMap<Kind, (Vec<u64>, Vec<u64>, Vec<u64>, Vec<u64>)> = HashMap::new();
    let mut idr_ok = 0;
    let mut idr_missed = 0;
    let mut unrequested_irap = 0;
    // AUs with no start code at all: vah265enc overrunning its coded buffer, almost always on an IDR
    // (forced, or its periodic one every key-int-max frames), so a missing IRAP may be hiding here.
    let mut corrupt: Vec<(usize, Kind)> = Vec::new();
    let mut refine_irap = 0;
    let mut bytes_total = 0usize;
    let mut cap_to_au: Vec<u64> = Vec::new();
    let mut done = 0u64;
    let mut pts_sorted: Vec<_> = kinds.keys().copied().collect();
    pts_sorted.sort_unstable();
    for (index, pts) in pts_sorted.iter().enumerate() {
        let kind = kinds[pts];
        let Some(r) = recs.get(pts) else { continue };
        if r.t_out == 0 {
            continue;
        }
        if r.types.is_empty() {
            // index + 1: the uncounted warm-up frame is the encoder's frame 0.
            corrupt.push((index + 1, kind));
        }
        done += 1;
        bytes_total += r.size;
        let irap = is_irap(&r.types);
        match (kind, irap) {
            (Kind::Idr, true) => idr_ok += 1,
            (Kind::Idr, false) => {
                idr_missed += 1;
                let next = recs.get(&(pts + period)).map(|n| n.types.clone());
                eprintln!("missed IDR at push {}: nal {:?}, {} B; next push nal {next:?}", pts / period, r.types, r.size);
            }
            (Kind::Normal, true) => unrequested_irap += 1,
            (Kind::Refine, true) => refine_irap += 1,
            _ => {}
        }
        // Capture → AU, from the moment the frame encoded was "captured": its tick (convert on request), or
        // the push of its BGRx frame into the conversion (--csc-at-capture). Comparable across both modes,
        // unlike push → AU, which starts after the frame has waited for the previous encode.
        if let Some(&k) = push_tick.get(pts) {
            let t_cap = if csc_at_capture { cap_times.lock().unwrap().get(&k).copied() } else { Some(start + k * period) };
            if let Some(t_cap) = t_cap {
                cap_to_au.push(r.t_out - t_cap);
            }
        }
        let e = by_kind.entry(kind).or_default();
        e.0.push(r.t_out - r.t_enc_in);
        e.1.push(r.t_out - r.t_push);
        e.2.push(r.t_enc_in - r.t_pp_in);
        e.3.push(r.size as u64);
    }
    // Content fps counts new frames (normal and forced IDR) only; refinements re-encode a frame already sent.
    let content = pts_sorted
        .iter()
        .filter(|p| kinds[*p] != Kind::Refine && recs.get(*p).is_some_and(|r| r.t_out > 0))
        .count();
    println!(
        "run: {w}x{h} tick {fps} Hz for {:.2} s, inflight<={max_inflight}: {content} content encodes = {:.1} fps, \
         {} refinements ({} ticks, {:.1}% of ticks encoded){}",
        wall as f64 / 1e9,
        content as f64 * 1e9 / wall as f64,
        done - content as u64,
        total_ticks,
        normal_encodes as f64 * 100.0 / total_ticks as f64,
        if stalled { " STALLED" } else { "" }
    );
    println!(
        "cpu: {:.1}% of one core (user+sys, whole process); amd gfx busy mean {:.0}%; bitrate {:.1} Mbps",
        cpu as f64 * 100.0 / wall as f64,
        gfx_busy,
        bytes_total as f64 * 8.0 / (wall as f64 / 1e9) / 1e6
    );
    for kind in [Kind::Normal, Kind::Idr, Kind::Refine] {
        if let Some((enc_ns, total_ns, csc_ns, sizes)) = by_kind.get(&kind) {
            println!("{kind:?}:");
            println!("  {}", summary("encode (enc sink → src)", enc_ns));
            println!("  {}", summary("push → AU (appsrc + CSC + encode)", total_ns));
            println!("  {}", summary("vapostproc in → enc in", csc_ns));
            println!("  AU size mean {:.1} KB, max {:.1} KB", mean(sizes) / 1e3, *sizes.iter().max().unwrap() as f64 / 1e3);
        }
    }
    let origin = if csc_at_capture { "BGRx frame pushed for conversion" } else { "tick of the frame encoded" };
    println!("{}", summary(&format!("capture ({origin}) → AU"), &cap_to_au));
    if idr_every > 0 {
        println!("forced IDR: {idr_ok} on the requested frame, {idr_missed} not");
    }
    println!("IRAP pictures not requested: {unrequested_irap} normal, {refine_irap} refinement");
    println!(
        "AUs with no start code (corrupt): {} at encoder frames {:?}",
        corrupt.len(),
        corrupt.iter().take(12).collect::<Vec<_>>()
    );
    if refine_every > 0 {
        let sizes: Vec<_> = pts_sorted
            .iter()
            .filter_map(|p| recs.get(p).map(|r| (kinds[p], r.size, r.types.clone())))
            .take(3 + refine_every as usize + refine_count as usize)
            .collect();
        for (k, s, t) in sizes {
            println!("  sequence: {k:?} {s} B nal {t:?}");
        }
    }
    println!("loadavg after: {load_after}");
}

fn parse_props(s: &str) -> Vec<(String, String)> {
    s.split(',')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let (k, v) = p.split_once('=').expect("prop=value");
            (k.to_string(), v.to_string())
        })
        .collect()
}

fn set_props(enc: &gst::Element, props: &[(String, String)]) {
    for (k, v) in props {
        enc.set_property_from_str(k, v);
    }
}
