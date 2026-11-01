//! The video pipeline on a fake clock and lain-platform's fake session (Swift:
//! `LainLoopbackTests/HostVideoPipelineTests`, with what the platform contract adds), and on the real HEVC
//! fixtures.

use std::path::Path;
use std::sync::{Arc, Mutex};

use lain_media::{
    Connection, Outbound, PipelineOptions, VideoEnd, VideoPipeline, encode_config,
    hevc::{self, AccessUnit},
};
use lain_platform::fake::{EncodeMode, FakeClock, FakeSource, FakeVideo, FakeVideoSession, fake_access_unit};
use lain_platform::{
    Chroma, Clock, ColorTags, EncodeConfig, EncodeRequest, EncodedFrame, PlatformError, StreamInfo, StreamedDisplay,
    VideoBackend, VideoEvent, VideoSession,
};
use lain_proto::{
    ChromaFormat, FrameAck, HeaderFlags, KeyframeReason, KeyframeRequest, Message, MessageCodec, VideoConfig,
    VideoFrame,
};
use tokio::sync::mpsc::UnboundedReceiver;

const MS: u64 = 1_000_000;
/// 120 Hz.
const FRAME_NS: u64 = 8_333_333;

const CONFIG: EncodeConfig = EncodeConfig {
    width: 1376,
    height: 1032,
    frame_rate: 120,
    bitrate: 60_000_000,
    chroma: Chroma::Yuv420,
    bit_depth: 8,
};

type Sent = Arc<Mutex<Vec<Outbound>>>;

/// Options with idle refinement off, for tests that count frames exactly (Swift: `noRefinement`).
fn no_refinement() -> PipelineOptions {
    PipelineOptions { max_refinements: 0, ..PipelineOptions::default() }
}

/// The pipeline with a fake session, and a client that acks every frame `ack_delay_ns` after it arrives.
struct Rig {
    clock: FakeClock,
    handle: FakeVideoSession,
    events: UnboundedReceiver<VideoEvent>,
    pipeline: VideoPipeline<FakeVideoSession, FakeClock>,
    sent: Sent,
    /// How many outbound messages the client has seen.
    seen: usize,
    ack_delay_ns: u64,
    pending_acks: Vec<(u64, FrameAck)>,
    /// When each received frame arrived.
    arrivals: Vec<u64>,
    ended: Option<VideoEnd>,
}

impl Rig {
    fn new(options: PipelineOptions, mode: EncodeMode, produced: Option<Chroma>) -> Self {
        let clock = FakeClock::default();
        let video = FakeVideo::new(clock.clone());
        video.set_mode(mode);
        video.set_produced_chroma(produced);
        let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
        let (session, events) = runtime.block_on(video.start(&FakeSource { display_id: 100 }, CONFIG)).unwrap();
        let handle = video.last_session().unwrap();
        let sent: Sent = Arc::default();
        let sink = Arc::clone(&sent);
        let pipeline = VideoPipeline::new(session, clock.clone(), options, move |o| sink.lock().unwrap().push(o));
        Self {
            clock,
            handle,
            events,
            pipeline,
            sent,
            seen: 0,
            ack_delay_ns: 0,
            pending_acks: Vec::new(),
            arrivals: Vec::new(),
            ended: None,
        }
    }

    fn immediate(options: PipelineOptions) -> Self {
        Self::new(options, EncodeMode::Immediate, None)
    }

    /// Delivers the session's events, and the client's acks that are due, until nothing is left to do.
    fn settle(&mut self) {
        loop {
            let mut progressed = false;
            while let Ok(event) = self.events.try_recv() {
                progressed = true;
                if let Some(end) = self.pipeline.handle_event(event) {
                    self.ended = Some(end);
                }
            }
            self.client();
            let now = self.clock.now_ns();
            let (due, later): (Vec<_>, Vec<_>) = self.pending_acks.drain(..).partition(|(t, _)| *t <= now);
            self.pending_acks = later;
            for (_, ack) in due {
                progressed = true;
                assert!(self.pipeline.handle_message(&Message::FrameAck(ack)));
            }
            if !progressed {
                break;
            }
        }
    }

    /// The client end: reads what is new, queues an ack per frame.
    fn client(&mut self) {
        let now = self.clock.now_ns();
        let sent = self.sent.lock().unwrap();
        for o in &sent[self.seen..] {
            assert_eq!(o.connection, Connection::Video);
            if let Message::VideoFrame(f) = &o.message {
                self.arrivals.push(now);
                let ack = FrameAck { frame_id: f.frame_id, received_at_ns: now, bytes: f.data.len() as u32 };
                self.pending_acks.push((now + self.ack_delay_ns, ack));
            }
        }
        self.seen = sent.len();
    }

    /// Advances the clock by `ns`, firing the pipeline's timer at each deadline on the way.
    fn advance(&mut self, ns: u64) {
        let end = self.clock.now_ns() + ns;
        loop {
            let ack_due = self.pending_acks.iter().map(|a| a.0).min();
            let next = [self.pipeline.next_deadline(), ack_due].into_iter().flatten().min();
            match next {
                Some(t) if t <= end => {
                    self.clock.set(t.max(self.clock.now_ns()));
                    self.pipeline.on_timer();
                    self.settle();
                }
                _ => break,
            }
        }
        self.clock.set(end);
        self.settle();
    }

    /// `count` captures at 120 Hz. Returns the time of the last one.
    fn feed(&mut self, count: usize) -> u64 {
        let mut last = 0;
        for _ in 0..count {
            self.handle.capture();
            last = self.clock.now_ns();
            self.settle();
            self.advance(FRAME_NS);
        }
        last
    }

    fn outbound(&self) -> Vec<Outbound> {
        self.sent.lock().unwrap().clone()
    }

    fn frames(&self) -> Vec<(VideoFrame, HeaderFlags)> {
        self.outbound()
            .into_iter()
            .filter_map(|o| match o.message {
                Message::VideoFrame(f) => Some((f, o.flags)),
                _ => None,
            })
            .collect()
    }

    fn configs(&self) -> Vec<VideoConfig> {
        self.outbound()
            .into_iter()
            .filter_map(|o| match o.message {
                Message::VideoConfig(c) => Some(c),
                _ => None,
            })
            .collect()
    }
}

/// The wire's form of a fake access unit: its slice, length-prefixed.
fn wire_data(frame_id: u32, keyframe: bool) -> Vec<u8> {
    AccessUnit::from_annexb(&fake_access_unit(frame_id, keyframe)).unwrap().data
}

#[test]
fn stream_with_config_first_keyframe_first_and_acks() {
    let mut rig = Rig::immediate(no_refinement());
    assert_eq!(rig.pipeline.chroma(), ChromaFormat::Yuv420);
    rig.feed(60);
    let mid = rig.pipeline.stats();

    // VideoConfig strictly before the first VideoFrame; the first frame is a keyframe, flagged.
    let kinds: Vec<_> = rig.outbound().iter().map(|o| o.message.ty()).collect();
    assert_eq!(kinds[0], lain_proto::MessageType::VideoConfig);
    assert_eq!(kinds.iter().filter(|k| **k == lain_proto::MessageType::VideoConfig).count(), 1);
    let config = rig.configs()[0].clone();
    assert_eq!(
        (config.config_id, config.chroma, config.bit_depth, config.width, config.height),
        (1, ChromaFormat::Yuv420, 8, 1376, 1032)
    );
    let tags = ColorTags::SRGB_FULL_RANGE;
    assert_eq!(
        (config.full_range, config.color_primaries, config.transfer_function, config.matrix),
        (tags.full_range, tags.primaries, tags.transfer, tags.matrix)
    );
    let key = AccessUnit::from_annexb(&fake_access_unit(1, true)).unwrap();
    assert_eq!(config.parameter_sets, key.parameter_sets);
    assert_eq!(rig.pipeline.current_config(), Some(&config));

    let frames = rig.frames();
    assert_eq!(frames.len(), 60, "a fast client and an instant encoder: every capture goes out");
    assert!(frames[0].0.is_keyframe && frames[0].1 == HeaderFlags::KEYFRAME);
    assert!(frames[1..].iter().all(|(f, flags)| !f.is_keyframe && flags.is_empty()), "no refinement while flowing");
    assert!(frames.iter().all(|(f, _)| f.config_id == config.config_id));
    assert!(frames.windows(2).all(|w| w[0].0.frame_id < w[1].0.frame_id));
    assert_eq!(frames[0].0.frame_id, 1);
    assert!(frames.iter().all(|(f, flags)| flags.contains(HeaderFlags::KEYFRAME) == f.is_keyframe));
    for (f, _) in &frames {
        assert_eq!(f.data, wire_data(f.frame_id, f.is_keyframe), "no parameter sets in the frame data");
    }
    let requests = rig.handle.requests();
    assert_eq!(requests.len(), 60);
    assert!(requests[0].keyframe && requests[1..].iter().all(|r| !r.keyframe && !r.refinement));

    // Every message is framable with its flags.
    for o in rig.outbound() {
        let bytes = MessageCodec::encode(&o.message, 0, 0, Some(o.flags), None);
        assert_eq!(MessageCodec::decode(&bytes).unwrap().header.flags, o.flags);
    }

    let s = rig.pipeline.stats();
    assert_eq!(s.captured, 60);
    assert!(s.peak_in_flight <= 2);
    assert_eq!(s.sent, frames.len() as u64);
    assert_eq!(s.offered, s.captured + s.refinements);
    assert!(s.encode_ms_p50.is_some() && s.ack_rtt_ms_p50.is_some());
    assert!(s.bytes_sent > 0 && mid.bytes_per_second > 0.0);
    assert_eq!(s.keyframes, 1);
    assert_eq!(s.chroma, Some(ChromaFormat::Yuv420));
    assert_eq!((s.pixel_width, s.pixel_height), (1376, 1032));
    assert_eq!(s.in_flight, 0);
}

#[test]
fn slow_client_drops_before_encode_never_after() {
    let mut rig = Rig::immediate(no_refinement());
    rig.ack_delay_ns = 40 * MS;
    rig.feed(120);
    rig.advance(200 * MS);
    let s = rig.pipeline.stats();
    assert!(s.peak_in_flight <= 2);
    assert!(s.dropped_before_encode > 40, "{s:?}");
    assert_eq!(s.offered, 120);
    assert_eq!(s.encoded + s.dropped_before_encode, s.offered, "every frame encoded or dropped in the slot");
    assert_eq!(s.sent, s.encoded - s.encode_failures);
    assert_eq!(rig.frames().len() as u64, s.sent, "nothing dropped after encoding");
    assert_eq!(s.in_flight, 0);
    assert!(s.ack_rtt_ms_p50.unwrap() >= 40.0);
    // Latency doesn't creep up: the gate never queues more than the window.
    let frames = rig.frames();
    let lag: Vec<u64> = frames.iter().zip(&rig.arrivals).map(|((f, _), at)| at - f.capture_time_ns).collect();
    assert!(lag.iter().all(|&l| l <= 2 * FRAME_NS), "{lag:?}");
}

#[test]
fn idle_refinement_sends_at_most_two_after_150ms() {
    let mut rig = Rig::immediate(PipelineOptions::default());
    let last_feed = rig.feed(40);
    assert_eq!(rig.pipeline.next_deadline(), Some(last_feed + 150 * MS));
    rig.advance(700 * MS);

    let frames = rig.frames();
    let refinements: Vec<_> = frames.iter().filter(|(_, flags)| flags.contains(HeaderFlags::REFINEMENT)).collect();
    assert_eq!(refinements.len(), 2, "the idle tail got both");
    assert!(refinements.iter().all(|(f, _)| !f.is_keyframe));
    assert_eq!(refinements[0].0.capture_time_ns, last_feed + 150 * MS);
    assert_eq!(refinements[1].0.capture_time_ns, last_feed + 300 * MS);
    assert!(frames[..frames.len() - 2].iter().all(|(_, flags)| !flags.contains(HeaderFlags::REFINEMENT)));
    assert_eq!(rig.pipeline.stats().refinements, 2);
    let requests = rig.handle.requests();
    assert_eq!(requests.iter().filter(|r| r.refinement).count(), 2);
    assert_eq!(rig.pipeline.next_deadline(), None, "done until the next capture");

    // Motion resets it.
    let t = rig.feed(1);
    assert_eq!(rig.pipeline.next_deadline(), Some(t + 150 * MS));
}

#[test]
fn keyframe_request_yields_a_keyframe_even_when_idle() {
    let mut rig = Rig::immediate(no_refinement());
    rig.feed(20);
    let before = rig.frames().len();
    assert_eq!(rig.frames().iter().filter(|(f, _)| f.is_keyframe).count(), 1);

    // Desktop idle (no captures): the request alone must produce a keyframe.
    rig.pipeline.keyframe_request(&KeyframeRequest { reason: KeyframeReason::DecodeError, last_good_frame_id: 3 });
    rig.settle();
    let after = rig.frames();
    assert_eq!(after.len(), before + 1);
    let (last, flags) = after.last().unwrap();
    assert!(last.is_keyframe && flags.contains(HeaderFlags::KEYFRAME));
    assert_eq!(last.capture_time_ns, rig.clock.now_ns(), "a re-offer carries the time of the re-offer, as in Swift");

    // While flowing, the next encoded frame is a keyframe (resumed also restarts the ack window).
    assert!(rig.pipeline.handle_message(&Message::KeyframeRequest(KeyframeRequest {
        reason: KeyframeReason::Resumed,
        last_good_frame_id: 0
    })));
    rig.feed(10);
    assert_eq!(rig.frames().iter().filter(|(f, _)| f.is_keyframe).count(), 3);
    assert_eq!(rig.pipeline.stats().keyframes, 3);
}

#[test]
fn keyframe_request_before_any_capture_waits_for_one() {
    let mut rig = Rig::immediate(no_refinement());
    rig.pipeline.request_keyframe(KeyframeReason::Startup);
    rig.settle();
    assert!(rig.handle.requests().is_empty(), "nothing to encode yet");
    rig.feed(1);
    assert!(rig.handle.requests()[0].keyframe);
}

#[test]
fn startup_request_restarts_the_ack_window() {
    let mut rig = Rig::immediate(no_refinement());
    rig.ack_delay_ns = u64::MAX / 2; // a client that never acks
    rig.feed(5);
    let s = rig.pipeline.stats();
    assert_eq!((s.sent, s.in_flight), (2, 2));
    assert!(rig.handle.requests().len() == 2, "the window is full; the newest capture waits in the slot");
    rig.pipeline.request_keyframe(KeyframeReason::Startup);
    rig.settle();
    let frames = rig.frames();
    assert_eq!(frames.len(), 3);
    assert!(frames[2].0.is_keyframe, "the waiting capture goes out as the keyframe");
    assert_eq!(rig.pipeline.stats().in_flight, 1);
}

#[test]
fn the_config_follows_what_the_encoder_produces() {
    // Swift: `fourTwoZeroWhenClientLacksHardware444`. On Linux the host always asks for 4:2:0 (L3); the
    // config says what the encoder actually produces.
    let display = StreamedDisplay { id: 100, pixel_width: 2752, pixel_height: 2064, refresh_hz: 120 };
    let options = PipelineOptions::default();
    let asked = encode_config(&display, 120, &options);
    assert_eq!(
        asked,
        EncodeConfig {
            width: 2752,
            height: 2064,
            frame_rate: 120,
            bitrate: 60_000_000,
            chroma: Chroma::Yuv420,
            bit_depth: 8
        }
    );
    assert_eq!(encode_config(&display, 60, &options).frame_rate, 60, "capped by the client");
    assert_eq!(encode_config(&display, 0, &options).frame_rate, 120, "0: the client didn't say");
    assert_eq!(encode_config(&display, 240, &options).frame_rate, 120);

    let mut rig = Rig::new(no_refinement(), EncodeMode::Immediate, Some(Chroma::Yuv444));
    assert_eq!(rig.pipeline.chroma(), ChromaFormat::Yuv444);
    rig.feed(3);
    assert_eq!(rig.configs()[0].chroma, ChromaFormat::Yuv444);
    assert_eq!(rig.pipeline.stats().chroma, Some(ChromaFormat::Yuv444));
}

#[test]
fn stop_is_idempotent_and_silences_everything() {
    let mut rig = Rig::immediate(PipelineOptions::default());
    rig.feed(10);
    assert!(!rig.frames().is_empty());
    let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
    runtime.block_on(rig.pipeline.stop());
    runtime.block_on(rig.pipeline.stop());
    assert!(!rig.pipeline.is_running());
    assert!(rig.handle.is_stopped());

    let messages = rig.outbound().len();
    let requests = rig.handle.requests().len();
    // Late captures, keyframe requests, acks and the idle timer do nothing now.
    for capture in 100..105 {
        assert_eq!(rig.pipeline.handle_event(VideoEvent::Captured { capture, capture_ns: rig.clock.now_ns() }), None);
    }
    rig.pipeline.request_keyframe(KeyframeReason::DecodeError);
    rig.pipeline.frame_ack(&FrameAck { frame_id: 1, received_at_ns: 0, bytes: 0 });
    assert_eq!(rig.pipeline.next_deadline(), None);
    rig.clock.advance(400 * MS);
    rig.pipeline.on_timer();
    assert_eq!(rig.outbound().len(), messages);
    assert_eq!(rig.handle.requests().len(), requests);
}

#[test]
fn capture_failure_and_owner_stop_end_video() {
    let mut rig = Rig::immediate(no_refinement());
    rig.feed(2);
    rig.handle.fail(PlatformError::Failed("compositor went away".into()));
    rig.settle();
    assert_eq!(rig.ended, Some(VideoEnd::Failed(PlatformError::Failed("compositor went away".into()))));
    assert!(!rig.pipeline.is_running());
    let messages = rig.outbound().len();
    assert_eq!(rig.pipeline.handle_event(VideoEvent::Captured { capture: 9, capture_ns: 0 }), None);
    assert_eq!(rig.pipeline.handle_event(VideoEvent::StoppedByUser), None, "nothing after the end");
    assert_eq!(rig.outbound().len(), messages);

    let mut rig = Rig::immediate(no_refinement());
    rig.feed(1);
    rig.handle.stop_by_user();
    rig.settle();
    assert_eq!(rig.ended, Some(VideoEnd::StoppedByUser));
    assert_eq!(rig.pipeline.next_deadline(), None);
}

#[test]
fn encode_failed_frees_the_gate_and_the_next_request_is_a_keyframe() {
    let mut rig = Rig::new(no_refinement(), EncodeMode::Manual, None);
    rig.handle.capture();
    rig.settle();
    assert!(rig.handle.complete(1));
    rig.settle();
    rig.handle.capture();
    rig.settle();
    rig.handle.capture(); // waits in the slot
    rig.settle();
    assert_eq!(rig.handle.requests().len(), 2);
    assert!(!rig.handle.requests()[1].keyframe);
    assert!(rig.handle.fail_encode(2));
    rig.settle();
    let requests = rig.handle.requests();
    assert_eq!(requests.len(), 3, "the slot's capture goes in at once");
    assert!(requests[2].keyframe, "the encoder's reference chain may be broken");
    assert!(rig.handle.complete(3));
    rig.settle();
    let frames = rig.frames();
    assert_eq!(frames.iter().map(|(f, _)| (f.frame_id, f.is_keyframe)).collect::<Vec<_>>(), [(1, true), (3, true)]);
    assert_eq!(rig.configs().len(), 1, "the same parameter sets: no new config");
    let s = rig.pipeline.stats();
    assert_eq!((s.encode_failures, s.sent, s.encoded), (1, 2, 3));
}

#[test]
fn a_result_for_a_newer_capture_is_no_refinement_and_isnt_encoded_twice() {
    let mut rig = Rig::new(PipelineOptions::default(), EncodeMode::Manual, None);
    rig.handle.capture();
    rig.settle();
    assert!(rig.handle.complete(1));
    rig.settle();
    rig.advance(150 * MS);
    let requests = rig.handle.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests[1].refinement);

    // A capture lands between the request and the encode: the session encodes it (its newest), and its
    // `Captured` event put it in the slot meanwhile.
    rig.clock.advance(MS);
    let capture = rig.handle.capture();
    let capture_ns = rig.clock.now_ns();
    rig.settle();
    rig.clock.advance(MS);
    let encoded = EncodedFrame {
        frame_id: 2,
        capture,
        capture_ns,
        submit_ns: capture_ns,
        encode_done_ns: rig.clock.now_ns(),
        keyframe: false,
        annexb: fake_access_unit(2, false),
    };
    assert_eq!(rig.pipeline.handle_event(VideoEvent::Encoded(encoded)), None);
    rig.settle();
    let (frame, flags) = rig.frames().last().cloned().unwrap();
    assert_eq!(frame.frame_id, 2);
    assert!(!flags.contains(HeaderFlags::REFINEMENT), "it shows capture 2, not a refinement of capture 1");
    assert_eq!(frame.capture_time_ns, capture_ns);
    assert_eq!(rig.handle.requests().len(), 2, "capture 2 was shown: not encoded again");
    let s = rig.pipeline.stats();
    assert_eq!((s.refinements, s.dropped_before_encode), (0, 1));
    assert_eq!((s.offered, s.encoded), (3, 2), "capture 1, its refinement, capture 2");
}

/// A session that answers nothing itself: the test feeds the pipeline results directly.
#[derive(Clone)]
struct ScriptedSession {
    info: StreamInfo,
    requests: Arc<Mutex<Vec<EncodeRequest>>>,
}

impl ScriptedSession {
    fn new(width: u32, height: u32) -> Self {
        Self {
            info: StreamInfo { width, height, chroma: Chroma::Yuv420, bit_depth: 8, color: ColorTags::SRGB_FULL_RANGE },
            requests: Arc::default(),
        }
    }
    fn requests(&self) -> Vec<EncodeRequest> {
        self.requests.lock().unwrap().clone()
    }
}

impl VideoSession for ScriptedSession {
    fn info(&self) -> StreamInfo {
        self.info
    }
    fn encode(&self, request: EncodeRequest) {
        self.requests.lock().unwrap().push(request);
    }
    async fn stop(&self) {}
}

struct Scripted {
    clock: FakeClock,
    session: ScriptedSession,
    pipeline: VideoPipeline<ScriptedSession, FakeClock>,
    sent: Sent,
    captures: u64,
}

impl Scripted {
    fn new(width: u32, height: u32) -> Self {
        let clock = FakeClock::default();
        let session = ScriptedSession::new(width, height);
        let sent: Sent = Arc::default();
        let sink = Arc::clone(&sent);
        let pipeline =
            VideoPipeline::new(session.clone(), clock.clone(), no_refinement(), move |o| sink.lock().unwrap().push(o));
        Self { clock, session, pipeline, sent, captures: 0 }
    }

    /// A capture, and the encoder's answer to the request it causes, acked at once.
    fn step(&mut self, annexb: Vec<u8>) -> EncodeRequest {
        self.captures += 1;
        let now = self.clock.now_ns();
        self.pipeline.handle_event(VideoEvent::Captured { capture: self.captures, capture_ns: now });
        let request = *self.session.requests().last().expect("a request");
        self.clock.advance(MS);
        self.pipeline.handle_event(VideoEvent::Encoded(EncodedFrame {
            frame_id: request.frame_id,
            capture: self.captures,
            capture_ns: now,
            submit_ns: now,
            encode_done_ns: self.clock.now_ns(),
            keyframe: request.keyframe,
            annexb,
        }));
        self.pipeline.frame_ack(&FrameAck { frame_id: request.frame_id, received_at_ns: 0, bytes: 0 });
        self.clock.advance(FRAME_NS);
        request
    }

    fn messages(&self) -> Vec<Outbound> {
        std::mem::take(&mut *self.sent.lock().unwrap())
    }
}

fn fixture(dir: &str, n: usize) -> Vec<u8> {
    std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("tests/fixtures/hevc/{dir}/au-{n:02}.h265")))
        .unwrap()
}

#[test]
fn real_streams_one_config_per_parameter_set_change() {
    let mut s = Scripted::new(256, 144);
    for n in 0..8 {
        let request = s.step(fixture("256x144-stuffing", n));
        assert_eq!(request.keyframe, n == 0, "only the first request asks for a keyframe");
    }
    let out = s.messages();
    let configs: Vec<_> =
        out.iter().filter_map(|o| if let Message::VideoConfig(c) = &o.message { Some(c) } else { None }).collect();
    assert_eq!(configs.len(), 1, "the IDR at 5 repeats the same parameter sets");
    assert_eq!(configs[0].parameter_sets, hevc::parameter_sets(&fixture("256x144", 0)).unwrap());
    assert!(matches!(out[0].message, Message::VideoConfig(_)));
    let frames: Vec<_> = out
        .iter()
        .filter_map(|o| if let Message::VideoFrame(f) = &o.message { Some((f.clone(), o.flags)) } else { None })
        .collect();
    assert_eq!(frames.len(), 8);
    for (n, (f, flags)) in frames.iter().enumerate() {
        assert_eq!(f.is_keyframe, n == 0 || n == 5, "frame {n}");
        assert_eq!(flags.contains(HeaderFlags::KEYFRAME), f.is_keyframe);
        assert_eq!(f.config_id, 1);
        let units = hevc::split_length_prefixed(&f.data).unwrap();
        assert_eq!(units.len(), 1, "frame {n}: only its slice, no filler or parameter sets");
        assert!(hevc::nal::is_vcl(hevc::nal_type(units[0][0])));
    }

    // The encoder is rebuilt with other parameter sets (here: another size's stream): a new config id.
    for n in 0..3 {
        s.step(fixture("192x128", n));
    }
    let out = s.messages();
    let Message::VideoConfig(second) = &out[0].message else { panic!("config first: {:?}", out[0].message.ty()) };
    assert_eq!(second.config_id, 2);
    assert_eq!(second.parameter_sets, hevc::parameter_sets(&fixture("192x128", 0)).unwrap());
    assert!(out[1..].iter().all(|o| matches!(&o.message, Message::VideoFrame(f) if f.config_id == 2)));
}

#[test]
fn unusable_results_count_as_failures_and_ask_for_a_keyframe() {
    let mut s = Scripted::new(256, 144);
    // A P-frame before any parameter sets: the client couldn't decode it.
    let first = s.step(fixture("256x144", 1));
    assert!(first.keyframe);
    assert!(s.messages().is_empty());
    // Not Annex-B.
    let second = s.step(vec![1, 2, 3, 4]);
    assert!(second.keyframe, "asked again");
    assert!(s.messages().is_empty());
    // A keyframe missing its VPS.
    let mut no_vps = fixture("256x144", 0);
    no_vps.drain(..4 + 23);
    let third = s.step(no_vps);
    assert!(third.keyframe);
    assert!(s.messages().is_empty());
    assert_eq!(s.pipeline.stats().encode_failures, 3);

    let fourth = s.step(fixture("256x144", 0));
    assert!(fourth.keyframe);
    assert_eq!(s.messages().len(), 2, "config and keyframe");
    // Asked for a keyframe, got a P-frame: sent as what it is, and the keyframe is asked for again.
    s.pipeline.request_keyframe(KeyframeReason::DecodeError);
    let requests = s.session.requests();
    let re_offer = requests.last().unwrap();
    assert!(re_offer.keyframe);
    s.pipeline.handle_event(VideoEvent::Encoded(EncodedFrame {
        frame_id: re_offer.frame_id,
        capture: s.captures,
        capture_ns: 0,
        submit_ns: 0,
        encode_done_ns: 0,
        keyframe: true,
        annexb: fixture("256x144", 2),
    }));
    let out = s.messages();
    assert!(matches!(&out[0].message, Message::VideoFrame(f) if !f.is_keyframe));
    assert!(out[0].flags.is_empty());
    s.pipeline.frame_ack(&FrameAck { frame_id: re_offer.frame_id, received_at_ns: 0, bytes: 0 });
    let next = s.step(fixture("256x144", 5));
    assert!(next.keyframe);
}

#[test]
fn a_result_for_no_outstanding_request_is_ignored() {
    let mut s = Scripted::new(256, 144);
    s.step(fixture("256x144", 0));
    s.messages();
    s.pipeline.handle_event(VideoEvent::Encoded(EncodedFrame {
        frame_id: 77,
        capture: 1,
        capture_ns: 0,
        submit_ns: 0,
        encode_done_ns: 0,
        keyframe: false,
        annexb: fixture("256x144", 1),
    }));
    s.pipeline.handle_event(VideoEvent::EncodeFailed { frame_id: 78 });
    assert!(s.messages().is_empty());
    let s2 = s.pipeline.stats();
    assert_eq!((s2.sent, s2.encode_failures), (1, 0));
}

#[test]
fn messages_other_than_ack_and_keyframe_request_are_not_the_pipelines() {
    let mut s = Scripted::new(256, 144);
    assert!(!s.pipeline.handle_message(&Message::Ping(lain_proto::Ping { id: 1, sent_at_ns: 0 })));
}
