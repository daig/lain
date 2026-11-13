//! The pure half of the capture: PipeWire's buffers, whatever their size, cut into chunks of exactly `chunk_ms`
//! worth of whole frames, each stamped with its first frame's capture time; and their delivery to the bounded
//! channel, dropping (never waiting) when the session is behind.
//!
//! Capture time: a buffer's last frame is taken to have been captured when the buffer arrived (the process
//! callback's `now_ns`), so its first frame `frames / rate` earlier. The chunks' times then follow one continuous
//! timeline (frame `n` after the anchor at `anchor + n / rate`), so consecutive chunks are exactly `chunk_ms`
//! apart rather than carrying each callback's scheduling jitter. The timeline is re-anchored on an arriving buffer
//! when it disagrees with the arrival by more than [`Chunker::tolerance_ns`] (a gap in the stream, a suspended
//! sink, the device clock drifting from `CLOCK_MONOTONIC`), never backwards past the last chunk sent, so the
//! times stay monotonic and chunks never overlap. No sample is dropped by a re-anchor.

use lain_platform::{AudioChunk, AudioFormat};
use tokio::sync::mpsc;

const NS_PER_S: u128 = 1_000_000_000;

/// The smallest disagreement between the timeline and an arrival that re-anchors it.
const MIN_TOLERANCE_NS: u64 = 10_000_000;

/// Cuts buffers into whole-frame chunks of `chunk_frames` and stamps them.
#[derive(Debug)]
pub struct Chunker {
    frame_bytes: usize,
    chunk_frames: usize,
    rate: u32,
    /// Whole frames not yet sent.
    pending: Vec<u8>,
    /// The timeline: frame `n` after the anchor was captured at `anchor_ns + n / rate`.
    anchor_ns: Option<u64>,
    /// `pending`'s first frame, counted from the anchor.
    next_frame: u64,
}

impl Chunker {
    /// Chunks of `chunk_ms` in `format` (at least one frame).
    pub fn new(format: AudioFormat, chunk_ms: u32) -> Self {
        Self {
            frame_bytes: format.frame_bytes().max(2),
            chunk_frames: chunk_frames(format, chunk_ms),
            rate: format.sample_rate.max(1),
            pending: Vec::new(),
            anchor_ns: None,
            next_frame: 0,
        }
    }

    /// Frames in each chunk.
    pub fn chunk_frames(&self) -> usize {
        self.chunk_frames
    }

    /// How far the timeline may disagree with an arrival before it is re-anchored: one chunk, at least 10 ms.
    pub fn tolerance_ns(&self) -> u64 {
        self.frames_ns(self.chunk_frames as u64).max(MIN_TOLERANCE_NS)
    }

    fn frames_ns(&self, frames: u64) -> u64 {
        (u128::from(frames) * NS_PER_S / u128::from(self.rate)) as u64
    }

    fn time_of(&self, anchor_ns: u64, frame: u64) -> u64 {
        anchor_ns + self.frames_ns(frame)
    }

    /// Adds one buffer of interleaved frames, which arrived at `arrival_ns`, and sends every complete chunk to
    /// `emit`. A trailing partial frame (PipeWire never sends one) is ignored.
    pub fn push(&mut self, data: &[u8], arrival_ns: u64, mut emit: impl FnMut(AudioChunk)) {
        let whole = data.len() / self.frame_bytes * self.frame_bytes;
        if whole == 0 {
            return;
        }
        let frames = (whole / self.frame_bytes) as u64;
        let pending_frames = (self.pending.len() / self.frame_bytes) as u64;
        // When this buffer's first frame was captured.
        let start = arrival_ns.saturating_sub(self.frames_ns(frames));
        let anchor = match self.anchor_ns {
            None => start,
            Some(anchor) => {
                let expected = self.time_of(anchor, self.next_frame + pending_frames);
                if start.abs_diff(expected) > self.tolerance_ns() {
                    // Never earlier than the end of the last chunk sent.
                    let floor = self.time_of(anchor, self.next_frame);
                    self.next_frame = 0;
                    start.saturating_sub(self.frames_ns(pending_frames)).max(floor)
                } else {
                    anchor
                }
            }
        };
        if self.anchor_ns != Some(anchor) {
            self.anchor_ns = Some(anchor);
            self.next_frame = 0;
        }
        self.pending.extend_from_slice(&data[..whole]);
        let chunk_bytes = self.chunk_frames * self.frame_bytes;
        while self.pending.len() >= chunk_bytes {
            let rest = self.pending.split_off(chunk_bytes);
            let samples = std::mem::replace(&mut self.pending, rest);
            emit(AudioChunk { capture_time_ns: self.time_of(anchor, self.next_frame), samples });
            self.next_frame += self.chunk_frames as u64;
        }
    }
}

/// Frames in `chunk_ms` of `format` (at least one).
pub fn chunk_frames(format: AudioFormat, chunk_ms: u32) -> usize {
    ((u64::from(format.sample_rate) * u64::from(chunk_ms) / 1000) as usize).max(1)
}

/// Sends chunks to the session without ever waiting: a full queue drops the chunk (logged once per run of
/// drops).
#[derive(Debug)]
pub struct Delivery {
    tx: mpsc::Sender<AudioChunk>,
    dropped: u64,
}

impl Delivery {
    pub fn new(tx: mpsc::Sender<AudioChunk>) -> Self {
        Self { tx, dropped: 0 }
    }

    /// Sends `chunk`; false if it was dropped (queue full or the session gone).
    pub fn deliver(&mut self, chunk: AudioChunk) -> bool {
        match self.tx.try_send(chunk) {
            Ok(()) => {
                if self.dropped > 0 {
                    tracing::info!(dropped = self.dropped, "sound queue drained; chunks were dropped meanwhile");
                    self.dropped = 0;
                }
                true
            }
            Err(mpsc::error::TrySendError::Full(_)) => {
                if self.dropped == 0 {
                    tracing::warn!("sound queue full: dropping chunks until the session catches up");
                }
                self.dropped += 1;
                false
            }
            Err(mpsc::error::TrySendError::Closed(_)) => false,
        }
    }

    /// Chunks dropped since the queue last accepted one.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Whether the session dropped its receiver.
    pub fn is_closed(&self) -> bool {
        self.tx.is_closed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lain_platform::AUDIO_QUEUE_CHUNKS;

    const MS: u64 = 1_000_000;

    fn frames(n: usize, channels: u8, first: u16) -> Vec<u8> {
        (0..n * channels as usize).flat_map(|i| (first.wrapping_add(i as u16)).to_le_bytes()).collect()
    }

    fn run(chunker: &mut Chunker, data: &[u8], arrival: u64) -> Vec<AudioChunk> {
        let mut out = Vec::new();
        chunker.push(data, arrival, |c| out.push(c));
        out
    }

    #[test]
    fn exact_buffers_are_exact_chunks() {
        let mut c = Chunker::new(AudioFormat::SESSION, 20);
        assert_eq!(c.chunk_frames(), 480);
        let mut times = Vec::new();
        for i in 0..5u64 {
            let out = run(&mut c, &frames(480, 1, 0), 1_000 * MS + (i + 1) * 20 * MS);
            assert_eq!(out.len(), 1);
            assert_eq!(out[0].samples.len(), 960);
            times.push(out[0].capture_time_ns);
        }
        assert_eq!(times, (0..5).map(|i| 1_000 * MS + i * 20 * MS).collect::<Vec<_>>());
    }

    #[test]
    fn arbitrary_buffers_split_and_join_without_losing_a_sample() {
        let format = AudioFormat { sample_rate: 48_000, channels: 2 };
        let mut c = Chunker::new(format, 10);
        assert_eq!(c.chunk_frames(), 480);
        let mut all_in = Vec::new();
        let mut out = Vec::new();
        let mut arrival = 5_000 * MS;
        let mut sample = 0u16;
        for &n in &[100usize, 1024, 7, 333, 960, 1, 479, 2000, 256] {
            let buf = frames(n, 2, sample);
            sample = sample.wrapping_add((n * 2) as u16);
            arrival += (n as u64) * 1_000_000_000 / 48_000;
            all_in.extend_from_slice(&buf);
            out.extend(run(&mut c, &buf, arrival));
        }
        let total_frames = all_in.len() / 4;
        assert_eq!(out.len(), total_frames / 480);
        assert!(out.iter().all(|c| c.samples.len() == 480 * 4));
        let all_out: Vec<u8> = out.iter().flat_map(|c| c.samples.clone()).collect();
        assert_eq!(all_out[..], all_in[..all_out.len()], "the samples, in order");
        // One continuous timeline, 10 ms apart, starting at the first buffer's first frame.
        let first = 5_000 * MS;
        for (i, chunk) in out.iter().enumerate() {
            assert_eq!(chunk.capture_time_ns, first + i as u64 * 10 * MS, "chunk {i}");
        }
    }

    #[test]
    fn partial_frames_are_ignored() {
        let mut c = Chunker::new(AudioFormat { sample_rate: 1000, channels: 2 }, 10);
        let mut data = frames(10, 2, 0);
        data.push(0xAA);
        let out = run(&mut c, &data, 1_000 * MS);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].samples.len(), 40);
        assert!(run(&mut c, &[1, 2, 3], 1_010 * MS).is_empty());
    }

    #[test]
    fn jitter_within_tolerance_keeps_the_timeline() {
        let mut c = Chunker::new(AudioFormat::SESSION, 20);
        let a = run(&mut c, &frames(480, 1, 0), 120 * MS);
        // 3 ms late: still the same timeline.
        let b = run(&mut c, &frames(480, 1, 0), 143 * MS);
        assert_eq!(a[0].capture_time_ns, 100 * MS);
        assert_eq!(b[0].capture_time_ns, 120 * MS);
    }

    #[test]
    fn a_gap_reanchors_forwards() {
        let mut c = Chunker::new(AudioFormat::SESSION, 20);
        run(&mut c, &frames(240, 1, 0), 110 * MS); // half a chunk, first frame at 100 ms
        // The next half arrives a second later: the pending half is placed just before it.
        let out = run(&mut c, &frames(240, 1, 0), 1_110 * MS);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].capture_time_ns, 1_090 * MS);
        let next = run(&mut c, &frames(480, 1, 0), 1_130 * MS);
        assert_eq!(next[0].capture_time_ns, 1_110 * MS);
    }

    #[test]
    fn a_burst_never_goes_backwards() {
        let mut c = Chunker::new(AudioFormat::SESSION, 20);
        let a = run(&mut c, &frames(480, 1, 0), 1_000 * MS);
        assert_eq!(a[0].capture_time_ns, 980 * MS);
        // Three chunks arriving at once, as if captured earlier than the timeline allows.
        let b = run(&mut c, &frames(1440, 1, 0), 1_001 * MS);
        let times: Vec<u64> = b.iter().map(|c| c.capture_time_ns).collect();
        assert_eq!(times, vec![1_000 * MS, 1_020 * MS, 1_040 * MS]);
    }

    #[test]
    fn long_runs_do_not_overflow() {
        let mut c = Chunker::new(AudioFormat { sample_rate: 192_000, channels: 1 }, 20);
        // A month of frames since the anchor.
        c.anchor_ns = Some(1);
        c.next_frame = 192_000 * 86_400 * 31;
        let t = c.time_of(1, c.next_frame);
        assert_eq!(t, 1 + 86_400 * 31 * 1_000_000_000);
    }

    #[test]
    fn a_full_queue_drops_new_chunks() {
        let (tx, mut rx) = mpsc::channel(AUDIO_QUEUE_CHUNKS);
        let mut d = Delivery::new(tx);
        let chunk = |t| AudioChunk { capture_time_ns: t, samples: vec![0; 960] };
        for t in 0..AUDIO_QUEUE_CHUNKS as u64 {
            assert!(d.deliver(chunk(t)));
        }
        assert!(!d.deliver(chunk(1000)));
        assert!(!d.deliver(chunk(1001)));
        assert_eq!(d.dropped(), 2);
        // The queue keeps the oldest; the dropped ones never arrive.
        assert_eq!(rx.try_recv().unwrap().capture_time_ns, 0);
        assert!(d.deliver(chunk(2000)));
        assert_eq!(d.dropped(), 0);
        let mut last = 0;
        while let Ok(c) = rx.try_recv() {
            last = c.capture_time_ns;
            assert!(c.capture_time_ns < 1000 || c.capture_time_ns == 2000);
        }
        assert_eq!(last, 2000);
        drop(rx);
        assert!(d.is_closed());
        assert!(!d.deliver(chunk(3000)));
    }
}
