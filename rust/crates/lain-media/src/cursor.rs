//! Cursor shapes (Swift: `LainHostCore/Video/CursorMonitor.swift`: `CursorShapeTracker`, `CursorMonitor`).

use std::collections::HashMap;
use std::sync::Arc;

use lain_platform::{Clock, CursorImage, CursorSource};
use lain_proto::{CursorSelect, CursorShape, HeaderFlags, Message};

use crate::{Connection, Outbound};

/// The shape bookkeeping, without timers (Swift: `CursorShapeTracker`): each unique image gets an id and is
/// sent once as `CursorShape`; `CursorSelect` goes out whenever the current shape or its visibility
/// changes. At most [`CursorShape::MAX_LIVE`] shapes are live: past that the table starts over (ids keep
/// growing), so every shape is resent when next used and the client's lowest-id eviction never drops a live
/// one.
///
/// Images are shared `Arc`s ([`CursorSource::current`] returns the same one while the cursor is unchanged),
/// so the unchanged case is a pointer comparison; content is compared only when the `Arc` differs. Swift
/// compares the last image by value.
#[derive(Debug)]
pub struct CursorShapeTracker {
    ids: HashMap<Arc<CursorImage>, u32>,
    next_id: u32,
    current: Option<(u32, bool)>,
    /// The last image seen, so an unchanged cursor (the common case at 60 Hz) skips hashing.
    last: Option<(Arc<CursorImage>, u32)>,
}

impl Default for CursorShapeTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl CursorShapeTracker {
    pub fn new() -> Self {
        Self { ids: HashMap::new(), next_id: 1, current: None, last: None }
    }

    pub fn unique_shapes(&self) -> usize {
        self.ids.len()
    }

    /// The messages to send for this sample, in order (a new shape precedes its select). `None` is a hidden
    /// cursor: the last shape stays selected, invisible.
    pub fn update(&mut self, image: Option<&Arc<CursorImage>>) -> Vec<Message> {
        let Some(image) = image else {
            return match self.current {
                Some((id, true)) => {
                    self.current = Some((id, false));
                    vec![Message::CursorSelect(CursorSelect { shape_id: id, visible: false })]
                }
                _ => Vec::new(),
            };
        };
        let mut out = Vec::new();
        let id = match &self.last {
            Some((last, id)) if Arc::ptr_eq(last, image) || **last == **image => *id,
            _ => match self.ids.get(image) {
                Some(&id) => id,
                None => {
                    if self.ids.len() >= CursorShape::MAX_LIVE {
                        self.ids.clear();
                    }
                    let id = self.next_id;
                    self.next_id = self.next_id.wrapping_add(1);
                    self.ids.insert(Arc::clone(image), id);
                    out.push(Message::CursorShape(CursorShape {
                        shape_id: id,
                        pixel_width: image.pixel_width,
                        pixel_height: image.pixel_height,
                        scale: image.scale,
                        hotspot_x: image.hotspot_x,
                        hotspot_y: image.hotspot_y,
                        pixels: image.pixels.clone(),
                    }));
                    id
                }
            },
        };
        self.last = Some((Arc::clone(image), id));
        if self.current != Some((id, true)) {
            self.current = Some((id, true));
            out.push(Message::CursorSelect(CursorSelect { shape_id: id, visible: true }));
        }
        out
    }
}

/// Samples a [`CursorSource`] at about 60 Hz and sends `CursorShape` / `CursorSelect` on the realtime
/// connection through its output callback (Swift: `CursorMonitor`).
///
/// Intended difference from Swift: no timer of its own. Like [`VideoPipeline`](crate::VideoPipeline) it is
/// driven by its owner: [`start`](Self::start), then call [`on_timer`](Self::on_timer) at
/// [`next_deadline`](Self::next_deadline) (re-read after every call). Time comes from the [`Clock`].
pub struct CursorMonitor<Src: CursorSource, C: Clock> {
    source: Src,
    clock: C,
    out: Box<dyn FnMut(Outbound) + Send>,
    tracker: CursorShapeTracker,
    interval_ns: u64,
    next_ns: Option<u64>,
    stopped: bool,
}

impl<Src: CursorSource, C: Clock> CursorMonitor<Src, C> {
    /// Swift's default rate.
    pub const DEFAULT_HZ: f64 = 60.0;

    /// `hz` must be positive and finite.
    pub fn new(source: Src, clock: C, hz: f64, out: impl FnMut(Outbound) + Send + 'static) -> Self {
        assert!(hz.is_finite() && hz > 0.0, "cursor rate must be positive");
        Self {
            source,
            clock,
            out: Box::new(out),
            tracker: CursorShapeTracker::new(),
            interval_ns: ((1e9 / hz).round() as u64).max(1),
            next_ns: None,
            stopped: false,
        }
    }

    pub fn source(&self) -> &Src {
        &self.source
    }

    /// Starts periodic sampling; the first sample is due at once. Does nothing once stopped or already
    /// started.
    pub fn start(&mut self) {
        if !self.stopped && self.next_ns.is_none() {
            self.next_ns = Some(self.clock.now_ns());
        }
    }

    /// When [`on_timer`](Self::on_timer) next has work: `None` before `start` and after `stop`.
    pub fn next_deadline(&self) -> Option<u64> {
        if self.stopped { None } else { self.next_ns }
    }

    /// Samples if a sample is due, and schedules the next one interval later. A late call doesn't make up
    /// the samples it missed.
    pub fn on_timer(&mut self) {
        let Some(due) = self.next_deadline() else { return };
        let now = self.clock.now_ns();
        if now < due {
            return;
        }
        self.sample_now();
        let next = due.saturating_add(self.interval_ns);
        self.next_ns = Some(if next > now { next } else { now.saturating_add(self.interval_ns) });
    }

    /// Samples once and sends whatever changed (Swift: `sampleNow`, also used by tests).
    pub fn sample_now(&mut self) {
        if self.stopped {
            return;
        }
        let image = self.source.current();
        for message in self.tracker.update(image.as_ref()) {
            (self.out)(Outbound { connection: Connection::Realtime, message, flags: HeaderFlags::EMPTY });
        }
    }

    /// Idempotent; nothing is sent afterwards.
    pub fn stop(&mut self) {
        self.stopped = true;
        self.next_ns = None;
    }

    pub fn unique_shapes(&self) -> usize {
        self.tracker.unique_shapes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lain_platform::fake::{FakeClock, FakeCursor};
    use lain_proto::{FrameParser, MessageCodec};
    use std::sync::Mutex;

    fn image(fill: u8, hotspot: f32) -> Arc<CursorImage> {
        Arc::new(CursorImage::new(4, 4, 2, hotspot, hotspot, vec![fill; 64]))
    }

    fn img(fill: u8) -> Arc<CursorImage> {
        image(fill, 1.0)
    }

    fn describe(messages: &[Message]) -> Vec<String> {
        messages
            .iter()
            .map(|m| match m {
                Message::CursorShape(s) => format!("shape {}", s.shape_id),
                Message::CursorSelect(s) => format!("select {}{}", s.shape_id, if s.visible { "" } else { " hidden" }),
                _ => "other".into(),
            })
            .collect()
    }

    #[test]
    fn sends_each_shape_once_and_selects_on_change() {
        let mut t = CursorShapeTracker::new();
        let (arrow, beam) = (img(10), img(20));
        assert_eq!(describe(&t.update(Some(&arrow))), ["shape 1", "select 1"]);
        assert!(t.update(Some(&arrow)).is_empty()); // unchanged: nothing
        assert_eq!(describe(&t.update(Some(&beam))), ["shape 2", "select 2"]);
        assert_eq!(describe(&t.update(Some(&arrow))), ["select 1"]); // known shape: select only
        assert!(t.update(Some(&img(10))).is_empty()); // equal content, new instance
        assert_eq!(describe(&t.update(Some(&image(10, 3.0)))), ["shape 3", "select 3"]); // hotspot is part of it
        assert_eq!(t.unique_shapes(), 3);
    }

    #[test]
    fn past_the_live_window_shapes_are_resent_under_new_ids() {
        let mut t = CursorShapeTracker::new();
        for i in 0..CursorShape::MAX_LIVE {
            let _ = t.update(Some(&img(i as u8))); // ids 1...64
        }
        assert_eq!(describe(&t.update(Some(&img(0)))), ["select 1"]);
        assert_eq!(describe(&t.update(Some(&img(200)))), ["shape 65", "select 65"]); // the table starts over
        assert_eq!(t.unique_shapes(), 1);
        assert_eq!(describe(&t.update(Some(&img(0)))), ["shape 66", "select 66"]); // resent, not just selected
    }

    #[test]
    fn hidden_keeps_the_shape_and_shows_again() {
        let mut t = CursorShapeTracker::new();
        assert!(t.update(None).is_empty()); // nothing shown yet: nothing to hide
        let _ = t.update(Some(&img(1)));
        assert_eq!(describe(&t.update(None)), ["select 1 hidden"]);
        assert!(t.update(None).is_empty());
        assert_eq!(describe(&t.update(Some(&img(1)))), ["select 1"]);
        assert_eq!(describe(&t.update(None)), ["select 1 hidden"]);
        assert_eq!(describe(&t.update(Some(&img(2)))), ["shape 2", "select 2"]);
    }

    #[test]
    fn shape_carries_pixels_and_hotspot() {
        let mut t = CursorShapeTracker::new();
        let image = Arc::new(CursorImage::new(2, 3, 2, 0.5, 1.5, (0..24).collect()));
        let Some(Message::CursorShape(s)) = t.update(Some(&image)).into_iter().next() else { panic!("no shape") };
        assert_eq!((s.pixel_width, s.pixel_height, s.scale), (2, 3, 2));
        assert_eq!((s.hotspot_x, s.hotspot_y), (0.5, 1.5));
        assert_eq!(s.pixels, image.pixels);
        // And it survives the wire.
        let bytes = MessageCodec::encode(&Message::CursorShape(s.clone()), 0, 0, None, None);
        let mut parser = FrameParser::new();
        parser.append(&bytes);
        assert_eq!(parser.next().unwrap().unwrap().message, Message::CursorShape(s));
    }

    /// A source that plays a list of images, repeating the last (Swift: `SequenceCursor`).
    struct SequenceCursor(Mutex<Vec<Option<Arc<CursorImage>>>>);

    impl CursorSource for SequenceCursor {
        fn current(&self) -> Option<Arc<CursorImage>> {
            let mut v = self.0.lock().unwrap();
            if v.len() > 1 { v.remove(0) } else { v.first().cloned().flatten() }
        }
    }

    type Sent = Arc<Mutex<Vec<Outbound>>>;

    fn monitor<S: CursorSource>(source: S, clock: &FakeClock, hz: f64) -> (CursorMonitor<S, FakeClock>, Sent) {
        let sent: Sent = Arc::default();
        let sink = Arc::clone(&sent);
        (CursorMonitor::new(source, clock.clone(), hz, move |o| sink.lock().unwrap().push(o)), sent)
    }

    fn messages(sent: &Sent) -> Vec<Message> {
        sent.lock().unwrap().iter().map(|o| o.message.clone()).collect()
    }

    #[test]
    fn samples_send_through_the_callback_and_stop_silences() {
        let source = SequenceCursor(Mutex::new(vec![Some(img(1)), Some(img(1)), Some(img(2)), None, Some(img(2))]));
        let (mut m, sent) = monitor(source, &FakeClock::default(), 60.0);
        for _ in 0..5 {
            m.sample_now();
        }
        assert_eq!(
            describe(&messages(&sent)),
            ["shape 1", "select 1", "shape 2", "select 2", "select 2 hidden", "select 2"]
        );
        assert!(sent.lock().unwrap().iter().all(|o| o.connection == Connection::Realtime && o.flags.is_empty()));
        m.stop();
        m.stop();
        let count = sent.lock().unwrap().len();
        m.sample_now();
        m.on_timer();
        assert_eq!(sent.lock().unwrap().len(), count);
    }

    #[test]
    fn timer_samples_at_the_rate() {
        let clock = FakeClock::default();
        let cursor = FakeCursor::default();
        cursor.set(Some(CursorImage::new(1, 1, 2, 0.0, 0.0, vec![9; 4])));
        let (mut m, sent) = monitor(cursor.clone(), &clock, 200.0);
        assert_eq!(m.next_deadline(), None, "not before start");
        m.start();
        let t0 = clock.now_ns();
        assert_eq!(m.next_deadline(), Some(t0), "the first sample is immediate");
        m.on_timer();
        assert_eq!(describe(&messages(&sent)), ["shape 1", "select 1"]);
        assert_eq!(m.next_deadline(), Some(t0 + 5_000_000));
        clock.advance(4_000_000);
        cursor.set(Some(CursorImage::new(1, 1, 2, 0.0, 0.0, vec![7; 4])));
        m.on_timer(); // early: nothing
        assert_eq!(messages(&sent).len(), 2);
        clock.advance(1_000_000);
        m.on_timer();
        assert_eq!(describe(&messages(&sent)[2..]), ["shape 2", "select 2"]);
        // A late timer doesn't make up missed samples.
        clock.advance(100_000_000);
        m.on_timer();
        assert_eq!(m.next_deadline(), Some(clock.now_ns() + 5_000_000));
        assert_eq!(messages(&sent).len(), 4, "unchanged cursor");
        m.stop();
        assert_eq!(m.next_deadline(), None);
    }

    /// Swift: `startAfterStopDoesNothing`.
    #[test]
    fn start_after_stop_does_nothing() {
        let clock = FakeClock::default();
        let source = SequenceCursor(Mutex::new(vec![Some(img(1))]));
        let (mut m, sent) = monitor(source, &clock, 200.0);
        m.stop();
        m.start();
        m.start();
        assert_eq!(m.next_deadline(), None);
        clock.advance(50_000_000);
        m.on_timer();
        assert!(sent.lock().unwrap().is_empty());
    }
}
