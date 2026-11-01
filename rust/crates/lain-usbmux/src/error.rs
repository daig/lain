use std::io;
use std::path::PathBuf;
use std::time::Duration;

/// What can go wrong talking to usbmuxd (Swift: `USBMuxError`).
///
/// Intended difference: Swift folds every POSIX failure into `posix(String, Int32)`. Here, the daemon not
/// running is its own case, [`UsbMuxError::Unavailable`], because on Linux it is the normal state with no iOS
/// device attached: libimobiledevice's usbmuxd is started by udev for the first device and exits after the
/// last (`usbmuxd --systemd` implies `--enable-exit`), and it doesn't unlink its socket on exit, so the path is
/// either missing (`NotFound`) or stale (`ConnectionRefused`). Any other failure to connect (a permission
/// error, say) is [`UsbMuxError::Io`] with op `"connect"`. Swift's receive timeout, also a `posix` error there,
/// is [`UsbMuxError::Timeout`].
#[derive(Debug, thiserror::Error)]
pub enum UsbMuxError {
    /// The daemon isn't running: connecting to its socket failed with `NotFound` (no socket file) or
    /// `ConnectionRefused` (a stale one). Nothing else is reported this way.
    #[error("usbmuxd is not running at {}: {source}", path.display())]
    Unavailable { path: PathBuf, source: io::Error },
    /// Any other socket error, including any other failure to connect (op `"connect"`) (Swift: `posix`).
    #[error("usbmuxd {op}: {source}")]
    Io { op: &'static str, source: io::Error },
    /// A packet that isn't what the protocol allows (Swift: `protocolError`).
    #[error("usbmuxd protocol error: {0}")]
    Protocol(String),
    /// The daemon's non-zero `Result` number (Swift: `result(Int)`); see [`crate::protocol::result`].
    #[error("usbmuxd result {0}")]
    Result(u64),
    /// The daemon closed the connection (Swift: `closed`).
    #[error("usbmuxd closed the connection")]
    Closed,
    /// No reply within the client's timeout (Swift: `posix("recv timeout", EAGAIN)`).
    #[error("usbmuxd did not answer within {0:?}")]
    Timeout(Duration),
}

impl UsbMuxError {
    /// The device refused the connection: nothing listens on the port (an iPhone, or lain not running).
    pub fn is_connection_refused(&self) -> bool {
        matches!(self, Self::Result(crate::protocol::result::CONNECTION_REFUSED))
    }

    pub(crate) fn io(op: &'static str, source: io::Error) -> Self {
        Self::Io { op, source }
    }
}
