//! Real capture: Mutter `RecordMonitor` on a physical monitor → `pipewiresrc` → vapostproc → vah265enc.
//!
//! Every frame Mutter delivers is encoded (no request gating: the point is the capture path, zero-copy
//! or not, and the latency of real frames). The ScreenCast session ends when this returns (Stop, and the
//! D-Bus connection closing).

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gstreamer as gst;
use gstreamer::prelude::*;
use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{OwnedObjectPath, Value};

use crate::stats::summary;
use crate::{Args, BusySampler, bus_error, configure_encoder, cpu_ns, is_irap, loadavg, nal_types, now_ns};

#[derive(Default, Clone)]
struct Rec {
    t_src: u64,
    t_enc_in: u64,
    t_out: u64,
    size: usize,
    irap: bool,
}

pub fn run(args: &Args) {
    let w: u32 = args.get("width", 2752);
    let h: u32 = args.get("height", 2064);
    let seconds: f64 = args.get("seconds", 10.0);
    let connector = args.str("connector", "HDMI-1");
    let cursor_mode: u32 = args.get("cursor-mode", 2);
    let force_shm = args.map.contains_key("shm");
    println!("loadavg before: {}", loadavg());

    let conn = Connection::session().expect("session bus");
    let sc = Proxy::new(&conn, "org.gnome.Mutter.ScreenCast", "/org/gnome/Mutter/ScreenCast", "org.gnome.Mutter.ScreenCast")
        .unwrap();
    let props: HashMap<&str, Value<'_>> = HashMap::new();
    let session_path: OwnedObjectPath = sc.call("CreateSession", &(props,)).expect("CreateSession");
    let session = Proxy::new(&conn, "org.gnome.Mutter.ScreenCast", session_path.as_str(), "org.gnome.Mutter.ScreenCast.Session")
        .unwrap();
    let mut rprops: HashMap<&str, Value<'_>> = HashMap::new();
    rprops.insert("cursor-mode", Value::U32(cursor_mode));
    let stream_path: OwnedObjectPath =
        session.call("RecordMonitor", &(connector.as_str(), rprops)).expect("RecordMonitor");
    let stream =
        Proxy::new(&conn, "org.gnome.Mutter.ScreenCast", stream_path.as_str(), "org.gnome.Mutter.ScreenCast.Stream").unwrap();
    let mut added = stream.receive_signal("PipeWireStreamAdded").unwrap();
    let _: () = session.call("Start", &()).expect("Start");
    let msg = added.next().expect("PipeWireStreamAdded");
    let (node,): (u32,) = msg.body().deserialize().unwrap();
    println!("RecordMonitor {connector}: PipeWire node {node} (cursor-mode {cursor_mode})");

    let src_caps = if force_shm { " ! video/x-raw" } else { "" };
    // Mutter sends a frame only when the monitor changes; keepalive re-sends the last one so the path can
    // be timed at a steady rate on an idle desktop (the content is then static).
    let keepalive: u32 = args.get("keepalive-ms", 0);
    let colorimetry = args.str("colorimetry", "");
    let colorimetry = if colorimetry.is_empty() { String::new() } else { format!(",colorimetry={colorimetry}") };
    let desc = format!(
        "pipewiresrc name=pw path={node} always-copy=false do-timestamp=true keepalive-time={keepalive}{src_caps} ! \
         vapostproc name=pp ! video/x-raw(memory:VAMemory),format=NV12,width={w},height={h}{colorimetry} ! \
         vah265enc name=enc ! video/x-h265,profile=main ! fakesink sync=false async=false"
    );
    let pipeline = gst::parse::launch(&desc).unwrap().downcast::<gst::Pipeline>().unwrap();
    let enc = pipeline.by_name("enc").unwrap();
    configure_encoder(&enc, args);

    // Matched in order (the encoder rewrites timestamps; nothing between pipewiresrc and the encoder
    // drops or reorders): capture times queue up at the source, move on at the encoder's input.
    let recs: Arc<Mutex<Vec<Rec>>> = Arc::default();
    let at_src: Arc<Mutex<VecDeque<u64>>> = Arc::default();
    let at_enc: Arc<Mutex<VecDeque<(u64, u64)>>> = Arc::default();
    let mem_kinds: Arc<Mutex<HashMap<String, u64>>> = Arc::default();
    {
        let q = at_src.clone();
        let mk = mem_kinds.clone();
        pipeline.by_name("pw").unwrap().static_pad("src").unwrap().add_probe(gst::PadProbeType::BUFFER, move |_, info| {
            if let Some(gst::PadProbeData::Buffer(b)) = &info.data {
                q.lock().unwrap().push_back(now_ns());
                let kind = b
                    .peek_memory(0)
                    .allocator()
                    .map(|a| a.type_().name().to_string())
                    .unwrap_or_else(|| "none".into());
                *mk.lock().unwrap().entry(format!("{kind} x{}", b.n_memory())).or_default() += 1;
            }
            gst::PadProbeReturn::Ok
        });
        let (q, e) = (at_src.clone(), at_enc.clone());
        enc.static_pad("sink").unwrap().add_probe(gst::PadProbeType::BUFFER, move |_, info| {
            if let Some(gst::PadProbeData::Buffer(_)) = &info.data {
                let t_src = q.lock().unwrap().pop_front().unwrap_or(0);
                e.lock().unwrap().push_back((t_src, now_ns()));
            }
            gst::PadProbeReturn::Ok
        });
        let (r, e) = (recs.clone(), at_enc.clone());
        enc.static_pad("src").unwrap().add_probe(gst::PadProbeType::BUFFER, move |_, info| {
            if let Some(gst::PadProbeData::Buffer(b)) = &info.data {
                let t = now_ns();
                let map = b.map_readable().unwrap();
                let (t_src, t_enc_in) = e.lock().unwrap().pop_front().unwrap_or((0, 0));
                r.lock().unwrap().push(Rec { t_src, t_enc_in, t_out: t, size: map.len(), irap: is_irap(&nal_types(&map)) });
            }
            gst::PadProbeReturn::Ok
        });
    }
    pipeline.set_state(gst::State::Playing).expect("pipeline");
    let busy = BusySampler::start();
    let cpu0 = cpu_ns();
    let t0 = now_ns();
    let mut printed_caps = false;
    while now_ns() - t0 < (seconds * 1e9) as u64 {
        std::thread::sleep(Duration::from_millis(100));
        if let Some(e) = bus_error(&pipeline) {
            eprintln!("pipeline error: {e}");
            break;
        }
        if !printed_caps && let Some(c) = pipeline.by_name("pw").unwrap().static_pad("src").unwrap().current_caps() {
            println!("pipewiresrc caps: {c}");
            if let Some(c) = pipeline.by_name("pp").unwrap().static_pad("src").unwrap().current_caps() {
                println!("vapostproc out caps: {c}");
            }
            printed_caps = true;
        }
    }
    let wall = now_ns() - t0;
    let cpu = cpu_ns() - cpu0;
    let gfx = busy.finish();
    let load_after = loadavg();
    pipeline.set_state(gst::State::Null).unwrap();
    let _: Result<(), _> = session.call("Stop", &());
    drop(conn);

    let recs = recs.lock().unwrap();
    let done: Vec<&Rec> = recs.iter().filter(|r| r.t_out > 0 && r.t_enc_in > 0).collect();
    let enc_ns: Vec<u64> = done.iter().map(|r| r.t_out - r.t_enc_in).collect();
    let tot_ns: Vec<u64> = done.iter().filter(|r| r.t_src > 0).map(|r| r.t_out - r.t_src).collect();
    println!("frames: {} encoded in {:.1} s = {:.1} fps", done.len(), wall as f64 / 1e9, done.len() as f64 * 1e9 / wall as f64);
    println!("memory of captured buffers: {:?}", mem_kinds.lock().unwrap());
    println!("{}", summary("encode (enc sink → src)", &enc_ns));
    println!("{}", summary("pipewiresrc out → AU (CSC + scale + encode)", &tot_ns));
    println!("IRAP pictures: {}", done.iter().filter(|r| r.irap).count());
    let sizes: Vec<u64> = done.iter().map(|r| r.size as u64).collect();
    println!("AU size mean {:.1} KB", crate::stats::mean(&sizes) / 1e3);
    println!("cpu: {:.1}% of one core; amd gfx busy mean {gfx:.0}%", cpu as f64 * 100.0 / wall as f64);
    println!("loadavg after: {load_after}");
}
