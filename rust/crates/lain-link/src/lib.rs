//! Sessions over any byte stream: message channels, channel auth, the dialer and acceptor roles, pairing.
//!
//! Swift reference: `Packages/LainKit/Sources/LainTransport/{Link,MessageChannel,Security,VersionGap,ByteStream,MemoryStream}.swift`.
//! Brief: `docs/LINUX-HOST-PLAN.md`, `lain-link`.
//!
//! - [`MessageChannel`]: framed messages over a [`ByteStream`] (a usbmuxd pipe, TCP, TLS, memory), starting
//!   in the handshake layer, then at the negotiated version.
//! - [`ChannelAuth`], [`PairingAccounts`]: the `ChannelHello` HMAC and the secret-store accounts.
//! - [`LinkDialer`] and [`HostLink`]: the dialer role (the host over USB, the client over Wi-Fi), with USB
//!   pairing and re-pairing.
//! - [`LinkAcceptor`]: the acceptor role (the host over Wi-Fi, the client over USB), grouping three
//!   connections into a [`Link`]; [`ClientLinkListener`] is the client's USB listener on it.
//! - [`VersionGap`]: which side to update when no version is common.
//!
//! Intended differences from Swift, in general (each item says its own):
//! - Callbacks and dispatch queues become tokio tasks and channels: a channel has a reader task and a
//!   writer task; an acceptor delivers through [`AcceptorEvents`]. Nothing outlives a close, a cancel or a
//!   drop (beyond [`CLOSE_LINGER`] for a write in progress).
//! - Swift's default arguments (`versions: nil` meaning `VersionList.offered`, `hostId: ""`) are explicit.
//! - Secrets are read through the async [`lain_platform::SecretStore`].

mod acceptor;
mod channel;
mod error;
mod link;
mod security;
mod stream;
mod version_gap;

pub use acceptor::{
    AcceptedLink, AcceptorEvents, AcceptorOptions, ClientLinkListener, LinkAcceptor, PairStore, Pairing,
};
pub use channel::{CLOSE_LINGER, ChannelOptions, ChannelSender, CloseReason, INBOUND_BUFFER, MessageChannel};
pub use error::{DialError, SendError, TransportError};
pub use link::{Configure, HostLink, Link, LinkDialer};
pub use security::{ChannelAuth, PairingAccounts};
pub use stream::{
    BoundStream, ByteStream, LinkTransport, MEMORY_STREAM_BUFFER, MemoryConnection, MemoryDialer, StreamDialer,
    memory_pair,
};
pub use version_gap::VersionGap;
