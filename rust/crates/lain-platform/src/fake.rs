//! Recording fakes of every contract, for tests (feature `fake`; Swift: `Tests/LainHostCoreTests/TestDoubles`).
//!
//! Each fake is a cheap handle around shared state: clone it, give one clone to the code under test, and
//! drive or inspect it through the other. [`FakePlatform`] bundles one of each behind [`Platform`].

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use tokio::sync::{mpsc, watch};

use crate::{
    AUDIO_QUEUE_CHUNKS, Advertiser, AudioBackend, AudioChunk, AudioFormat, Chroma, Clock, ColorTags, CursorImage,
    CursorSource, DisplayBackend, DisplaySpec, EncodeConfig, EncodeRequest, EncodedFrame, InputAction, InputBackend,
    InputSettings, Monitor, Platform, PlatformError, PointF, PowerBackend, RectF, Result, SecretStore, ServiceAd,
    SettingsSource, SetupReport, SetupSource, StreamInfo, StreamedDisplay, VideoBackend, VideoEvent, VideoSession,
};

/// A poisoned fake is still inspectable: a failed assertion elsewhere shouldn't hide the state.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

// MARK: Clock

/// A clock that moves only when told to.
#[derive(Debug, Clone)]
pub struct FakeClock(Arc<AtomicU64>);

impl FakeClock {
    pub fn new(start_ns: u64) -> Self {
        Self(Arc::new(AtomicU64::new(start_ns)))
    }

    pub fn set(&self, ns: u64) {
        self.0.store(ns, Ordering::SeqCst);
    }

    pub fn advance(&self, ns: u64) {
        self.0.fetch_add(ns, Ordering::SeqCst);
    }
}

impl Default for FakeClock {
    /// Starts at one second, so "time zero" never reads as "unset".
    fn default() -> Self {
        Self::new(1_000_000_000)
    }
}

impl Clock for FakeClock {
    fn now_ns(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

// MARK: Display

/// What a [`FakeDisplay`] hands the video backend: the display to capture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FakeSource {
    pub display_id: u32,
}

#[derive(Debug)]
struct DisplayState {
    physical: Vec<Monitor>,
    created: Option<(StreamedDisplay, Monitor)>,
    /// The spec the live display was made for.
    spec: Option<DisplaySpec>,
    next_id: u32,
    fail_next_create: Option<PlatformError>,
    creates: usize,
    destroys: usize,
    cursor: Option<PointF>,
}

#[derive(Debug)]
struct DisplayShared {
    state: Mutex<DisplayState>,
    monitors: watch::Sender<Vec<Monitor>>,
}

/// A desktop with one 1920×1080 primary monitor at the origin until told otherwise. `create` puts lain's
/// display to the right of the physical monitors, top-aligned, at the spec's logical size.
#[derive(Debug, Clone)]
pub struct FakeDisplay(Arc<DisplayShared>);

/// The default physical monitor's id; lain's displays get ids from 100 on.
pub const FAKE_PRIMARY_ID: u32 = 1;

impl FakeDisplay {
    pub fn new() -> Self {
        let physical = vec![Monitor {
            id: FAKE_PRIMARY_ID,
            bounds: RectF::new(0.0, 0.0, 1920.0, 1080.0),
            primary: true,
            lain: false,
        }];
        let (monitors, _) = watch::channel(physical.clone());
        Self(Arc::new(DisplayShared {
            state: Mutex::new(DisplayState {
                physical,
                created: None,
                spec: None,
                next_id: 100,
                fail_next_create: None,
                creates: 0,
                destroys: 0,
                cursor: None,
            }),
            monitors,
        }))
    }

    fn publish(&self, state: &DisplayState) {
        let mut all = state.physical.clone();
        if let Some((_, monitor)) = &state.created {
            all.push(monitor.clone());
        }
        self.0.monitors.send_replace(all);
    }

    /// Replaces the physical monitors (hotplug, rearrangement).
    pub fn set_physical(&self, monitors: Vec<Monitor>) {
        let mut s = lock(&self.0.state);
        s.physical = monitors;
        self.publish(&s);
    }

    /// Moves lain's display, as the owner might in the display settings.
    pub fn move_lain(&self, origin: PointF) {
        let mut s = lock(&self.0.state);
        if let Some((_, monitor)) = s.created.as_mut() {
            monitor.bounds.x = origin.x;
            monitor.bounds.y = origin.y;
        }
        self.publish(&s);
    }

    pub fn set_cursor(&self, location: Option<PointF>) {
        lock(&self.0.state).cursor = location;
    }

    /// The next `create` fails with `error`.
    pub fn fail_next_create(&self, error: PlatformError) {
        lock(&self.0.state).fail_next_create = Some(error);
    }

    /// lain's display, while it exists.
    pub fn created(&self) -> Option<StreamedDisplay> {
        lock(&self.0.state).created.as_ref().map(|(display, _)| *display)
    }

    pub fn create_count(&self) -> usize {
        lock(&self.0.state).creates
    }

    pub fn destroy_count(&self) -> usize {
        lock(&self.0.state).destroys
    }
}

impl Default for FakeDisplay {
    fn default() -> Self {
        Self::new()
    }
}

impl DisplayBackend for FakeDisplay {
    type Source = FakeSource;

    async fn create(&self, spec: DisplaySpec) -> Result<(StreamedDisplay, FakeSource)> {
        let mut s = lock(&self.0.state);
        s.creates += 1;
        if let Some(error) = s.fail_next_create.take() {
            return Err(error);
        }
        if s.created.is_some() {
            return Err(PlatformError::Failed("a display already exists".into()));
        }
        let id = s.next_id;
        s.next_id += 1;
        let x = s.physical.iter().map(|m| m.bounds.max_x()).fold(0.0, f64::max);
        let (width, height) = spec.logical_size();
        let display = StreamedDisplay {
            id,
            pixel_width: spec.pixel_width,
            pixel_height: spec.pixel_height,
            refresh_hz: spec.refresh_hz,
        };
        let monitor = Monitor { id, bounds: RectF::new(x, 0.0, width, height), primary: false, lain: true };
        s.created = Some((display, monitor));
        s.spec = Some(spec);
        self.publish(&s);
        Ok((display, FakeSource { display_id: id }))
    }

    async fn destroy(&self) {
        let mut s = lock(&self.0.state);
        if s.created.take().is_some() {
            s.spec = None;
            s.destroys += 1;
            self.publish(&s);
        }
    }

    fn monitors(&self) -> watch::Receiver<Vec<Monitor>> {
        self.0.monitors.subscribe()
    }

    fn cursor_location(&self) -> Option<PointF> {
        lock(&self.0.state).cursor
    }

    /// The live display's scale: the client's choice, else the spec's own.
    fn applied_scale(&self) -> Option<f64> {
        lock(&self.0.state)
            .spec
            .map(|s| if s.desired_scale > 0 { f64::from(s.desired_scale) / 100.0 } else { f64::from(s.scale.max(1)) })
    }
}

// MARK: Video

/// A minimal Annex-B access unit for framing tests (not decodable): VPS, SPS, PPS and an IDR slice for a
/// keyframe, one trailing slice otherwise. Payload bytes are never zero, so no start code can appear
/// inside a NAL unit.
pub fn fake_access_unit(frame_id: u32, keyframe: bool) -> Vec<u8> {
    const START: [u8; 4] = [0, 0, 0, 1];
    // NAL header: forbidden bit 0, nal_unit_type, nuh_layer_id 0, nuh_temporal_id_plus1 1.
    fn nal(out: &mut Vec<u8>, nal_type: u8, payload: &[u8]) {
        out.extend_from_slice(&START);
        out.extend_from_slice(&[nal_type << 1, 0x01]);
        out.extend_from_slice(payload);
    }
    let id =
        [0x80 | (frame_id & 0x7F) as u8, 0x80 | ((frame_id >> 7) & 0x7F) as u8, 0x80 | ((frame_id >> 14) & 0x7F) as u8];
    let mut out = Vec::new();
    if keyframe {
        nal(&mut out, FAKE_NAL_VPS, FAKE_VPS_PAYLOAD);
        nal(&mut out, FAKE_NAL_SPS, FAKE_SPS_PAYLOAD);
        nal(&mut out, FAKE_NAL_PPS, FAKE_PPS_PAYLOAD);
        nal(&mut out, FAKE_NAL_IDR_W_RADL, &id);
    } else {
        nal(&mut out, FAKE_NAL_TRAIL_R, &id);
    }
    out
}

pub const FAKE_NAL_TRAIL_R: u8 = 1;
pub const FAKE_NAL_IDR_W_RADL: u8 = 19;
pub const FAKE_NAL_VPS: u8 = 32;
pub const FAKE_NAL_SPS: u8 = 33;
pub const FAKE_NAL_PPS: u8 = 34;
pub const FAKE_VPS_PAYLOAD: &[u8] = &[0x0C, 0x01, 0xFF, 0xFF];
pub const FAKE_SPS_PAYLOAD: &[u8] = &[0x01, 0x01, 0x60, 0xA0];
pub const FAKE_PPS_PAYLOAD: &[u8] = &[0xC1, 0x72, 0xB4];

/// How a [`FakeVideoSession`] answers `encode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EncodeMode {
    /// At once: `Encoded` for the newest capture, or `EncodeFailed` before the first one.
    #[default]
    Immediate,
    /// Only when the test calls [`FakeVideoSession::complete`] or [`FakeVideoSession::fail_encode`].
    Manual,
}

/// A capture: its number and time.
type Capture = (u64, u64);

/// Manual mode: a request not answered yet, with the capture it will encode.
#[derive(Debug)]
struct Pending {
    request: EncodeRequest,
    capture: Option<Capture>,
    submit_ns: u64,
}

#[derive(Debug)]
struct SessionState {
    events: Option<mpsc::UnboundedSender<VideoEvent>>,
    captures: u64,
    newest: Option<Capture>,
    requests: Vec<EncodeRequest>,
    pending: Vec<Pending>,
    stopped: bool,
}

#[derive(Debug)]
struct SessionShared {
    config: EncodeConfig,
    info: StreamInfo,
    source: FakeSource,
    mode: EncodeMode,
    clock: FakeClock,
    state: Mutex<SessionState>,
}

/// One fake capture-and-encode session; the test's handle and the code's session are clones.
#[derive(Debug, Clone)]
pub struct FakeVideoSession(Arc<SessionShared>);

impl FakeVideoSession {
    pub fn config(&self) -> EncodeConfig {
        self.0.config
    }

    pub fn source(&self) -> FakeSource {
        self.0.source
    }

    fn emit(&self, s: &mut SessionState, event: VideoEvent) {
        if let Some(events) = &s.events {
            let _ = events.send(event);
        }
    }

    fn encoded(&self, request: EncodeRequest, capture: Capture, submit_ns: u64) -> VideoEvent {
        VideoEvent::Encoded(EncodedFrame {
            frame_id: request.frame_id,
            capture: capture.0,
            capture_ns: capture.1,
            submit_ns,
            encode_done_ns: self.0.clock.now_ns(),
            keyframe: request.keyframe,
            annexb: fake_access_unit(request.frame_id, request.keyframe),
        })
    }

    /// The display changed: emits `Captured` with the next capture number (from 1), stamped now.
    pub fn capture(&self) -> u64 {
        let mut s = lock(&self.0.state);
        s.captures += 1;
        let capture = (s.captures, self.0.clock.now_ns());
        s.newest = Some(capture);
        self.emit(&mut s, VideoEvent::Captured { capture: capture.0, capture_ns: capture.1 });
        capture.0
    }

    /// Every request so far, in order.
    pub fn requests(&self) -> Vec<EncodeRequest> {
        lock(&self.0.state).requests.clone()
    }

    /// Manual mode: answers the pending request for `frame_id` with the capture that was newest when it
    /// was made (`EncodeFailed` if there was none). Returns whether such a request was pending.
    pub fn complete(&self, frame_id: u32) -> bool {
        let mut s = lock(&self.0.state);
        let Some(i) = s.pending.iter().position(|p| p.request.frame_id == frame_id) else { return false };
        let pending = s.pending.remove(i);
        let event = match pending.capture {
            Some(capture) => self.encoded(pending.request, capture, pending.submit_ns),
            None => VideoEvent::EncodeFailed { frame_id },
        };
        self.emit(&mut s, event);
        true
    }

    /// Manual mode: the encoder drops the pending request for `frame_id`.
    pub fn fail_encode(&self, frame_id: u32) -> bool {
        let mut s = lock(&self.0.state);
        let Some(i) = s.pending.iter().position(|p| p.request.frame_id == frame_id) else { return false };
        s.pending.remove(i);
        self.emit(&mut s, VideoEvent::EncodeFailed { frame_id });
        true
    }

    /// Capture stops on its own: emits `Failed` and closes the event stream.
    pub fn fail(&self, error: PlatformError) {
        let mut s = lock(&self.0.state);
        self.emit(&mut s, VideoEvent::Failed(error));
        s.events = None;
    }

    /// The owner stops the capture: emits `StoppedByUser` and closes the event stream.
    pub fn stop_by_user(&self) {
        let mut s = lock(&self.0.state);
        self.emit(&mut s, VideoEvent::StoppedByUser);
        s.events = None;
    }

    pub fn is_stopped(&self) -> bool {
        lock(&self.0.state).stopped
    }
}

impl VideoSession for FakeVideoSession {
    fn info(&self) -> StreamInfo {
        self.0.info
    }

    fn encode(&self, request: EncodeRequest) {
        let mut s = lock(&self.0.state);
        if s.stopped {
            return;
        }
        s.requests.push(request);
        let submit_ns = self.0.clock.now_ns();
        let newest = s.newest;
        match self.0.mode {
            EncodeMode::Immediate => {
                let event = match newest {
                    Some(capture) => self.encoded(request, capture, submit_ns),
                    None => VideoEvent::EncodeFailed { frame_id: request.frame_id },
                };
                self.emit(&mut s, event);
            }
            EncodeMode::Manual => s.pending.push(Pending { request, capture: newest, submit_ns }),
        }
    }

    async fn stop(&self) {
        let mut s = lock(&self.0.state);
        s.stopped = true;
        s.events = None;
        s.pending.clear();
    }
}

#[derive(Debug)]
struct VideoState {
    sessions: Vec<FakeVideoSession>,
    fail_next_start: Option<PlatformError>,
    mode: EncodeMode,
    produced_chroma: Option<Chroma>,
}

/// Starts [`FakeVideoSession`]s. Tests reach a session through [`sessions`](Self::sessions) or
/// [`last_session`](Self::last_session).
#[derive(Debug, Clone)]
pub struct FakeVideo {
    clock: FakeClock,
    state: Arc<Mutex<VideoState>>,
}

impl FakeVideo {
    pub fn new(clock: FakeClock) -> Self {
        Self {
            clock,
            state: Arc::new(Mutex::new(VideoState {
                sessions: Vec::new(),
                fail_next_start: None,
                mode: EncodeMode::Immediate,
                produced_chroma: None,
            })),
        }
    }

    /// How sessions started from now on answer `encode`.
    pub fn set_mode(&self, mode: EncodeMode) {
        lock(&self.state).mode = mode;
    }

    /// Sessions started from now on produce `chroma` whatever was asked (an encoder's fallback).
    pub fn set_produced_chroma(&self, chroma: Option<Chroma>) {
        lock(&self.state).produced_chroma = chroma;
    }

    pub fn fail_next_start(&self, error: PlatformError) {
        lock(&self.state).fail_next_start = Some(error);
    }

    pub fn sessions(&self) -> Vec<FakeVideoSession> {
        lock(&self.state).sessions.clone()
    }

    pub fn last_session(&self) -> Option<FakeVideoSession> {
        lock(&self.state).sessions.last().cloned()
    }
}

impl Default for FakeVideo {
    fn default() -> Self {
        Self::new(FakeClock::default())
    }
}

impl VideoBackend for FakeVideo {
    type Source = FakeSource;
    type Session = FakeVideoSession;

    async fn start(
        &self,
        source: &FakeSource,
        config: EncodeConfig,
    ) -> Result<(FakeVideoSession, mpsc::UnboundedReceiver<VideoEvent>)> {
        let mut v = lock(&self.state);
        if let Some(error) = v.fail_next_start.take() {
            return Err(error);
        }
        let (events, receiver) = mpsc::unbounded_channel();
        let info = StreamInfo {
            width: config.width,
            height: config.height,
            chroma: v.produced_chroma.unwrap_or(config.chroma),
            bit_depth: config.bit_depth,
            color: ColorTags::SRGB_FULL_RANGE,
        };
        let session = FakeVideoSession(Arc::new(SessionShared {
            config,
            info,
            source: *source,
            mode: v.mode,
            clock: self.clock.clone(),
            state: Mutex::new(SessionState {
                events: Some(events),
                captures: 0,
                newest: None,
                requests: Vec::new(),
                pending: Vec::new(),
                stopped: false,
            }),
        }));
        v.sessions.push(session.clone());
        Ok((session, receiver))
    }
}

// MARK: Cursor

/// A cursor the test sets.
#[derive(Debug, Clone, Default)]
pub struct FakeCursor(Arc<Mutex<Option<Arc<CursorImage>>>>);

impl FakeCursor {
    /// `None` hides the cursor.
    pub fn set(&self, image: Option<CursorImage>) {
        *lock(&self.0) = image.map(Arc::new);
    }
}

impl CursorSource for FakeCursor {
    fn current(&self) -> Option<Arc<CursorImage>> {
        lock(&self.0).clone()
    }
}

// MARK: Input

/// Records every action applied.
#[derive(Debug, Clone, Default)]
pub struct FakeInput(Arc<Mutex<Vec<InputAction>>>);

impl FakeInput {
    pub fn actions(&self) -> Vec<InputAction> {
        lock(&self.0).clone()
    }

    /// The actions so far, clearing the record.
    pub fn take(&self) -> Vec<InputAction> {
        std::mem::take(&mut *lock(&self.0))
    }
}

impl InputBackend for FakeInput {
    fn apply(&self, actions: &[InputAction]) {
        lock(&self.0).extend_from_slice(actions);
    }
}

// MARK: Power

#[derive(Debug, Default)]
struct PowerState {
    awake: bool,
    transitions: Vec<bool>,
    activity: u64,
}

/// Records awake transitions and user-activity calls.
#[derive(Debug, Clone, Default)]
pub struct FakePower(Arc<Mutex<PowerState>>);

impl FakePower {
    pub fn is_awake(&self) -> bool {
        lock(&self.0).awake
    }

    /// Every `set_awake` call, in order.
    pub fn transitions(&self) -> Vec<bool> {
        lock(&self.0).transitions.clone()
    }

    pub fn activity_count(&self) -> u64 {
        lock(&self.0).activity
    }
}

impl PowerBackend for FakePower {
    fn set_awake(&self, awake: bool) {
        let mut s = lock(&self.0);
        s.awake = awake;
        s.transitions.push(awake);
    }

    fn user_activity(&self) {
        lock(&self.0).activity += 1;
    }
}

// MARK: Settings and setup

/// GNOME's defaults until set: 400 ms double-click, 500 ms repeat delay, 30 ms repeat interval, US layout.
#[derive(Debug, Clone)]
pub struct FakeSettings(Arc<Mutex<InputSettings>>);

impl FakeSettings {
    pub fn set(&self, settings: InputSettings) {
        *lock(&self.0) = settings;
    }
}

impl Default for FakeSettings {
    fn default() -> Self {
        Self(Arc::new(Mutex::new(InputSettings {
            double_click_ms: 400,
            key_repeat_delay_ms: 500,
            key_repeat_interval_ms: 30,
            input_source: "xkb:us".into(),
        })))
    }
}

impl SettingsSource for FakeSettings {
    fn input_settings(&self) -> InputSettings {
        lock(&self.0).clone()
    }
}

/// A setup the test sets; empty (no items, no other display) until then.
#[derive(Debug, Clone, Default)]
pub struct FakeSetup(Arc<Mutex<SetupReport>>);

impl FakeSetup {
    pub fn set(&self, report: SetupReport) {
        *lock(&self.0) = report;
    }
}

impl SetupSource for FakeSetup {
    fn setup(&self) -> SetupReport {
        lock(&self.0).clone()
    }
}

// MARK: Secrets

#[derive(Debug, Default)]
struct SecretsShared {
    secrets: Mutex<BTreeMap<String, Vec<u8>>>,
    failing: AtomicBool,
}

/// Secrets in memory (Swift: `InMemorySecretStore`). While [`set_failing`](Self::set_failing) is on,
/// every call fails as a locked keyring would.
#[derive(Debug, Clone, Default)]
pub struct MemorySecretStore(Arc<SecretsShared>);

impl MemorySecretStore {
    pub fn with(initial: impl IntoIterator<Item = (String, Vec<u8>)>) -> Self {
        let store = Self::default();
        lock(&store.0.secrets).extend(initial);
        store
    }

    pub fn set_failing(&self, failing: bool) {
        self.0.failing.store(failing, Ordering::SeqCst);
    }

    /// The stored secrets, bypassing `set_failing`.
    pub fn snapshot(&self) -> BTreeMap<String, Vec<u8>> {
        lock(&self.0.secrets).clone()
    }

    fn check(&self) -> Result<()> {
        if self.0.failing.load(Ordering::SeqCst) {
            Err(PlatformError::Denied("secret store locked".into()))
        } else {
            Ok(())
        }
    }
}

impl SecretStore for MemorySecretStore {
    async fn secret(&self, account: &str) -> Result<Option<Vec<u8>>> {
        self.check()?;
        Ok(lock(&self.0.secrets).get(account).cloned())
    }

    async fn set_secret(&self, account: &str, secret: &[u8]) -> Result<()> {
        self.check()?;
        lock(&self.0.secrets).insert(account.to_owned(), secret.to_vec());
        Ok(())
    }

    async fn remove_secret(&self, account: &str) -> Result<()> {
        self.check()?;
        lock(&self.0.secrets).remove(account);
        Ok(())
    }

    async fn all_secrets(&self) -> Result<BTreeMap<String, Vec<u8>>> {
        self.check()?;
        Ok(lock(&self.0.secrets).clone())
    }
}

// MARK: Advertiser

/// Records what is advertised: `Some` for each `advertise`, `None` for each `withdraw`.
#[derive(Debug, Clone, Default)]
pub struct FakeAdvertiser(Arc<Mutex<Vec<Option<ServiceAd>>>>);

impl FakeAdvertiser {
    pub fn history(&self) -> Vec<Option<ServiceAd>> {
        lock(&self.0).clone()
    }

    /// What is advertised now.
    pub fn current(&self) -> Option<ServiceAd> {
        lock(&self.0).last().cloned().flatten()
    }
}

impl Advertiser for FakeAdvertiser {
    async fn advertise(&self, ad: ServiceAd) -> Result<()> {
        lock(&self.0).push(Some(ad));
        Ok(())
    }

    async fn withdraw(&self) {
        lock(&self.0).push(None);
    }
}

// MARK: Audio

#[derive(Debug, Default)]
struct AudioState {
    /// The running capture's sender and format, if any.
    running: Option<(mpsc::Sender<AudioChunk>, AudioFormat, u32)>,
    starts: usize,
    stops: usize,
    fail_next: Option<PlatformError>,
}

/// A sound capture driven by the test: [`push`](Self::push) sends a chunk to the running capture.
#[derive(Debug, Clone, Default)]
pub struct FakeAudio(Arc<Mutex<AudioState>>);

/// The fake's capture: dropping it stops the capture.
#[derive(Debug)]
pub struct FakeAudioCapture(Arc<Mutex<AudioState>>);

impl Drop for FakeAudioCapture {
    fn drop(&mut self) {
        let mut state = lock(&self.0);
        state.running = None;
        state.stops += 1;
    }
}

impl FakeAudio {
    /// Sends a chunk to the running capture; false if none is running or its queue is full.
    pub fn push(&self, chunk: AudioChunk) -> bool {
        lock(&self.0).running.as_ref().is_some_and(|(tx, _, _)| tx.try_send(chunk).is_ok())
    }

    /// The running capture's format and chunk length.
    pub fn running(&self) -> Option<(AudioFormat, u32)> {
        lock(&self.0).running.as_ref().map(|(_, f, ms)| (*f, *ms))
    }

    /// How many captures were started.
    pub fn starts(&self) -> usize {
        lock(&self.0).starts
    }

    /// How many captures were stopped (dropped).
    pub fn stops(&self) -> usize {
        lock(&self.0).stops
    }

    /// The next start fails with `error`.
    pub fn fail_next_start(&self, error: PlatformError) {
        lock(&self.0).fail_next = Some(error);
    }
}

impl AudioBackend for FakeAudio {
    type Capture = FakeAudioCapture;

    async fn start(
        &self,
        format: AudioFormat,
        chunk_ms: u32,
    ) -> Result<(FakeAudioCapture, mpsc::Receiver<AudioChunk>)> {
        let mut state = lock(&self.0);
        if let Some(e) = state.fail_next.take() {
            return Err(e);
        }
        let (tx, rx) = mpsc::channel(AUDIO_QUEUE_CHUNKS);
        state.running = Some((tx, format, chunk_ms));
        state.starts += 1;
        Ok((FakeAudioCapture(self.0.clone()), rx))
    }
}

// MARK: Platform

/// One fake of each contract, sharing one [`FakeClock`]. Fields are handles: clone one to drive it while
/// the code under test owns the platform.
#[derive(Debug, Clone)]
pub struct FakePlatform {
    pub display: FakeDisplay,
    pub video: FakeVideo,
    pub cursor: FakeCursor,
    pub input: FakeInput,
    pub power: FakePower,
    pub settings: FakeSettings,
    pub setup: FakeSetup,
    pub secrets: MemorySecretStore,
    pub clock: FakeClock,
    pub audio: FakeAudio,
}

impl FakePlatform {
    pub fn new() -> Self {
        let clock = FakeClock::default();
        Self {
            display: FakeDisplay::new(),
            video: FakeVideo::new(clock.clone()),
            cursor: FakeCursor::default(),
            input: FakeInput::default(),
            power: FakePower::default(),
            settings: FakeSettings::default(),
            setup: FakeSetup::default(),
            secrets: MemorySecretStore::default(),
            clock,
            audio: FakeAudio::default(),
        }
    }
}

impl Default for FakePlatform {
    fn default() -> Self {
        Self::new()
    }
}

impl Platform for FakePlatform {
    type Display = FakeDisplay;
    type Video = FakeVideo;
    type Cursor = FakeCursor;
    type Input = FakeInput;
    type Power = FakePower;
    type Settings = FakeSettings;
    type Setup = FakeSetup;
    type Secrets = MemorySecretStore;
    type Clock = FakeClock;
    type Audio = FakeAudio;

    fn display(&self) -> &FakeDisplay {
        &self.display
    }

    fn video(&self) -> &FakeVideo {
        &self.video
    }

    fn cursor(&self) -> &FakeCursor {
        &self.cursor
    }

    fn input(&self) -> &FakeInput {
        &self.input
    }

    fn power(&self) -> &FakePower {
        &self.power
    }

    fn settings(&self) -> &FakeSettings {
        &self.settings
    }

    fn setup(&self) -> &FakeSetup {
        &self.setup
    }

    fn secrets(&self) -> &MemorySecretStore {
        &self.secrets
    }

    fn clock(&self) -> &FakeClock {
        &self.clock
    }

    fn audio(&self) -> &FakeAudio {
        &self.audio
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SPEC: DisplaySpec =
        DisplaySpec { pixel_width: 2752, pixel_height: 2064, scale: 2, desired_scale: 0, refresh_hz: 120 };
    const CONFIG: EncodeConfig = EncodeConfig {
        width: 2752,
        height: 2064,
        frame_rate: 120,
        bitrate: 60_000_000,
        chroma: Chroma::Yuv420,
        bit_depth: 8,
    };

    #[tokio::test]
    async fn display_lifecycle_updates_monitors() {
        let display = FakeDisplay::new();
        let mut monitors = display.monitors();
        let (created, source) = display.create(SPEC).await.unwrap();
        assert_eq!(source.display_id, created.id);
        assert!(monitors.has_changed().unwrap());
        let list = monitors.borrow_and_update().clone();
        let lain = list.iter().find(|m| m.lain).unwrap();
        assert_eq!(lain.bounds, RectF::new(1920.0, 0.0, 1376.0, 1032.0));

        assert!(display.create(SPEC).await.is_err(), "one display at a time");
        display.destroy().await;
        display.destroy().await;
        assert_eq!(display.destroy_count(), 1);
        assert!(monitors.borrow_and_update().iter().all(|m| !m.lain));

        display.fail_next_create(PlatformError::Unavailable("no compositor".into()));
        assert_eq!(display.create(SPEC).await.unwrap_err(), PlatformError::Unavailable("no compositor".into()));
        let (second, _) = display.create(SPEC).await.unwrap();
        assert_ne!(second.id, created.id, "ids aren't reused");
    }

    #[tokio::test]
    async fn immediate_encode_uses_the_newest_capture() {
        let video = FakeVideo::default();
        let (session, mut events) = video.start(&FakeSource { display_id: 100 }, CONFIG).await.unwrap();

        session.encode(EncodeRequest { frame_id: 1, keyframe: true, refinement: false, bitrate: None });
        assert_eq!(events.recv().await, Some(VideoEvent::EncodeFailed { frame_id: 1 }));

        let handle = video.last_session().unwrap();
        assert_eq!(handle.capture(), 1);
        assert_eq!(handle.capture(), 2);
        assert!(matches!(events.recv().await, Some(VideoEvent::Captured { capture: 1, .. })));
        assert!(matches!(events.recv().await, Some(VideoEvent::Captured { capture: 2, .. })));

        session.encode(EncodeRequest { frame_id: 2, keyframe: true, refinement: false, bitrate: None });
        let Some(VideoEvent::Encoded(frame)) = events.recv().await else { panic!("expected a frame") };
        assert_eq!((frame.frame_id, frame.capture, frame.keyframe), (2, 2, true));
        assert_eq!(frame.annexb, fake_access_unit(2, true));

        session.stop().await;
        assert!(handle.is_stopped());
        assert_eq!(events.recv().await, None, "the stream closes on stop");
    }

    #[tokio::test]
    async fn manual_encode_waits_for_the_test() {
        let video = FakeVideo::default();
        video.set_mode(EncodeMode::Manual);
        let (session, mut events) = video.start(&FakeSource { display_id: 100 }, CONFIG).await.unwrap();
        let handle = video.last_session().unwrap();
        handle.capture();
        let _ = events.recv().await;
        session.encode(EncodeRequest { frame_id: 7, keyframe: false, refinement: true, bitrate: None });
        handle.capture();
        let _ = events.recv().await;
        assert!(handle.complete(7));
        let Some(VideoEvent::Encoded(frame)) = events.recv().await else { panic!("expected a frame") };
        assert_eq!(frame.capture, 1, "the capture newest when requested");
        assert!(!handle.complete(7));
    }

    #[test]
    fn fake_access_units_have_no_start_code_inside() {
        for id in [0, 1, 127, 128, 0x1FFFFF] {
            for keyframe in [false, true] {
                let au = fake_access_unit(id, keyframe);
                let starts = au.windows(4).filter(|w| *w == [0, 0, 0, 1]).count();
                assert_eq!(starts, if keyframe { 4 } else { 1 });
                assert_eq!(au.windows(3).filter(|w| *w == [0, 0, 1]).count(), starts);
            }
        }
    }

    #[tokio::test]
    async fn secrets_fail_while_locked() {
        let store = MemorySecretStore::with([("host".to_owned(), vec![1; 32])]);
        assert_eq!(store.secret("host").await.unwrap(), Some(vec![1; 32]));
        store.set_failing(true);
        assert!(store.all_secrets().await.is_err());
        store.set_failing(false);
        store.remove_secret("host").await.unwrap();
        store.remove_secret("host").await.unwrap();
        assert!(store.all_secrets().await.unwrap().is_empty());
    }

    #[test]
    fn platform_bundle_compiles_against_the_contract() {
        fn uses<P: Platform>(platform: &P) -> u64 {
            platform.clock().now_ns()
        }
        assert_eq!(uses(&FakePlatform::new()), 1_000_000_000);
    }
}
