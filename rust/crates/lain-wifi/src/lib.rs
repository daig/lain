//! Wi-Fi transport: PSK derivation, the TLS-PSK listener and client, TCP options, the TXT record.
//!
//! Swift reference: `Packages/LainKit/Sources/LainTransport/{WiFiSecurity,NetworkStream,Discovery}.swift`,
//! `LainHostCore/Session/HostWiFiListener.swift`. Brief: `docs/LINUX-HOST-PLAN.md`, `lain-wifi`.
//!
//! Over Wi-Fi the iPad dials the host (§7.7, D29): TCP, then TLS 1.2 with only
//! `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC) under the PSK of one pairing secret, then
//! `lain-link`'s handshake, whose acceptor is `lain-host`'s.
//!
//! - [`WiFiPsk`]: a pairing secret's PSK identity and key.
//! - [`TlsPskListener`]: the TLS-PSK listener over a live [`PskTable`] (Swift: `NetworkStreamListener`).
//! - [`WiFiListener`]: the host's Wi-Fi link source, following the secret store, with a [`WiFiStatus`]
//!   watch (Swift: `HostWiFiListener`). It hands each authenticated connection to `lain-host` as a
//!   `Box<dyn lain_link::ByteStream>`.
//! - [`WiFiDialer`] and [`connect`]: the TLS client, for tests and a fake iPad, and a
//!   [`lain_link::StreamDialer`].
//! - [`LainTxt`]: the Bonjour TXT record.
//!
//! What Swift's `NetworkStream.swift` has that this crate leaves out, and why:
//! - `NetworkStream`'s callback state machine (start, ordered delivery, close once, flush-then-cancel with a
//!   deadline): a tokio stream is pulled by its reader, and `lain-link`'s channel owns the close.
//! - `NetworkPath` and its kinds (peer-to-peer, Wi-Fi, wired, loopback): [`lain_link::LinkTransport`] names
//!   the interface, and `lain-host` words the status ("LAN (<interface>)").
//! - `localNetworkDenied`, AWDL and `includePeerToPeer`, Bonjour browsing (`DiscoveredHost`,
//!   `HostDiscovery`): macOS and iPadOS only, or the client's.
//! - `WiFiLinkDialer`'s path pinning: this crate dials socket addresses, which leave nothing to resolve.
//! - The listener's Bonjour advertisement: the daemon advertises through `lain-platform`'s `Advertiser`
//!   while [`WiFiStatus::Listening`].

mod connection;
mod error;
mod host;
mod ifaddrs;
mod listener;
mod pending;
mod psk;
pub mod socket;
pub mod tls;
mod txt;

pub use connection::{TlsStream, WiFiConnection, WiFiDialer, connect};
pub use error::WiFiError;
pub use host::{WiFiListener, WiFiListenerOptions, WiFiStatus};
pub use listener::{ListenerOptions, OnAccept, REJECTIONS_BUFFER, TlsPskListener};
pub use psk::{IDENTITY_PREFIX, WiFiPsk};
pub use tls::{NegotiatedTls, PskTable};
pub use txt::LainTxt;
