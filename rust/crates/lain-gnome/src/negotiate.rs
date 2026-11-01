//! The short-lived PipeWire consumer that gives lain's virtual monitor its mode (decision L8; spike B §1 and
//! exp8; `pwprobe.c` in C). `RecordVirtual` creates no monitor until a consumer fixes the stream's format, and
//! the monitor takes the consumer's size and `maxFramerate`. It outlives the consumer, and `lain-linux-video`
//! later connects to the same node with the same format. No Swift counterpart: `CGVirtualDisplay` takes its
//! mode from a descriptor.
//!
//! The PipeWire main loop runs on its own thread, iterated in 10 ms steps until the caller stops it.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use pipewire as pw;
use pw::spa;
use pw::spa::param::format::{FormatProperties, MediaSubtype, MediaType};
use pw::spa::param::video::{VideoFormat, VideoInfoRaw};
use pw::spa::pod::{Pod, Value, serialize::PodSerializer};
use pw::spa::utils::{Fraction, Rectangle, SpaTypes};
use tokio::sync::oneshot;

/// How long the thread waits for a format, at most, whatever the caller does.
const LIMIT: Duration = Duration::from_secs(10);

/// What the consumer and Mutter agreed on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NegotiatedFormat {
    pub width: u32,
    pub height: u32,
    /// `maxFramerate`: the virtual monitor's refresh rate.
    pub max_framerate: (u32, u32),
    /// The SPA video format (`BGRx` or `BGRA`).
    pub format: u32,
}

/// The `EnumFormat` the consumer offers, as `pwprobe.c` does: raw video, `BGRx` (or `BGRA`), exactly `width ×
/// height`, `framerate` 0/1 (variable, as Mutter offers), and `maxFramerate` up to `fps`/1, defaulting to it.
pub fn format_pod(width: u32, height: u32, fps: u32) -> Vec<u8> {
    let object = spa::pod::object!(
        SpaTypes::ObjectParamFormat,
        spa::param::ParamType::EnumFormat,
        spa::pod::property!(FormatProperties::MediaType, Id, MediaType::Video),
        spa::pod::property!(FormatProperties::MediaSubtype, Id, MediaSubtype::Raw),
        spa::pod::property!(
            FormatProperties::VideoFormat,
            Choice,
            Enum,
            Id,
            VideoFormat::BGRx,
            VideoFormat::BGRx,
            VideoFormat::BGRA
        ),
        spa::pod::property!(FormatProperties::VideoSize, Rectangle, Rectangle { width, height }),
        spa::pod::property!(FormatProperties::VideoFramerate, Fraction, Fraction { num: 0, denom: 1 }),
        spa::pod::property!(
            FormatProperties::VideoMaxFramerate,
            Choice,
            Range,
            Fraction,
            Fraction { num: fps, denom: 1 },
            Fraction { num: 1, denom: 1 },
            Fraction { num: fps, denom: 1 }
        ),
    );
    PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &Value::Object(object))
        .expect("a format pod always serializes")
        .0
        .into_inner()
}

/// A running negotiation. Dropping it (or [`finish`](Self::finish)) disconnects the consumer.
#[derive(Debug)]
pub struct Negotiation {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Negotiation {
    /// Disconnects the consumer and waits (off the async runtime) for its thread to end.
    pub async fn finish(mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = tokio::task::spawn_blocking(move || thread.join()).await;
        }
    }
}

impl Drop for Negotiation {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
    }
}

/// Connects a consumer to `node` asking for `width × height` at up to `fps`. The receiver gets the format
/// once Mutter fixes it, or why it didn't.
pub fn negotiate(
    node: u32,
    width: u32,
    height: u32,
    fps: u32,
) -> (Negotiation, oneshot::Receiver<Result<NegotiatedFormat, String>>) {
    let (tx, rx) = oneshot::channel();
    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    let thread = std::thread::Builder::new().name("lain-pw-negotiate".into()).spawn(move || {
        let mut tx = Some(tx);
        if let Err(e) = run(node, width, height, fps, &flag, &mut tx)
            && let Some(tx) = tx.take()
        {
            let _ = tx.send(Err(e));
        }
    });
    let thread = match thread {
        Ok(t) => Some(t),
        Err(e) => {
            tracing::warn!("can't start the PipeWire thread: {e}");
            None
        }
    };
    (Negotiation { stop, thread }, rx)
}

type Reply = Option<oneshot::Sender<Result<NegotiatedFormat, String>>>;

fn run(node: u32, width: u32, height: u32, fps: u32, stop: &AtomicBool, tx: &mut Reply) -> Result<(), String> {
    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None).map_err(|e| format!("PipeWire main loop: {e}"))?;
    let context = pw::context::ContextRc::new(&mainloop, None).map_err(|e| format!("PipeWire context: {e}"))?;
    let core = context.connect_rc(None).map_err(|e| format!("connecting to PipeWire: {e}"))?;
    let stream = pw::stream::StreamBox::new(
        &core,
        "lain-negotiate",
        pw::properties::properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
        },
    )
    .map_err(|e| format!("PipeWire stream: {e}"))?;
    let outcome: Rc<RefCell<Option<Result<NegotiatedFormat, String>>>> = Rc::new(RefCell::new(None));
    let on_format = outcome.clone();
    let on_state = outcome.clone();
    let _listener = stream
        .add_local_listener_with_user_data(())
        .param_changed(move |_, _, id, param| {
            let Some(param) = param else { return };
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            let mut info = VideoInfoRaw::new();
            if info.parse(param).is_ok() {
                let size = info.size();
                let max = info.max_framerate();
                on_format.borrow_mut().get_or_insert(Ok(NegotiatedFormat {
                    width: size.width,
                    height: size.height,
                    max_framerate: (max.num, max.denom),
                    format: info.format().as_raw(),
                }));
            }
        })
        .state_changed(move |_, _, _, new| {
            if let pw::stream::StreamState::Error(e) = new {
                on_state.borrow_mut().get_or_insert(Err(format!("PipeWire stream error: {e}")));
            }
        })
        .process(|stream, _| {
            // Buffers aren't wanted: hand each back at once (dropping it requeues it).
            let _ = stream.dequeue_buffer();
        })
        .register()
        .map_err(|e| format!("PipeWire listener: {e}"))?;
    let bytes = format_pod(width, height, fps);
    let pod = Pod::from_bytes(&bytes).ok_or("the format pod doesn't parse")?;
    stream
        .connect(spa::utils::Direction::Input, Some(node), pw::stream::StreamFlags::AUTOCONNECT, &mut [pod])
        .map_err(|e| format!("connecting to node {node}: {e}"))?;
    let deadline = Instant::now() + LIMIT;
    while !stop.load(Ordering::Acquire) && Instant::now() < deadline {
        mainloop.loop_().iterate(pw::loop_::Timeout::Finite(Duration::from_millis(10)));
        if let Some(result) = outcome.borrow_mut().take()
            && let Some(tx) = tx.take()
        {
            let _ = tx.send(result);
        }
    }
    if let Some(tx) = tx.take() {
        let _ = tx.send(Err(format!("node {node} fixed no format within {LIMIT:?}")));
    }
    let _ = stream.disconnect();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use pw::spa::pod::deserialize::PodDeserializer;
    use pw::spa::pod::{ChoiceValue, Property};
    use pw::spa::utils::{Choice, ChoiceEnum, Id};

    fn prop(props: &[Property], key: FormatProperties) -> &Value {
        &props.iter().find(|p| p.key == key.as_raw()).unwrap().value
    }

    #[test]
    fn the_format_pod_asks_for_the_size_and_max_framerate() {
        let bytes = format_pod(2752, 2064, 120);
        let (_, value) = PodDeserializer::deserialize_any_from(&bytes).unwrap();
        let Value::Object(obj) = value else { panic!("not an object") };
        assert_eq!(obj.type_, SpaTypes::ObjectParamFormat.as_raw());
        assert_eq!(obj.id, spa::param::ParamType::EnumFormat.as_raw());
        let p = &obj.properties;
        assert_eq!(prop(p, FormatProperties::MediaType), &Value::Id(Id(MediaType::Video.as_raw())));
        assert_eq!(prop(p, FormatProperties::MediaSubtype), &Value::Id(Id(MediaSubtype::Raw.as_raw())));
        assert_eq!(prop(p, FormatProperties::VideoSize), &Value::Rectangle(Rectangle { width: 2752, height: 2064 }));
        assert_eq!(prop(p, FormatProperties::VideoFramerate), &Value::Fraction(Fraction { num: 0, denom: 1 }));
        let Value::Choice(ChoiceValue::Fraction(Choice(_, ChoiceEnum::Range { default, min, max }))) =
            prop(p, FormatProperties::VideoMaxFramerate)
        else {
            panic!("maxFramerate isn't a range")
        };
        assert_eq!((default.num, min.num, max.num), (120, 1, 120));
        let Value::Choice(ChoiceValue::Id(Choice(_, ChoiceEnum::Enum { default, alternatives }))) =
            prop(p, FormatProperties::VideoFormat)
        else {
            panic!("format isn't an enum")
        };
        assert_eq!(default.0, VideoFormat::BGRx.as_raw());
        assert!(alternatives.contains(&Id(VideoFormat::BGRA.as_raw())));
        assert!(Pod::from_bytes(&bytes).is_some());
    }
}
