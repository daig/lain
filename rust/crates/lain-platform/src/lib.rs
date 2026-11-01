//! The bridge contract between lain's platform-free core and a platform (decision L6).
//!
//! The core (`lain-link`, `lain-media`, `lain-input`, `lain-host`, …) is written against these traits
//! only; `lain-gnome`, `lain-linux-video` and `lain-linux-system` implement them for GNOME on Linux, and
//! the `fake` feature provides recording fakes for tests. Nothing here knows the wire format: the core
//! maps between these types and `lain-proto`'s messages.
//!
//! Conventions every implementation follows:
//! - Positions are **global logical pixels** (top-left origin), the space of [`Monitor::bounds`] and
//!   [`InputAction::MoveTo`]. On GNOME in logical layout mode they equal the Mac host's points.
//! - Times are nanoseconds of `CLOCK_MONOTONIC` ([`clock::now_ns`]).
//! - Async methods are declared `fn f(&self) -> impl Future<Output = T> + Send`, so their futures can be
//!   spawned on tokio's multi-thread runtime; an implementation may write them as `async fn`.
//! - Methods called from the realtime path (`InputBackend::apply`, `CursorSource::current`,
//!   `DisplayBackend::cursor_location`, `VideoSession::encode`) never block.

pub mod advertise;
pub mod clock;
pub mod cursor;
pub mod display;
pub mod error;
pub mod geometry;
pub mod identity;
pub mod input;
pub mod power;
pub mod secrets;
pub mod settings;
pub mod setup;
pub mod video;

#[cfg(feature = "fake")]
pub mod fake;

pub use advertise::{Advertiser, ServiceAd};
pub use clock::{Clock, MonotonicClock};
pub use cursor::{CursorImage, CursorSource};
pub use display::{DisplayBackend, DisplaySpec, Monitor, StreamedDisplay};
pub use error::{PlatformError, Result};
pub use geometry::{PointF, RectF};
pub use identity::HostIdentity;
pub use input::{InputAction, InputBackend, ScrollSource};
pub use power::PowerBackend;
pub use secrets::SecretStore;
pub use settings::{InputSettings, SettingsSource};
pub use setup::{Requirement, RequirementState, SetupReport, SetupSource};
pub use video::{
    Chroma, ColorTags, EncodeConfig, EncodeRequest, EncodedFrame, StreamInfo, VideoBackend, VideoEvent, VideoSession,
};

/// Everything the session engine (`lain-host`) needs from a platform, as one bundle of associated types
/// (static dispatch). Advertising and autostart aren't here: the daemon drives them directly.
pub trait Platform: Send + Sync + 'static {
    type Display: DisplayBackend;
    /// Captures what the display backend creates.
    type Video: VideoBackend<Source = <Self::Display as DisplayBackend>::Source>;
    type Cursor: CursorSource;
    type Input: InputBackend;
    type Power: PowerBackend;
    type Settings: SettingsSource;
    type Setup: SetupSource;
    type Secrets: SecretStore;
    type Clock: Clock;

    fn display(&self) -> &Self::Display;
    fn video(&self) -> &Self::Video;
    fn cursor(&self) -> &Self::Cursor;
    fn input(&self) -> &Self::Input;
    fn power(&self) -> &Self::Power;
    fn settings(&self) -> &Self::Settings;
    fn setup(&self) -> &Self::Setup;
    fn secrets(&self) -> &Self::Secrets;
    fn clock(&self) -> &Self::Clock;
}
