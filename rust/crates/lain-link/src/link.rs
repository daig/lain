//! A session's three connections, and the dialer role. Swift: `Link.swift` (`Link`, `LinkDialer`,
//! `HostLink`).

use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use lain_platform::SecretStore;
use lain_proto::{
    ChannelAccept, ChannelHello, ConnectionKind, Envelope, ErrorCode, Hello, Message, Pair, ProtocolFeature,
    VersionList,
};

use crate::{ByteStream, ChannelAuth, LinkTransport, MessageChannel, StreamDialer, TransportError};

/// The three authenticated connections of one session (§7.1), at the version both sides negotiated. Swift:
/// `Link`. Dropping it closes all three.
#[derive(Debug)]
pub struct Link {
    pub session_token: [u8; ChannelHello::TOKEN_SIZE],
    pub realtime: MessageChannel,
    pub video: MessageChannel,
    pub audio: MessageChannel,
    /// What the link runs over, read from its realtime connection (§7.7).
    pub transport: LinkTransport,
    /// The negotiated protocol version (PROTOCOL-VERSIONING §3.2).
    pub version: u8,
    /// The versions the peer supports; `None` for a link made without a handshake (tests).
    pub peer_versions: Option<VersionList>,
    /// The versions this side offered.
    pub local_versions: VersionList,
}

impl Link {
    /// Channels still in the handshake layer (a link made without one, in tests) are set to `version`.
    /// Swift defaults `version` to the newest and `localVersions` to `VersionList.offered`; here both are
    /// explicit.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        session_token: [u8; ChannelHello::TOKEN_SIZE],
        realtime: MessageChannel,
        video: MessageChannel,
        audio: MessageChannel,
        transport: LinkTransport,
        version: u8,
        peer_versions: Option<VersionList>,
        local_versions: VersionList,
    ) -> Self {
        for channel in [&realtime, &video, &audio] {
            if channel.version().is_none() {
                channel.set_version(version);
            }
        }
        Self { session_token, realtime, video, audio, transport, version, peer_versions, local_versions }
    }

    pub fn channels(&self) -> [&MessageChannel; 3] {
        [&self.realtime, &self.video, &self.audio]
    }

    pub fn channels_mut(&mut self) -> [&mut MessageChannel; 3] {
        [&mut self.realtime, &mut self.video, &mut self.audio]
    }

    /// Whether the session's version has `feature` (PROTOCOL-VERSIONING §3.4).
    pub fn supports(&self, feature: ProtocolFeature) -> bool {
        feature.is_supported(self.version)
    }

    /// The peer runs an older version than this side's newest: the features it misses.
    pub fn older_peer_misses(&self) -> Vec<ProtocolFeature> {
        ProtocolFeature::missing(self.version, self.local_versions.newest())
    }

    pub fn close(&self) {
        self.channels().iter().for_each(|c| c.close());
    }
}

/// A [`LinkDialer`] hook run on each new stream before its channel starts. Swift: `LinkDialer.configure`.
pub type Configure<S> = Arc<dyn Fn(ConnectionKind, &S) + Send + Sync>;

/// The dialer role (§7.6, §7.7 D29): opens realtime, video and audio and sends `ChannelHello` on each, plus
/// `Pair` on realtime when pairing (USB only). Over USB the host dials; over Wi-Fi the client does. The
/// acceptor answers only to refuse (an `Error`, then a close); the handshake reply that follows (`Hello`
/// over USB, `HelloAck` over Wi-Fi) is read with [`reply`](Self::reply). Swift: `LinkDialer`.
pub struct LinkDialer<D: StreamDialer> {
    pub dialer: D,
    pub label: String,
    /// Runs on each new stream before its channel starts (`HostLink`: the video socket's small send
    /// buffer, §7.3).
    pub configure: Option<Configure<D::Stream>>,
    /// What the link runs over; `None`: what the realtime stream says ([`ByteStream::link_transport`]).
    /// Swift takes a function of the realtime stream; every caller of it passes a constant.
    pub transport: Option<LinkTransport>,
    /// The versions offered in `ChannelHello`.
    pub versions: VersionList,
    /// How long each connection's `ChannelAccept` may take.
    pub accept_timeout: Duration,
}

impl<D: StreamDialer> LinkDialer<D> {
    /// Swift's default accept timeout.
    pub const ACCEPT_TIMEOUT: Duration = Duration::from_secs(5);

    /// Label `lain.link`, [`VersionList::offered`], no hook, the stream's own transport, a 5 s accept timeout.
    pub fn new(dialer: D) -> Self {
        Self {
            dialer,
            label: "lain.link".into(),
            configure: None,
            transport: None,
            versions: VersionList::offered().clone(),
            accept_timeout: Self::ACCEPT_TIMEOUT,
        }
    }

    pub fn label(mut self, label: impl Into<String>) -> Self {
        self.label = label.into();
        self
    }

    pub fn versions(mut self, versions: VersionList) -> Self {
        self.versions = versions;
        self
    }

    pub fn transport(mut self, transport: LinkTransport) -> Self {
        self.transport = Some(transport);
        self
    }

    pub fn accept_timeout(mut self, timeout: Duration) -> Self {
        self.accept_timeout = timeout;
        self
    }

    pub fn configure(mut self, configure: impl Fn(ConnectionKind, &D::Stream) + Send + Sync + 'static) -> Self {
        self.configure = Some(Arc::new(configure));
        self
    }

    /// A new session authenticated with a stored secret.
    pub async fn open(&self, secret: &[u8]) -> Result<Link, TransportError> {
        self.open_with(secret, None).await
    }

    /// USB pairing (D23): realtime's hello carries the all-zero HMAC and is followed by `pair`; video and
    /// audio authenticate with its secret. Swift: `open(pairing:)`.
    pub async fn open_pairing(&self, pair: &Pair) -> Result<Link, TransportError> {
        self.open_with(&pair.secret, Some(pair)).await
    }

    async fn open_with(&self, secret: &[u8], pair: Option<&Pair>) -> Result<Link, TransportError> {
        let token = ChannelAuth::random_bytes::<{ ChannelHello::TOKEN_SIZE }>();
        // A failure drops whatever was opened, which closes it.
        let (realtime, transport) = self.connect(ConnectionKind::Realtime, token, secret, pair).await?;
        let (video, _) = self.connect(ConnectionKind::Video, token, secret, pair).await?;
        let (audio, _) = self.connect(ConnectionKind::Audio, token, secret, pair).await?;
        let mut channels = [realtime, video, audio];
        // Every connection is answered with the same version, or the link fails (PROTOCOL-VERSIONING §3.2).
        let mut agreed: Option<(u8, VersionList)> = None;
        for channel in &mut channels {
            let (version, peer) = self.accepted(channel).await?;
            if let Some((first, _)) = &agreed
                && *first != version
            {
                return Err(TransportError::UnexpectedMessage(format!("connections answered v{first} and v{version}")));
            }
            channel.set_version(version);
            agreed = Some((version, peer));
        }
        let (version, peer) = agreed.expect("three connections");
        let [realtime, video, audio] = channels;
        Ok(Link::new(token, realtime, video, audio, transport, version, Some(peer), self.versions.clone()))
    }

    async fn connect(
        &self,
        kind: ConnectionKind,
        token: [u8; ChannelHello::TOKEN_SIZE],
        secret: &[u8],
        pair: Option<&Pair>,
    ) -> Result<(MessageChannel, LinkTransport), TransportError> {
        let stream = self.dialer.dial(kind).await?;
        if let Some(configure) = &self.configure {
            configure(kind, &stream);
        }
        let transport = self.transport.clone().unwrap_or_else(|| stream.link_transport());
        let channel = MessageChannel::new(stream, format!("{}.{}", self.label, kind_name(kind)));
        let sent = match pair {
            Some(pair) if kind == ConnectionKind::Realtime => {
                let hello = ChannelAuth::hello(kind, token, None, &self.versions);
                channel.send(&Message::ChannelHello(hello)).and_then(|()| channel.send(&Message::Pair(pair.clone())))
            }
            _ => channel.send(&Message::ChannelHello(ChannelAuth::hello(kind, token, Some(secret), &self.versions))),
        };
        sent.map_err(|_| TransportError::Closed)?;
        Ok((channel, transport))
    }

    /// The acceptor's answer on one connection: the chosen version, which must be the highest common one by
    /// this side's own count. A refusal fails: `Error(authenticationFailed)` as `AuthenticationFailed`; no
    /// common version as `NoCommonVersion`; a legacy peer's `Error(versionMismatch)` (or a frame in its own
    /// version) as `VersionMismatch`; any other `Error` as `UnexpectedMessage`.
    async fn accepted(&self, channel: &mut MessageChannel) -> Result<(u8, VersionList), TransportError> {
        let env = channel.recv_timeout(self.accept_timeout).await?;
        match env.message {
            Message::ChannelAccept(ChannelAccept { chosen, versions }) => {
                if chosen == 0 {
                    return Err(TransportError::NoCommonVersion { local: self.versions.clone(), peer: versions });
                }
                if Some(chosen) != self.versions.highest_common(&versions) {
                    return Err(TransportError::UnexpectedMessage(format!(
                        "ChannelAccept chose v{chosen} of {versions}, offered {}",
                        self.versions
                    )));
                }
                Ok((chosen, versions))
            }
            Message::Error(e) if e.code == ErrorCode::AUTHENTICATION_FAILED => Err(TransportError::AuthenticationFailed),
            // A legacy acceptor, answering in our framing.
            Message::Error(e) if e.code == ErrorCode::VERSION_MISMATCH => {
                Err(TransportError::VersionMismatch { remote: 0 })
            }
            Message::Error(e) => Err(TransportError::UnexpectedMessage(format!("Error({}): {}", e.code, e.message))),
            other => Err(TransportError::UnexpectedMessage(format!("{} instead of ChannelAccept", other.ty()))),
        }
    }

    /// The peer's first message on realtime. A refusal fails: `Error(authenticationFailed)` as
    /// `AuthenticationFailed`; `Error(versionMismatch)`, or a close after a frame in another major version,
    /// as `VersionMismatch` (§7.5). Anything else, other `Error`s included, is returned.
    pub async fn reply(link: &mut Link, timeout: Duration) -> Result<Envelope, TransportError> {
        let first = link.realtime.recv_timeout(timeout).await?;
        if let Message::Error(e) = &first.message {
            if e.code == ErrorCode::AUTHENTICATION_FAILED {
                return Err(TransportError::AuthenticationFailed);
            }
            if e.code == ErrorCode::VERSION_MISMATCH {
                // A legacy peer: its version is unknown.
                return Err(TransportError::VersionMismatch { remote: 0 });
            }
        }
        Ok(first)
    }
}

impl<D: StreamDialer + fmt::Debug> fmt::Debug for LinkDialer<D> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LinkDialer")
            .field("dialer", &self.dialer)
            .field("label", &self.label)
            .field("versions", &self.versions)
            .finish_non_exhaustive()
    }
}

/// "realtime", "video", "audio": Swift's `"\(kind)"`, in labels and on-the-wire refusal texts.
pub(crate) fn kind_name(kind: ConnectionKind) -> &'static str {
    match kind {
        ConnectionKind::Realtime => "realtime",
        ConnectionKind::Video => "video",
        ConnectionKind::Audio => "audio",
    }
}

/// The host dials, authenticates and (over USB) pairs (§7.5 handshake steps 1–2, §7.6). Swift: `HostLink`.
pub struct HostLink;

impl HostLink {
    /// How long the client's `Hello` may take after the link is up.
    pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
    /// Video writes wait on a small kernel buffer instead of queueing below the app (§7.3). Linux doubles a
    /// requested SO_SNDBUF (its bookkeeping share), so the kernel reports twice this.
    pub const VIDEO_SEND_BUFFER: usize = 128 * 1024;

    /// Opens realtime, video and audio, sends `ChannelHello` on each, and waits for the client's `Hello`.
    /// With no stored secret, or when the client rejects ours and `allow_pairing` is set (USB), it pairs: a
    /// zero-HMAC hello plus `Pair` (carrying `host_id`, so the client can store the secret for Wi-Fi too) on
    /// realtime. The new secret is stored under `peer_id` once `Hello` arrives. The `bool` says whether this
    /// session paired (true) or authenticated with the stored secret. A client that couldn't read its secret
    /// (`Error(internal)`) fails the attempt without re-pairing: the caller just retries.
    ///
    /// On the Linux host `peer_id` is the iPad's USB serial number (`lain-host` decides). Swift defaults
    /// `hostId` to "" and `versions` to `VersionList.offered`; here they are explicit. Every stream's video
    /// connection gets [`VIDEO_SEND_BUFFER`](Self::VIDEO_SEND_BUFFER) through
    /// [`ByteStream::set_send_buffer_size`] (Swift: only a `SocketStream`'s).
    pub async fn open<D: StreamDialer>(
        dialer: D,
        secrets: &impl SecretStore,
        peer_id: &str,
        allow_pairing: bool,
        host_id: &str,
        versions: &VersionList,
    ) -> Result<(Link, Hello, bool), TransportError> {
        let stored = secrets.secret(peer_id).await?;
        if stored.is_none() && !allow_pairing {
            return Err(TransportError::NoSecret);
        }
        let links = LinkDialer::new(dialer).label("lain.host").versions(versions.clone()).configure(|kind, stream| {
            if kind == ConnectionKind::Video
                && let Err(e) = stream.set_send_buffer_size(Self::VIDEO_SEND_BUFFER)
            {
                tracing::warn!("could not set the video send buffer: {e}");
            }
        });
        match Self::attempt(&links, secrets, peer_id, stored.as_deref(), host_id).await {
            Err(TransportError::AuthenticationFailed) if stored.is_some() && allow_pairing => {
                tracing::info!("client rejected stored secret; re-pairing over USB");
                Self::attempt(&links, secrets, peer_id, None, host_id).await
            }
            result => result,
        }
    }

    /// One attempt; a failure drops (closes) the link.
    async fn attempt<D: StreamDialer>(
        links: &LinkDialer<D>,
        secrets: &impl SecretStore,
        peer_id: &str,
        stored: Option<&[u8]>,
        host_id: &str,
    ) -> Result<(Link, Hello, bool), TransportError> {
        let (mut link, new_secret) = match stored {
            Some(secret) => (links.open(secret).await?, None),
            None => {
                let pair = Pair { secret: ChannelAuth::random_bytes(), host_id: host_id.to_owned() };
                (links.open_pairing(&pair).await?, Some(pair.secret))
            }
        };
        let first = LinkDialer::<D>::reply(&mut link, Self::HANDSHAKE_TIMEOUT).await?;
        let hello = Self::hello_from(first)?;
        if let Some(secret) = &new_secret {
            secrets.set_secret(peer_id, secret).await?;
        }
        Ok((link, hello, new_secret.is_some()))
    }

    fn hello_from(first: Envelope) -> Result<Hello, TransportError> {
        match first.message {
            Message::Hello(hello) => Ok(hello),
            Message::Error(e) => Err(TransportError::UnexpectedMessage(format!("Error({}): {}", e.code, e.message))),
            other => Err(TransportError::UnexpectedMessage(other.ty().to_string())),
        }
    }
}
