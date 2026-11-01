//! Why a link or a connection failed. Swift: `TransportError` (`ByteStream.swift`).

use std::fmt;
use std::sync::Arc;

use lain_platform::PlatformError;
use lain_proto::VersionList;

/// Why a link, a handshake or a channel operation failed. Swift: `TransportError`.
///
/// Intended differences from Swift:
/// - `posix(String, Int32)` is [`Io`](Self::Io), carrying `std::io::Error`'s text: tokio's errors don't
///   always have an errno.
/// - Two cases Swift expresses as "any other `Error`" get their own variants, so that the type stays
///   `Clone + PartialEq`: [`Secrets`](Self::Secrets) (the secret store failed; Swift rethrows the
///   Keychain's error) and [`Dial`](Self::Dial) (the [`StreamDialer`](crate::StreamDialer) failed; Swift
///   rethrows the dialer's error).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TransportError {
    /// A read or write on the stream failed.
    #[error("i/o: {0}")]
    Io(String),
    /// The connection closed (locally, by the peer, or after bytes that don't parse).
    #[error("closed")]
    Closed,
    #[error("timed out")]
    Timeout,
    #[error("authentication failed")]
    AuthenticationFailed,
    /// The peer runs a lain from before version negotiation (legacy): `remote` is its version when its
    /// frame named one, 0 when it answered ours with `Error(versionMismatch)`.
    #[error("the peer speaks protocol v{remote}, from before version negotiation")]
    VersionMismatch { remote: u8 },
    /// Both sides negotiate, but no version is common to both (PROTOCOL-VERSIONING §3.2).
    #[error("no common protocol version: this side {local}, the peer {peer}")]
    NoCommonVersion { local: VersionList, peer: VersionList },
    #[error("unexpected: {0}")]
    UnexpectedMessage(String),
    /// No stored secret, and pairing isn't allowed.
    #[error("no pairing secret")]
    NoSecret,
    /// The secret store failed (Swift: the store's own error, rethrown).
    #[error("secret store: {0}")]
    Secrets(#[from] PlatformError),
    /// The stream dialer failed (Swift: the dialer's own error, rethrown).
    #[error("dial: {0}")]
    Dial(DialError),
}

impl From<std::io::Error> for TransportError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e.to_string())
    }
}

/// A [`StreamDialer`](crate::StreamDialer)'s own error, kept whole so the caller can inspect it
/// (`downcast_ref::<UsbMuxError>()`, say). Equal when their texts are.
#[derive(Clone)]
pub struct DialError(Arc<dyn std::error::Error + Send + Sync + 'static>);

impl DialError {
    pub fn new(error: impl std::error::Error + Send + Sync + 'static) -> Self {
        Self(Arc::new(error))
    }

    /// The dialer's error as its own type.
    pub fn downcast_ref<E: std::error::Error + 'static>(&self) -> Option<&E> {
        self.0.downcast_ref()
    }

    pub fn inner(&self) -> &(dyn std::error::Error + Send + Sync + 'static) {
        &*self.0
    }
}

impl fmt::Debug for DialError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&*self.0, f)
    }
}

impl fmt::Display for DialError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&*self.0, f)
    }
}

impl PartialEq for DialError {
    fn eq(&self, other: &Self) -> bool {
        self.0.to_string() == other.0.to_string()
    }
}

impl Eq for DialError {}

/// Why [`MessageChannel::send`](crate::MessageChannel::send) didn't queue a message.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SendError {
    /// The message doesn't exist at the channel's version (callers check `Link::supports` first, so this
    /// is a bug). Swift returns false and asserts in Debug builds; Rust returns this and logs, since a
    /// test build is a Debug build.
    #[error("not sent: {0}")]
    Unrepresentable(String),
    /// The channel is closed or closing. Swift drops such writes silently.
    #[error("channel closed")]
    Closed,
}
