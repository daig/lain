//! Spike A: HEVC Main 4:2:0 8-bit encode latency on the AMD iGPU through GStreamer's `vah265enc`.
//!
//! `encbench synth [options]` encodes GPU-resident synthetic content (a ring of VA surfaces made once,
//! then never touched by the CPU) at a fixed tick rate, the way lain's core drives a `VideoSession`:
//! by default one request outstanding, the newest content on each tick.
//! `encbench live [options]` captures a physical monitor with Mutter's `RecordMonitor` through
//! `pipewiresrc` and encodes every frame it delivers.
//!
//! Every time is CLOCK_MONOTONIC. See README.md for the method and the options.

mod live;
mod stats;
mod synth;
mod va;

use std::collections::HashMap;
use std::time::Duration;

use gstreamer as gst;
use gstreamer::prelude::*;

pub fn now_ns() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime only writes the timespec it is given.
    #[allow(unsafe_code)]
    unsafe {
        libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts);
    }
    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

/// User plus system CPU time of this process, in nanoseconds.
pub fn cpu_ns() -> u64 {
    let mut ru: libc::rusage = unsafe_zeroed();
    // SAFETY: getrusage only writes the struct it is given.
    #[allow(unsafe_code)]
    unsafe {
        libc::getrusage(libc::RUSAGE_SELF, &mut ru);
    }
    let tv = |t: libc::timeval| t.tv_sec as u64 * 1_000_000_000 + t.tv_usec as u64 * 1000;
    tv(ru.ru_utime) + tv(ru.ru_stime)
}

fn unsafe_zeroed() -> libc::rusage {
    // SAFETY: rusage is plain integers; all-zero is valid.
    #[allow(unsafe_code)]
    unsafe {
        std::mem::zeroed()
    }
}

pub fn loadavg() -> String {
    std::fs::read_to_string("/proc/loadavg").unwrap_or_default().trim().to_string()
}

/// The AMD iGPU's `gpu_busy_percent` (the GFX/compute engine, not VCN), found by PCI vendor 0x1002.
pub fn amd_busy_path() -> Option<String> {
    for entry in std::fs::read_dir("/sys/class/drm").ok()?.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.starts_with("card") || name.contains('-') {
            continue;
        }
        let dev = entry.path().join("device");
        if std::fs::read_to_string(dev.join("vendor")).ok()?.trim() == "0x1002" {
            return Some(dev.join("gpu_busy_percent").to_string_lossy().to_string());
        }
    }
    None
}

/// Samples the AMD GFX busy percentage every 10 ms until `stop` is set; returns the mean.
pub struct BusySampler {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    handle: Option<std::thread::JoinHandle<f64>>,
}

impl BusySampler {
    pub fn start() -> Self {
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let s = stop.clone();
        let handle = amd_busy_path().map(|path| {
            std::thread::spawn(move || {
                let (mut sum, mut n) = (0.0, 0u32);
                while !s.load(std::sync::atomic::Ordering::Relaxed) {
                    if let Ok(v) = std::fs::read_to_string(&path)
                        && let Ok(v) = v.trim().parse::<f64>()
                    {
                        sum += v;
                        n += 1;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                if n == 0 { f64::NAN } else { sum / n as f64 }
            })
        });
        BusySampler { stop, handle }
    }

    pub fn finish(mut self) -> f64 {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        self.handle.take().and_then(|h| h.join().ok()).unwrap_or(f64::NAN)
    }
}

/// `--key value` options; repeated `--enc prop=value` collected in order.
pub struct Args {
    pub map: HashMap<String, String>,
    pub enc: Vec<(String, String)>,
}

impl Args {
    fn parse(it: impl Iterator<Item = String>) -> Args {
        let mut map = HashMap::new();
        let mut enc = Vec::new();
        let mut it = it.peekable();
        while let Some(k) = it.next() {
            let k = k.trim_start_matches("--").to_string();
            let v = match it.peek() {
                Some(v) if !v.starts_with("--") => it.next().unwrap(),
                _ => "true".to_string(),
            };
            if k == "enc" {
                let (p, val) = v.split_once('=').expect("--enc prop=value");
                enc.push((p.to_string(), val.to_string()));
            } else {
                map.insert(k, v);
            }
        }
        Args { map, enc }
    }

    pub fn get<T: std::str::FromStr>(&self, k: &str, default: T) -> T {
        self.map.get(k).map(|v| v.parse().unwrap_or_else(|_| panic!("bad --{k} {v}"))).unwrap_or(default)
    }

    pub fn str(&self, k: &str, default: &str) -> String {
        self.map.get(k).cloned().unwrap_or_else(|| default.to_string())
    }
}

/// The encoder's settings, low-latency defaults: CBR 60 Mbps, no B-frames, one reference, the longest
/// GOP the element allows, speed-first target usage. `--enc prop=value` overrides or adds any property.
pub fn configure_encoder(enc: &gst::Element, args: &Args) {
    let fps: u32 = args.get("fps", 120);
    let defaults: [(&str, String); 6] = [
        ("rate-control", args.str("rc", "cbr")),
        ("bitrate", args.str("bitrate", "60000")),
        ("b-frames", "0".into()),
        ("ref-frames", args.str("ref", "1")),
        ("key-int-max", args.str("keyint", "1024")),
        ("target-usage", args.str("tu", "7")),
    ];
    for (k, v) in defaults.iter() {
        enc.set_property_from_str(k, v);
    }
    if args.map.contains_key("cpb-frames") {
        // CPB size in kbit for N frames' worth of the bitrate.
        let kbps: u32 = args.get("bitrate", 60000);
        let frames: u32 = args.get("cpb-frames", 1);
        enc.set_property("cpb-size", kbps * frames / fps);
    }
    for (k, v) in &args.enc {
        enc.set_property_from_str(k, v);
    }
    let mut desc = Vec::new();
    for p in [
        "device-path",
        "rate-control",
        "bitrate",
        "cpb-size",
        "b-frames",
        "ref-frames",
        "key-int-max",
        "target-usage",
        "min-qp",
        "max-qp",
        "qpi",
        "qpp",
        "mbbrc",
        "num-slices",
    ] {
        let v = enc.property_value(p);
        let s = v
            .serialize()
            .map(|s| s.to_string())
            .unwrap_or_else(|_| format!("{v:?}"));
        desc.push(format!("{p}={s}"));
    }
    println!("encoder: {}", desc.join(" "));
    let dev = enc.property::<String>("device-path");
    assert!(
        std::fs::read_to_string(format!("/sys/class/drm/{}/device/vendor", dev.trim_start_matches("/dev/dri/")))
            .map(|v| v.trim() == "0x1002")
            .unwrap_or(false),
        "encoder is on {dev}, which is not the AMD GPU"
    );
}

/// NAL unit types of an Annex-B access unit.
pub fn nal_types(au: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 3 < au.len() {
        if au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1 {
            out.push((au[i + 3] >> 1) & 0x3f);
            i += 3;
        } else {
            i += 1;
        }
    }
    out
}

/// IDR_W_RADL (19), IDR_N_LP (20) or CRA (21).
pub fn is_irap(types: &[u8]) -> bool {
    types.iter().any(|t| (16..=21).contains(t))
}

pub fn bus_error(pipeline: &gst::Pipeline) -> Option<String> {
    let bus = pipeline.bus()?;
    while let Some(msg) = bus.pop() {
        match msg.view() {
            gst::MessageView::Error(e) => return Some(format!("{} ({:?})", e.error(), e.debug())),
            gst::MessageView::Warning(w) => eprintln!("warning: {} ({:?})", w.error(), w.debug()),
            _ => {}
        }
    }
    None
}

fn main() {
    gst::init().expect("gst init");
    let mut argv = std::env::args().skip(1);
    let mode = argv.next().unwrap_or_default();
    let args = Args::parse(argv);
    if mode != "synth" && mode != "live" {
        eprintln!("usage: encbench synth|live [--key value]... (see README.md)");
        std::process::exit(2);
    }
    // The AMD node, its element factories and a display context pinned to it, before any pipeline exists.
    let va = va::Va::new(args.map.get("render-node").map(|s| s.as_str()));
    match mode.as_str() {
        "synth" => synth::run(&args, &va),
        "live" => live::run(&args, &va),
        _ => {
            eprintln!("usage: encbench synth|live [--key value]... (see README.md)");
            std::process::exit(2);
        }
    }
}
