//! What the session engine takes from its owner (Swift: `HostSession.Dependencies`, `HostSession.Tuning`,
//! `HostWiFiConfig`'s admission part).

use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use lain_input::InputConfig;
use lain_link::HostLink;
use lain_media::PipelineOptions;
use lain_platform::HostIdentity;
use lain_proto::VersionList;

use crate::CursorWarpDetector;

/// Everything [`HostSession`](crate::HostSession) needs besides the platform, usbmuxd and the Wi-Fi streams
/// (Swift: `HostSession.Dependencies` minus the platform parts, which [`Platform`](lain_platform::Platform)
/// bundles, plus `Tuning`).
#[derive(Debug, Clone)]
pub struct HostConfig {
    /// The protocol versions offered (PROTOCOL-VERSIONING §3.2). The default is [`VersionList::offered`],
    /// which honours `LAIN_PROTOCOL_MAX`.
    pub versions: VersionList,
    /// Who this computer is (§7.7 D29): its id goes in `Pair` and, with the name, in every `HelloAck`.
    /// `None`: empty ids (Swift: `identity` nil).
    pub identity: Option<HostIdentity>,
    /// The video path's tuning; its `average_bit_rate` (60 Mbps) is also `HelloAck.bitrate`.
    pub video: PipelineOptions,
    /// How the client's input is mapped (`lain-input`).
    pub input: InputConfig,
    /// Admission of the network links handed in (Swift: `HostWiFiConfig`'s `usbPreference`,
    /// `helloTimeout`, `busyDrain`).
    pub wifi: WifiAdmission,
    pub tuning: Tuning,
    /// How long lain's display outlives a session whose link went away (the iPad's app left the screen, the
    /// cable came out), so that the iPad's next session of the same size takes it back ([`crate::keeper`]).
    /// Zero, the default here as in Swift, removes it at once; `lain-hostd` keeps it 30 s by default.
    pub display_keep_alive: Duration,
    /// After the owner stops lain's display on the desktop (GNOME's sharing indicator), bring video back by
    /// itself: the session's link is closed, and the iPad's reconnect starts a fresh one. Off, as in Swift, here;
    /// on in `lain-hostd` (the developer: Stop has no use for this app). At most once per
    /// [`RESUME_AFTER_STOP_MIN_GAP`](crate::RESUME_AFTER_STOP_MIN_GAP), so a desktop that keeps stopping it
    /// doesn't loop.
    pub resume_after_stop: bool,
}

impl Default for HostConfig {
    fn default() -> Self {
        Self {
            versions: VersionList::offered().clone(),
            identity: None,
            video: PipelineOptions::default(),
            input: InputConfig::default(),
            wifi: WifiAdmission::default(),
            tuning: Tuning::default(),
            display_keep_alive: Duration::ZERO,
            resume_after_stop: false,
        }
    }
}

/// How links handed in from the Wi-Fi listener are admitted (Swift: the admission fields of
/// `HostWiFiConfig`; the listener's own fields belong to `lain-wifi`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WifiAdmission {
    /// USB wins (decision 8): a network link from an iPad that is attached over USB is told `busy` for this
    /// long after its USB attempt began: its attach, its first dial if it waited its turn behind another
    /// device, or the end of its last USB session. Hand-over re-dials between devices that both fail over
    /// USB don't restart it. After it, USB counts as broken and the network link is let in.
    pub usb_preference: Duration,
    /// How long an accepted link may take to send `Hello` (`HostLink::HANDSHAKE_TIMEOUT` over USB).
    pub hello_timeout: Duration,
    /// After `Error(busy)` the link is closed only after this, so the client reads the error first.
    pub busy_drain: Duration,
}

impl Default for WifiAdmission {
    fn default() -> Self {
        Self {
            usb_preference: Duration::from_secs(5),
            hello_timeout: HostLink::HANDSHAKE_TIMEOUT,
            busy_drain: Duration::from_millis(200),
        }
    }
}

/// A test hook (Swift: `Tuning.afterRegistering`, internal there).
pub type Hook = Arc<dyn Fn() -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>;

/// Timings (Swift: `HostSession.Tuning`).
#[derive(Clone)]
pub struct Tuning {
    /// Real-cursor sampling for warp detection (§5.4); also how often `lain-input`'s held-back scroll stop
    /// is polled.
    pub cursor_sample_hz: f64,
    /// Quick retries right after attach (the client's listener may lag the attach), then slow ones for as
    /// long as the iPad stays attached (lain may not be open yet).
    pub fast_retries: u32,
    pub fast_retry_interval: Duration,
    pub slow_retry_interval: Duration,
    /// If usbmuxd's event stream ends, or the daemon isn't running, listen again after this. On Linux the
    /// daemon exits after the last iOS device is unplugged (SL4), so this is how a newly plugged iPad is
    /// noticed.
    pub usbmux_retry_interval: Duration,
    /// `PowerBackend::user_activity` at most this often (§5.5 Power).
    pub user_activity_interval_ns: u64,
    pub warp: CursorWarpDetector,
    /// A session ended by a capture error lets the next one start at once the first time; each further one
    /// in a row waits this long, doubling (capped at 32×), over either transport. Plugging in the iPad whose
    /// sessions failed resets the count, and it is dialed at once, ahead of a device that is only waiting
    /// the backoff out.
    pub capture_retry_interval: Duration,
    /// lain on the iPad closing realtime right after our `ChannelHello` this many times in a row is taken for
    /// an app that speaks another protocol (a v1 app closes without answering).
    pub closes_before_update_hint: u32,
    /// Tests only: runs right after a USB connection is registered as the live session.
    #[doc(hidden)]
    pub after_registering: Option<Hook>,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            cursor_sample_hz: 60.0,
            fast_retries: 20,
            fast_retry_interval: Duration::from_millis(100),
            slow_retry_interval: Duration::from_secs(1),
            usbmux_retry_interval: Duration::from_secs(1),
            user_activity_interval_ns: 1_000_000_000,
            warp: CursorWarpDetector::default(),
            capture_retry_interval: Duration::from_secs(1),
            closes_before_update_hint: 3,
            after_registering: None,
        }
    }
}

impl fmt::Debug for Tuning {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Tuning")
            .field("cursor_sample_hz", &self.cursor_sample_hz)
            .field("fast_retries", &self.fast_retries)
            .field("fast_retry_interval", &self.fast_retry_interval)
            .field("slow_retry_interval", &self.slow_retry_interval)
            .field("usbmux_retry_interval", &self.usbmux_retry_interval)
            .field("user_activity_interval_ns", &self.user_activity_interval_ns)
            .field("warp", &self.warp)
            .field("capture_retry_interval", &self.capture_retry_interval)
            .field("closes_before_update_hint", &self.closes_before_update_hint)
            .finish_non_exhaustive()
    }
}
