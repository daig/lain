//! The PipeWire consumer of lain's display (decision L7; SL5's structure: PipeWire on its own thread, which only
//! swaps the newest buffer into the video thread's latest-wins slot). A port of `spikes/linux-convert/e2e/e2e.c`'s
//! stream (and `lain-gnome`'s `negotiate.rs`, how the `pipewire` crate is driven). Swift: `FrameSource` /
//! `ScreenCaptureFrameSource` (behaviour: complete frames only, the compositor's capture time, a surface pool).
//!
//! - It connects to `GnomeSource::node_id` asking for exactly the display's size and `maxFramerate` refresh/1, a
//!   second consumer of the node `lain-gnome` negotiated (SL6: the same format, no new monitor). DMA-BUF first,
//!   at Mutter's modifier (`0x200000000401b03`, the one offered here, and what `e2e.c` asked for); shared memory
//!   as the fallback format.
//! - Every buffer's `SPA_META_Cursor` goes into the run's [`CursorState`] (`lain-gnome`'s `consume_cursor`
//!   does the same): the position, invalid while the pointer is hidden or off the stream, and each new bitmap.
//! - A buffer with an empty chunk carries only a cursor update: it goes back at once and isn't a picture.
//! - A DMA-BUF picture's fd is duplicated and its real size read (`lseek`), so the video thread's import never
//!   depends on PipeWire's buffer staying put; the buffer itself stays dequeued (Mutter can't draw into it) until
//!   the conversion has read it, and then comes back here through a channel to be queued. Buffers that PipeWire
//!   removed meanwhile (a renegotiation) are never queued again.
//! - A shared-memory picture is copied out at once and its buffer queued back.
//! - `capture_ns` is the buffer's `spa_meta_header.pts` (Mutter's frame time, `CLOCK_MONOTONIC`), else the arrival.
//! - A stream error, or the stream leaving the streaming states, is reported to the video thread
//!   ([`Inbox::capture_ended`]).
#![allow(unsafe_code)]

use std::cell::RefCell;
use std::collections::HashMap;
use std::os::fd::{BorrowedFd, OwnedFd};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use lain_gnome::{BitmapFormat, CursorState};
use pipewire as pw;
use pw::spa;
use pw::spa::param::format::{FormatProperties, MediaSubtype, MediaType};
use pw::spa::param::video::{VideoFormat, VideoInfoRaw};
use pw::spa::pod::{ChoiceValue, Object, Pod, Property, PropertyFlags, Value, serialize::PodSerializer};
use pw::spa::utils::{Choice, ChoiceEnum, ChoiceFlags, Fraction, Id, Rectangle, SpaTypes};
use tokio::sync::watch;

use crate::engine::{CaptureFrame, Inbox};
use crate::frame::{DmaBufPlane, Picture, Pixels};
use crate::gbm::{DRM_FORMAT_ARGB8888, DRM_FORMAT_XRGB8888, MUTTER_MODIFIER};

/// What to capture.
#[derive(Debug, Clone)]
pub struct CaptureConfig {
    pub node_id: u32,
    pub width: u32,
    pub height: u32,
    /// `maxFramerate`: the display's refresh rate.
    pub max_fps: u32,
    /// The DMA-BUF modifier asked for.
    pub modifier: u64,
    pub cursor: Arc<CursorState>,
}

impl CaptureConfig {
    pub fn new(node_id: u32, width: u32, height: u32, max_fps: u32, cursor: Arc<CursorState>) -> Self {
        Self { node_id, width, height, max_fps, modifier: MUTTER_MODIFIER, cursor }
    }
}

fn serialize(value: Value) -> Vec<u8> {
    PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &value).expect("a pod always serializes").0.into_inner()
}

/// One `EnumFormat`: raw BGRx (or BGRA), exactly `width × height`, `framerate` 0/1 (variable, as Mutter offers),
/// `maxFramerate` up to `fps`/1; with `modifier`, a mandatory DMA-BUF modifier (`e2e.c`'s format), without it
/// the shared-memory format (`lain-gnome`'s `format_pod`).
pub fn format_pod(width: u32, height: u32, fps: u32, modifier: Option<u64>) -> Vec<u8> {
    let mut properties = vec![
        Property::new(FormatProperties::MediaType.as_raw(), Value::Id(Id(MediaType::Video.as_raw()))),
        Property::new(FormatProperties::MediaSubtype.as_raw(), Value::Id(Id(MediaSubtype::Raw.as_raw()))),
        Property::new(
            FormatProperties::VideoFormat.as_raw(),
            Value::Choice(ChoiceValue::Id(Choice(
                ChoiceFlags::empty(),
                ChoiceEnum::Enum {
                    default: Id(VideoFormat::BGRx.as_raw()),
                    alternatives: vec![Id(VideoFormat::BGRx.as_raw()), Id(VideoFormat::BGRA.as_raw())],
                },
            ))),
        ),
        Property::new(FormatProperties::VideoSize.as_raw(), Value::Rectangle(Rectangle { width, height })),
        Property::new(FormatProperties::VideoFramerate.as_raw(), Value::Fraction(Fraction { num: 0, denom: 1 })),
        Property::new(
            FormatProperties::VideoMaxFramerate.as_raw(),
            Value::Choice(ChoiceValue::Fraction(Choice(
                ChoiceFlags::empty(),
                ChoiceEnum::Range {
                    default: Fraction { num: fps, denom: 1 },
                    min: Fraction { num: 1, denom: 1 },
                    max: Fraction { num: fps, denom: 1 },
                },
            ))),
        ),
    ];
    if let Some(m) = modifier {
        properties.push(Property {
            key: FormatProperties::VideoModifier.as_raw(),
            flags: PropertyFlags::MANDATORY,
            value: Value::Long(m as i64),
        });
    }
    serialize(Value::Object(Object {
        type_: SpaTypes::ObjectParamFormat.as_raw(),
        id: spa::param::ParamType::EnumFormat.as_raw(),
        properties,
    }))
}

/// `SPA_PARAM_Buffers`: 3–8 buffers (6 preferred, as `e2e.c`), of the data type the format implies.
pub fn buffers_pod(dmabuf: bool) -> Vec<u8> {
    let types = if dmabuf {
        1 << spa::sys::SPA_DATA_DmaBuf
    } else {
        (1 << spa::sys::SPA_DATA_MemFd) | (1 << spa::sys::SPA_DATA_MemPtr)
    };
    serialize(Value::Object(Object {
        type_: SpaTypes::ObjectParamBuffers.as_raw(),
        id: spa::param::ParamType::Buffers.as_raw(),
        properties: vec![
            Property::new(
                spa::sys::SPA_PARAM_BUFFERS_buffers,
                Value::Choice(ChoiceValue::Int(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Range { default: 6, min: 3, max: 8 },
                ))),
            ),
            Property::new(
                spa::sys::SPA_PARAM_BUFFERS_dataType,
                Value::Choice(ChoiceValue::Int(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Flags { default: types, flags: vec![] },
                ))),
            ),
        ],
    }))
}

/// `SPA_PARAM_Meta` for `SPA_META_Header` (the PTS).
pub fn header_meta_pod() -> Vec<u8> {
    serialize(Value::Object(Object {
        type_: SpaTypes::ObjectParamMeta.as_raw(),
        id: spa::param::ParamType::Meta.as_raw(),
        properties: vec![
            Property::new(spa::sys::SPA_PARAM_META_type, Value::Id(Id(spa::sys::SPA_META_Header))),
            Property::new(
                spa::sys::SPA_PARAM_META_size,
                Value::Int(std::mem::size_of::<spa::sys::spa_meta_header>() as i32),
            ),
        ],
    }))
}

/// Whether a `Format` param carries a modifier (so the buffers are DMA-BUFs).
pub fn format_has_modifier(format: &[u8]) -> bool {
    match spa::pod::deserialize::PodDeserializer::deserialize_any_from(format) {
        Ok((_, Value::Object(obj))) => obj.properties.iter().any(|p| p.key == FormatProperties::VideoModifier.as_raw()),
        _ => false,
    }
}

/// The negotiated format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Negotiated {
    pub width: u32,
    pub height: u32,
    /// DRM fourcc of the pixels (`XR24` or `AR24`).
    pub fourcc: u32,
    /// `Some` for DMA-BUF.
    pub modifier: Option<u64>,
}

/// One buffer's first data block and chunk, as PipeWire gave them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BufferView {
    pub n_datas: u32,
    pub data_type: u32,
    pub fd: i64,
    pub max_size: u32,
    pub has_data_ptr: bool,
    pub chunk_offset: u32,
    pub chunk_size: u32,
    pub chunk_stride: i32,
    pub chunk_flags: i32,
}

/// What a buffer is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BufferKind {
    /// No picture: a cursor update (an empty chunk) or a corrupted one.
    CursorOnly,
    /// A DMA-BUF picture at the chunk's offset and stride.
    DmaBuf { fd: i32, offset: u32, stride: u32 },
    /// A mapped shared-memory picture: `stride × height` bytes from `offset` of the data block.
    Memory { offset: u32, stride: u32 },
    /// Unusable, for the given reason.
    Invalid(&'static str),
}

/// Classifies a buffer (`e2e.c`'s `on_process` and `import`), before any of it is used.
pub fn classify(view: &BufferView, format: &Negotiated) -> BufferKind {
    if view.n_datas < 1 {
        return BufferKind::Invalid("no data block");
    }
    if view.chunk_size == 0 || view.chunk_flags & spa::sys::SPA_CHUNK_FLAG_CORRUPTED as i32 != 0 {
        return BufferKind::CursorOnly;
    }
    let row = format.width * 4;
    let stride = match u32::try_from(view.chunk_stride) {
        Ok(s) if s >= row => s,
        _ => return BufferKind::Invalid("a stride below a row"),
    };
    match (view.data_type, format.modifier) {
        (t, Some(_)) if t == spa::sys::SPA_DATA_DmaBuf => match i32::try_from(view.fd) {
            Ok(fd) if fd >= 0 && view.n_datas == 1 => BufferKind::DmaBuf { fd, offset: view.chunk_offset, stride },
            _ => BufferKind::Invalid("a DMA-BUF without a single fd"),
        },
        (t, None) if t == spa::sys::SPA_DATA_MemFd || t == spa::sys::SPA_DATA_MemPtr => {
            let end = u64::from(view.chunk_offset) + u64::from(stride) * u64::from(format.height - 1) + u64::from(row);
            if !view.has_data_ptr {
                BufferKind::Invalid("shared memory that isn't mapped")
            } else if end > u64::from(view.max_size) {
                BufferKind::Invalid("shared memory smaller than the picture")
            } else {
                BufferKind::Memory { offset: view.chunk_offset, stride }
            }
        }
        _ => BufferKind::Invalid("a data type that doesn't match the format"),
    }
}

/// Writes one buffer's cursor metadata into `cursor` (as `lain_gnome::negotiate::write_cursor`).
fn write_cursor(cursor: &CursorState, meta: &spa::buffer::meta::MetaCursor) {
    if !meta.is_valid() {
        cursor.set_invalid();
        return;
    }
    let p = meta.position();
    cursor.set_position(p.x, p.y);
    if let Some(bitmap) = meta.bitmap()
        && let Some(data) = bitmap.bitmap_data()
    {
        let format = if bitmap.format() == VideoFormat::BGRA { BitmapFormat::Bgra } else { BitmapFormat::Rgba };
        let size = bitmap.size();
        let hot = meta.hotspot();
        let stride = bitmap.stride().unsigned_abs() as usize;
        cursor.set_bitmap(format, size.width, size.height, stride, (hot.x, hot.y), data);
    }
}

/// A dequeued buffer, identified for its return: the pointer and the generation it was dequeued in.
struct RawBuffer {
    ptr: *mut pw::sys::pw_buffer,
    generation: u64,
}

// SAFETY: the pointer is only an identity while it travels to the video thread and back; it is dereferenced (and
// queued) only on the PipeWire thread, and only if that thread still has it outstanding with the same generation
// (so PipeWire hasn't removed or reused it meanwhile).
unsafe impl Send for RawBuffer {}

/// The running consumer: its thread, stopped on drop.
pub struct Capture {
    stop: Arc<AtomicBool>,
    done: watch::Receiver<bool>,
}

impl Capture {
    /// Starts the consumer thread; pictures go into `inbox`, its end is reported there. Setting `stop` (from any
    /// thread: the video thread stops capture this way) ends it within about 10 ms.
    pub fn start(config: CaptureConfig, inbox: Arc<Inbox>, stop: Arc<AtomicBool>) -> Result<Self, String> {
        let flag = stop.clone();
        let (done_tx, done) = watch::channel(false);
        std::thread::Builder::new()
            .name("lain-pw-capture".into())
            .spawn(move || {
                if let Err(e) = run(&config, &inbox, &flag) {
                    inbox.capture_ended(e);
                }
                let _ = done_tx.send(true);
            })
            .map_err(|e| format!("can't start the PipeWire thread: {e}"))?;
        Ok(Self { stop, done })
    }

    /// Becomes true once the thread has disconnected the stream and ended.
    pub fn done(&self) -> watch::Receiver<bool> {
        self.done.clone()
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
    }
}

#[derive(Default)]
struct Shared {
    format: Option<Negotiated>,
    /// Buffers dequeued and not yet given back, by pointer: their generation.
    outstanding: HashMap<usize, u64>,
    generation: u64,
    streaming: bool,
    ended: Option<String>,
}

fn now_ns() -> u64 {
    lain_platform::clock::now_ns()
}

fn run(config: &CaptureConfig, inbox: &Arc<Inbox>, stop: &AtomicBool) -> Result<(), String> {
    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None).map_err(|e| format!("PipeWire main loop: {e}"))?;
    let context = pw::context::ContextRc::new(&mainloop, None).map_err(|e| format!("PipeWire context: {e}"))?;
    let core = context.connect_rc(None).map_err(|e| format!("connecting to PipeWire: {e}"))?;
    let stream = pw::stream::StreamRc::new(
        core,
        "lain-video",
        pw::properties::properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
        },
    )
    .map_err(|e| format!("PipeWire stream: {e}"))?;
    let shared = Rc::new(RefCell::new(Shared::default()));
    let (returns, receiver) = pw::channel::channel::<RawBuffer>();

    // Buffers coming back from the video thread: queued if still ours.
    let back_stream = stream.clone();
    let back_shared = shared.clone();
    let attached = receiver.attach(mainloop.loop_(), move |raw: RawBuffer| {
        let mut s = back_shared.borrow_mut();
        if s.outstanding.get(&(raw.ptr as usize)) == Some(&raw.generation) {
            s.outstanding.remove(&(raw.ptr as usize));
            // SAFETY: the buffer was dequeued from this stream (it is outstanding with this generation, so PipeWire
            // hasn't removed it since) and is queued once.
            unsafe { back_stream.queue_raw_buffer(raw.ptr) };
        }
    });

    let (w, h, fps) = (config.width, config.height, config.max_fps);
    let fmt_shared = shared.clone();
    let state_shared = shared.clone();
    let rm_shared = shared.clone();
    let cursor = config.cursor.clone();
    let proc_shared = shared.clone();
    let proc_inbox = inbox.clone();
    let _listener = stream
        .add_local_listener_with_user_data(())
        .param_changed(move |stream, _, id, param| {
            let Some(param) = param else { return };
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            let mut info = VideoInfoRaw::new();
            if info.parse(param).is_err() {
                return;
            }
            let size = info.size();
            let fourcc = if info.format() == VideoFormat::BGRA { DRM_FORMAT_ARGB8888 } else { DRM_FORMAT_XRGB8888 };
            let dmabuf = format_has_modifier(param.as_bytes());
            let negotiated = Negotiated {
                width: size.width,
                height: size.height,
                fourcc,
                modifier: dmabuf.then(|| info.modifier()),
            };
            tracing::info!(?negotiated, "lain's display's stream format");
            if (size.width, size.height) != (w, h) {
                fmt_shared
                    .borrow_mut()
                    .ended
                    .get_or_insert(format!("the stream is {}×{}, not the display's {w}×{h}", size.width, size.height));
                return;
            }
            fmt_shared.borrow_mut().format = Some(negotiated);
            let pods = [buffers_pod(dmabuf), header_meta_pod(), lain_gnome::negotiate::cursor_meta_pod()];
            let mut params: Vec<&Pod> = pods.iter().filter_map(|b| Pod::from_bytes(b)).collect();
            if let Err(e) = stream.update_params(&mut params) {
                tracing::warn!("setting the stream's buffer params: {e}");
            }
        })
        .state_changed(move |_, _, old, new| {
            tracing::debug!(?old, ?new, "lain's display's stream");
            let mut s = state_shared.borrow_mut();
            match new {
                pw::stream::StreamState::Error(e) => {
                    s.ended.get_or_insert(format!("PipeWire stream error: {e}"));
                }
                pw::stream::StreamState::Streaming | pw::stream::StreamState::Paused => s.streaming = true,
                pw::stream::StreamState::Unconnected if s.streaming => {
                    s.ended.get_or_insert("the PipeWire stream was disconnected".into());
                }
                _ => {}
            }
        })
        .remove_buffer(move |_, _, buffer| {
            rm_shared.borrow_mut().outstanding.remove(&(buffer as usize));
        })
        .process(move |stream, _| {
            loop {
                // SAFETY: dequeued from this stream; it is queued back here, or later through the channel.
                let raw = unsafe { stream.dequeue_raw_buffer() };
                if raw.is_null() {
                    break;
                }
                let arrival = now_ns();
                let format = proc_shared.borrow().format;
                // SAFETY: a dequeued pw_buffer points at its spa_buffer, its metas and datas, valid until it is
                // queued back; nothing here outlives that except the duplicated fd and copied bytes.
                let picture = unsafe { read_buffer(raw, format, &cursor, arrival) };
                match picture {
                    Some((picture, capture_ns)) if !matches!(picture.pixels, Pixels::Memory { .. }) => {
                        let generation = {
                            let mut s = proc_shared.borrow_mut();
                            s.generation += 1;
                            let g = s.generation;
                            s.outstanding.insert(raw as usize, g);
                            g
                        };
                        let returns = returns.clone();
                        let back = RawBuffer { ptr: raw, generation };
                        let release = Box::new(move || {
                            let _ = returns.send(back);
                        });
                        proc_inbox.push_frame(CaptureFrame::new(picture, capture_ns, Some(release)));
                    }
                    other => {
                        // SAFETY: dequeued above, queued once.
                        unsafe { stream.queue_raw_buffer(raw) };
                        if let Some((picture, capture_ns)) = other {
                            proc_inbox.push_frame(CaptureFrame::new(picture, capture_ns, None));
                        }
                    }
                }
            }
        })
        .register()
        .map_err(|e| format!("PipeWire listener: {e}"))?;

    let dmabuf = format_pod(w, h, fps, Some(config.modifier));
    let memory = format_pod(w, h, fps, None);
    let mut params: Vec<&Pod> = [&dmabuf, &memory].iter().filter_map(|b| Pod::from_bytes(b)).collect();
    stream
        .connect(
            spa::utils::Direction::Input,
            Some(config.node_id),
            pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
            &mut params,
        )
        .map_err(|e| format!("connecting to node {}: {e}", config.node_id))?;
    tracing::info!(node = config.node_id, "capturing lain's display");

    while !stop.load(Ordering::Acquire) {
        mainloop.loop_().iterate(pw::loop_::Timeout::Finite(Duration::from_millis(10)));
        let ended = shared.borrow_mut().ended.take();
        if let Some(why) = ended {
            inbox.capture_ended(why);
            break;
        }
    }
    // The receiver goes before the stream, so no buffer is queued into a destroyed stream.
    drop(attached);
    let _ = stream.disconnect();
    Ok(())
}

/// Reads one dequeued buffer: writes its cursor metadata, and returns its picture (with the capture time) unless
/// it carries none. A DMA-BUF's fd is duplicated; shared memory is copied.
///
/// # Safety
/// `raw` is a buffer dequeued from the stream and not yet queued back.
unsafe fn read_buffer(
    raw: *mut pw::sys::pw_buffer,
    format: Option<Negotiated>,
    cursor: &CursorState,
    arrival: u64,
) -> Option<(Picture, u64)> {
    // SAFETY: (the caller's invariant) raw is a live pw_buffer; its spa_buffer and the arrays it points at are
    // PipeWire's, valid while dequeued.
    unsafe {
        let buf = (*raw).buffer;
        if buf.is_null() {
            return None;
        }
        let meta = spa::sys::spa_buffer_find_meta_data(
            buf,
            spa::sys::SPA_META_Cursor,
            std::mem::size_of::<spa::sys::spa_meta_cursor>(),
        ) as *const spa::buffer::meta::MetaCursor;
        if !meta.is_null() {
            write_cursor(cursor, &*meta);
        }
        let header = spa::sys::spa_buffer_find_meta_data(
            buf,
            spa::sys::SPA_META_Header,
            std::mem::size_of::<spa::sys::spa_meta_header>(),
        ) as *const spa::sys::spa_meta_header;
        let pts = if header.is_null() { 0 } else { (*header).pts };
        let capture_ns = if pts > 0 { pts as u64 } else { arrival };
        let format = format?;
        if (*buf).n_datas == 0 || (*buf).datas.is_null() {
            return None;
        }
        let data = &*(*buf).datas;
        let chunk = data.chunk;
        if chunk.is_null() {
            return None;
        }
        let view = BufferView {
            n_datas: (*buf).n_datas,
            data_type: data.type_,
            fd: data.fd,
            max_size: data.maxsize,
            has_data_ptr: !data.data.is_null(),
            chunk_offset: (*chunk).offset,
            chunk_size: (*chunk).size,
            chunk_stride: (*chunk).stride,
            chunk_flags: (*chunk).flags,
        };
        let pixels = match classify(&view, &format) {
            BufferKind::CursorOnly => return None,
            BufferKind::Invalid(why) => {
                tracing::debug!(why, ?view, "an unusable buffer");
                return None;
            }
            BufferKind::DmaBuf { fd, offset, stride } => {
                let fd = BorrowedFd::borrow_raw(fd);
                let owned: OwnedFd = match rustix::io::fcntl_dupfd_cloexec(fd, 3) {
                    Ok(f) => f,
                    Err(e) => {
                        tracing::debug!("dup of a DMA-BUF: {e}");
                        return None;
                    }
                };
                let size = rustix::fs::seek(&owned, rustix::fs::SeekFrom::End(0)).unwrap_or(0);
                Pixels::DmaBuf(DmaBufPlane {
                    fd: owned,
                    fourcc: format.fourcc,
                    modifier: format.modifier.unwrap_or(0),
                    offset,
                    stride,
                    size,
                })
            }
            BufferKind::Memory { offset, stride } => {
                let len = stride as usize * format.height as usize;
                let base = data.data.cast::<u8>().add(offset as usize);
                let bytes = std::slice::from_raw_parts(base, len.min((data.maxsize - offset) as usize));
                Pixels::Memory { data: bytes.to_vec(), stride }
            }
        };
        Some((Picture { width: format.width, height: format.height, pixels }, capture_ns))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pw::spa::pod::deserialize::PodDeserializer;

    fn object(bytes: &[u8]) -> Object {
        let (_, value) = PodDeserializer::deserialize_any_from(bytes).unwrap();
        let Value::Object(obj) = value else { panic!("not an object") };
        obj
    }

    fn prop(obj: &Object, key: u32) -> &Property {
        obj.properties.iter().find(|p| p.key == key).unwrap()
    }

    #[test]
    fn format_pods() {
        let dma = format_pod(2752, 2064, 120, Some(MUTTER_MODIFIER));
        let obj = object(&dma);
        assert_eq!(
            (obj.type_, obj.id),
            (SpaTypes::ObjectParamFormat.as_raw(), spa::param::ParamType::EnumFormat.as_raw())
        );
        let m = prop(&obj, FormatProperties::VideoModifier.as_raw());
        assert_eq!(m.value, Value::Long(MUTTER_MODIFIER as i64));
        assert!(m.flags.contains(PropertyFlags::MANDATORY));
        assert_eq!(
            prop(&obj, FormatProperties::VideoSize.as_raw()).value,
            Value::Rectangle(Rectangle { width: 2752, height: 2064 })
        );
        let Value::Choice(ChoiceValue::Fraction(Choice(_, ChoiceEnum::Range { default, max, .. }))) =
            prop(&obj, FormatProperties::VideoMaxFramerate.as_raw()).value
        else {
            panic!("maxFramerate")
        };
        assert_eq!((default.num, max.num), (120, 120));
        assert!(format_has_modifier(&dma));
        let shm = format_pod(2752, 2064, 120, None);
        assert!(!format_has_modifier(&shm));
        assert!(Pod::from_bytes(&dma).is_some() && Pod::from_bytes(&shm).is_some());
        // The shared-memory format is lain-gnome's negotiating format.
        assert_eq!(
            object(&shm).properties.len(),
            object(&lain_gnome::negotiate::format_pod(2752, 2064, 120)).properties.len()
        );
    }

    #[test]
    fn buffer_and_meta_pods() {
        let obj = object(&buffers_pod(true));
        let Value::Choice(ChoiceValue::Int(Choice(_, ChoiceEnum::Flags { default, .. }))) =
            prop(&obj, spa::sys::SPA_PARAM_BUFFERS_dataType).value
        else {
            panic!("dataType")
        };
        assert_eq!(default, 1 << spa::sys::SPA_DATA_DmaBuf);
        let Value::Choice(ChoiceValue::Int(Choice(_, ChoiceEnum::Range { min, max, .. }))) =
            prop(&obj, spa::sys::SPA_PARAM_BUFFERS_buffers).value
        else {
            panic!("buffers")
        };
        assert_eq!((min, max), (3, 8), "a pool of at least three");
        let obj = object(&buffers_pod(false));
        let Value::Choice(ChoiceValue::Int(Choice(_, ChoiceEnum::Flags { default, .. }))) =
            prop(&obj, spa::sys::SPA_PARAM_BUFFERS_dataType).value
        else {
            panic!("dataType")
        };
        assert_eq!(default, (1 << spa::sys::SPA_DATA_MemFd) | (1 << spa::sys::SPA_DATA_MemPtr));
        let obj = object(&header_meta_pod());
        assert_eq!(prop(&obj, spa::sys::SPA_PARAM_META_type).value, Value::Id(Id(spa::sys::SPA_META_Header)));
    }

    fn view(data_type: u32, size: u32, stride: i32) -> BufferView {
        BufferView {
            n_datas: 1,
            data_type,
            fd: 42,
            max_size: 11008 * 2064,
            has_data_ptr: true,
            chunk_offset: 0,
            chunk_size: size,
            chunk_stride: stride,
            chunk_flags: 0,
        }
    }

    #[test]
    fn classifies_buffers() {
        let dma =
            Negotiated { width: 2752, height: 2064, fourcc: DRM_FORMAT_XRGB8888, modifier: Some(MUTTER_MODIFIER) };
        let shm = Negotiated { modifier: None, ..dma };
        let d = spa::sys::SPA_DATA_DmaBuf;
        assert_eq!(classify(&view(d, 1, 11008), &dma), BufferKind::DmaBuf { fd: 42, offset: 0, stride: 11008 });
        assert_eq!(classify(&view(d, 0, 11008), &dma), BufferKind::CursorOnly, "an empty chunk is a cursor update");
        let mut corrupt = view(d, 1, 11008);
        corrupt.chunk_flags = spa::sys::SPA_CHUNK_FLAG_CORRUPTED as i32;
        assert_eq!(classify(&corrupt, &dma), BufferKind::CursorOnly);
        assert!(matches!(classify(&view(d, 1, 11000), &dma), BufferKind::Invalid(_)), "stride");
        assert!(matches!(classify(&view(d, 1, -11008), &dma), BufferKind::Invalid(_)), "negative stride");
        let mut nofd = view(d, 1, 11008);
        nofd.fd = -1;
        assert!(matches!(classify(&nofd, &dma), BufferKind::Invalid(_)));
        assert!(matches!(classify(&view(spa::sys::SPA_DATA_MemFd, 1, 11008), &dma), BufferKind::Invalid(_)));
        let m = spa::sys::SPA_DATA_MemFd;
        assert_eq!(classify(&view(m, 1, 11008), &shm), BufferKind::Memory { offset: 0, stride: 11008 });
        let mut small = view(m, 1, 11008);
        small.max_size = 11008 * 2063;
        assert!(matches!(classify(&small, &shm), BufferKind::Invalid(_)));
        let mut unmapped = view(spa::sys::SPA_DATA_MemPtr, 1, 11008);
        unmapped.has_data_ptr = false;
        assert!(matches!(classify(&unmapped, &shm), BufferKind::Invalid(_)));
    }
}
