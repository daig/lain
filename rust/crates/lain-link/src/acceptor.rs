//! The acceptor role, and the client's USB listener built on it. Swift: `Link.swift` (`LinkAcceptor`,
//! `AcceptedLink`, `ClientLinkListener`).

use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use lain_platform::{PlatformError, SecretStore};
use lain_proto::{
    ChannelAccept, ChannelHello, ConnectionKind, ErrorCode, ErrorMessage, Message, Pair, USB_PORT, VersionList,
};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

use crate::link::kind_name;
use crate::{
    ByteStream, ChannelAuth, ChannelOptions, Link, LinkTransport, MessageChannel, PairingAccounts, TransportError,
};

/// A link the acceptor authenticated (§7.7 D29). Swift: `AcceptedLink`.
#[derive(Debug)]
pub struct AcceptedLink {
    pub link: Link,
    /// The stored account whose secret the dialer used (on the client `"host"` or `mac:<hostId>`, on the
    /// host the iPad's USB serial), or the account a pairing stored the new secret under.
    pub peer: String,
    /// The session's secret: it verified all three `ChannelHello`s.
    pub secret: Vec<u8>,
    /// This link paired (USB only) instead of authenticating with a stored secret.
    pub paired: bool,
}

/// What a [`Pairing::Accept`] does with the new secret; an error answers `Error(internal)`.
pub type PairStore = Arc<dyn Fn(Pair) -> Pin<Box<dyn Future<Output = Result<(), PlatformError>> + Send>> + Send + Sync>;

/// Whether an acceptor pairs. Swift: `LinkAcceptor.Pairing`.
#[derive(Clone)]
pub enum Pairing {
    /// A zero-HMAC hello is refused: wireless never pairs (D13).
    Refuse,
    /// USB only (D23): a zero-HMAC realtime hello plus `Pair` is accepted. `store` persists the secret; the
    /// link's peer is `peer`.
    Accept { peer: String, store: PairStore },
}

impl Pairing {
    pub fn accept<F, Fut>(peer: impl Into<String>, store: F) -> Self
    where
        F: Fn(Pair) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<(), PlatformError>> + Send + 'static,
    {
        Self::Accept { peer: peer.into(), store: Arc::new(move |pair| Box::pin(store(pair))) }
    }

    /// The client's USB pairing: [`PairingAccounts::store_pairing`] under `peer` (and `mac:<hostId>`).
    pub fn client<S: SecretStore + Clone>(secrets: S, peer: impl Into<String>) -> Self {
        let peer = peer.into();
        let account = peer.clone();
        Self::accept(peer, move |pair| {
            let secrets = secrets.clone();
            let account = account.clone();
            async move { PairingAccounts::store_pairing(&secrets, &pair, &account).await }
        })
    }
}

impl fmt::Debug for Pairing {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Refuse => f.write_str("Refuse"),
            Self::Accept { peer, .. } => f.debug_struct("Accept").field("peer", peer).finish_non_exhaustive(),
        }
    }
}

/// How a [`LinkAcceptor`] decides. Swift: `LinkAcceptor.init`'s parameters.
#[derive(Debug, Clone)]
pub struct AcceptorOptions {
    /// Tried first, with the one read USB always made (the client's `"host"`); if that read fails the
    /// connection gets `Error(internal)`, so the dialer retries instead of re-pairing. Every other stored
    /// account is a further candidate, listed with `all_secrets()`, whose failure is only logged. Without a
    /// primary account (the host), `all_secrets()` is the read that must work. `AuthenticationFailed` thus
    /// always means "read fine, nothing matched".
    pub primary_account: Option<String>,
    pub pairing: Pairing,
    pub label: String,
    /// What an accepted link runs over; `None`: what its realtime stream says
    /// ([`ByteStream::link_transport`]). Swift takes a function of the stream; every caller passes a
    /// constant.
    pub transport: Option<LinkTransport>,
    /// What this side supports. Each authenticated connection is answered with `ChannelAccept`: the highest
    /// version common to both lists, or 0 and a close.
    pub versions: VersionList,
}

impl Default for AcceptorOptions {
    /// No primary account, pairing refused, [`VersionList::offered`]: the host's Wi-Fi acceptor.
    fn default() -> Self {
        Self {
            primary_account: None,
            pairing: Pairing::Refuse,
            label: "lain.acceptor".into(),
            transport: None,
            versions: VersionList::offered().clone(),
        }
    }
}

/// What a [`LinkAcceptor`] delivers. Swift: its `onLink` and `onReject` callbacks.
#[derive(Debug)]
pub struct AcceptorEvents {
    /// Complete links. Once delivered a link is the consumer's: what happens to an earlier link is its
    /// policy.
    pub links: mpsc::UnboundedReceiver<AcceptedLink>,
    /// Refused connections: `VersionMismatch` (a legacy peer) or `NoCommonVersion` (the peer runs another
    /// lain: worth telling the owner), `AuthenticationFailed`, `UnexpectedMessage`, or the secret store's
    /// error (`Secrets`).
    pub rejections: mpsc::UnboundedReceiver<TransportError>,
}

struct Session {
    token: [u8; ChannelHello::TOKEN_SIZE],
    secret: Vec<u8>,
    peer: String,
    paired: bool,
    /// The negotiated version, and the dialer's list that video and audio must repeat.
    version: u8,
    peer_versions: VersionList,
    realtime: MessageChannel,
    video: Option<MessageChannel>,
    audio: Option<MessageChannel>,
}

struct Waiting {
    id: u64,
    hello: ChannelHello,
    channel: MessageChannel,
}

#[derive(Default)]
struct State {
    cancelled: bool,
    /// Sessions whose realtime is in, waiting for video and audio.
    pending: Vec<Session>,
    /// Video/audio connections that arrived before their realtime connection.
    waiting: Vec<Waiting>,
    next_waiting_id: u64,
    /// Tokens of delivered and dropped sessions, newest last.
    finished: VecDeque<[u8; ChannelHello::TOKEN_SIZE]>,
}

impl State {
    fn finish(&mut self, token: [u8; ChannelHello::TOKEN_SIZE]) {
        self.finished.push_back(token);
        if self.finished.len() > REMEMBERED_TOKENS {
            self.finished.pop_front();
        }
    }
}

/// Tokens of delivered and dropped sessions kept to close late joins; older ones fall back to the wait for
/// a realtime that never comes.
const REMEMBERED_TOKENS: usize = 64;

struct Inner<S> {
    secrets: S,
    options: AcceptorOptions,
    state: Mutex<State>,
    cancel: watch::Sender<bool>,
    links: mpsc::UnboundedSender<AcceptedLink>,
    rejections: mpsc::UnboundedSender<TransportError>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The acceptor role (§7.6, §7.7 D29). Swift: `LinkAcceptor`.
///
/// Every accepted connection must open with a valid `ChannelHello` within
/// [`HELLO_TIMEOUT`](Self::HELLO_TIMEOUT) (and, pairing, its `Pair` within the same time); the secret-store
/// reads that check it, and a pairing's store, must finish within that time too, else the connection gets
/// `Error(internal)` and [`AcceptorEvents::rejections`] a [`TransportError::Secrets`]. Realtime starts
/// a session, authenticated by a stored secret (or paired, where [`Pairing`] allows it); video and audio
/// join it by session token under that session's secret, waiting up to `HELLO_TIMEOUT` for their realtime.
/// Once all three are in, [`AcceptorEvents::links`] gets the link and the acceptor forgets the session,
/// keeping only its token (a late join is closed). A session whose video and audio don't follow its
/// realtime within `HELLO_TIMEOUT` is dropped. On a connection whose transport already authenticated one
/// pairing ([`BoundStream`](crate::BoundStream): Wi-Fi TLS-PSK), a `ChannelHello` under any other secret is
/// refused, so the HMAC and the TLS key always name the same pairing.
///
/// [`cancel`](Self::cancel), or dropping the acceptor, closes every connection not yet delivered and
/// refuses new ones; every task and timer it started ends then. Delivered links are the consumer's.
/// Must be used inside a tokio runtime.
///
/// It owns its secret store (its tasks are `'static`). `Platform::secrets()` only lends `&P::Secrets`, and
/// `lain-platform` has no `impl SecretStore for Arc<T>`, so a consumer sharing the platform's store passes
/// a small adapter over `Arc<P>` that delegates to `p.secrets()`.
pub struct LinkAcceptor<S: SecretStore> {
    inner: Arc<Inner<S>>,
}

impl<S: SecretStore> LinkAcceptor<S> {
    /// How long a connection may take to send its `ChannelHello` (and `Pair`), and a session its video and
    /// audio.
    pub const HELLO_TIMEOUT: Duration = Duration::from_secs(3);

    pub fn new(secrets: S, options: AcceptorOptions) -> (Self, AcceptorEvents) {
        let (links, links_rx) = mpsc::unbounded_channel();
        let (rejections, rejections_rx) = mpsc::unbounded_channel();
        let inner = Arc::new(Inner {
            secrets,
            options,
            state: Mutex::new(State::default()),
            cancel: watch::Sender::new(false),
            links,
            rejections,
        });
        (Self { inner }, AcceptorEvents { links: links_rx, rejections: rejections_rx })
    }

    /// Takes a connected stream (the USB listener's socket, a Wi-Fi listener's TLS connection). After
    /// [`cancel`](Self::cancel) it is closed at once.
    pub fn accept(&self, stream: impl ByteStream) {
        Inner::accept(&self.inner, stream);
    }

    /// Closes every connection not yet delivered and refuses new ones. Delivered links are the consumer's.
    pub fn cancel(&self) {
        self.inner.cancel();
    }

    pub fn is_cancelled(&self) -> bool {
        lock(&self.inner.state).cancelled
    }
}

impl<S: SecretStore> Drop for LinkAcceptor<S> {
    fn drop(&mut self) {
        self.inner.cancel();
    }
}

impl<S: SecretStore> fmt::Debug for LinkAcceptor<S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LinkAcceptor").field("options", &self.inner.options).finish_non_exhaustive()
    }
}

impl<S: SecretStore> Inner<S> {
    fn hello_timeout() -> Duration {
        LinkAcceptor::<S>::HELLO_TIMEOUT
    }

    fn accept(self: &Arc<Self>, stream: impl ByteStream) {
        let options = ChannelOptions {
            label: format!("{}.conn", self.options.label),
            answer_version_mismatch: true,
            version: None,
        };
        if lock(&self.state).cancelled {
            return; // dropping the stream closes it
        }
        let channel = MessageChannel::with_options(stream, options);
        let inner = self.clone();
        tokio::spawn(async move {
            let mut cancel = inner.cancel.subscribe();
            tokio::select! {
                _ = cancel.wait_for(|c| *c) => {}
                () = inner.clone().handshake(channel) => {}
            }
        });
    }

    fn cancel(&self) {
        let (pending, waiting) = {
            let mut s = lock(&self.state);
            s.cancelled = true;
            (std::mem::take(&mut s.pending), std::mem::take(&mut s.waiting))
        };
        self.cancel.send_replace(true);
        // Dropping the channels closes them.
        drop(pending);
        drop(waiting);
    }

    /// Spawns `f` to run after `delay` unless the acceptor is cancelled first.
    fn after(self: &Arc<Self>, delay: Duration, f: impl FnOnce(&Self) + Send + 'static) {
        let inner = self.clone();
        tokio::spawn(async move {
            let mut cancel = inner.cancel.subscribe();
            tokio::select! {
                _ = cancel.wait_for(|c| *c) => {}
                () = tokio::time::sleep(delay) => f(&inner),
            }
        });
    }

    /// Answers `Error(code)` so the dialer can say why, then closes.
    fn reject(&self, channel: MessageChannel, code: ErrorCode, why: &str, error: TransportError) {
        tracing::error!(acceptor = %self.options.label, "rejecting connection: {why}");
        let _ = channel.send(&Message::Error(ErrorMessage { code, message: why.to_owned() }));
        drop(channel); // closes after the answer
        let _ = self.rejections.send(error);
    }

    /// Authenticated, but no version is common: `ChannelAccept` with 0 and this side's list, so the dialer
    /// can say which side to update, then a close.
    fn refuse_version(&self, channel: MessageChannel, hello: &ChannelHello) {
        let versions = &self.options.versions;
        tracing::error!(acceptor = %self.options.label, "rejecting connection: it offers {}, this side {versions}", hello.versions);
        let _ = channel.send(&Message::ChannelAccept(ChannelAccept { chosen: 0, versions: versions.clone() }));
        drop(channel);
        let _ = self
            .rejections
            .send(TransportError::NoCommonVersion { local: versions.clone(), peer: hello.versions.clone() });
    }

    async fn handshake(self: Arc<Self>, mut channel: MessageChannel) {
        let deadline = Instant::now() + Self::hello_timeout();
        let env = match tokio::time::timeout_at(deadline, channel.recv()).await {
            Err(_) => {
                tracing::error!(acceptor = %self.options.label, "closing a connection that sent no ChannelHello in {:?}", Self::hello_timeout());
                return;
            }
            // A legacy peer's first frame was already answered by the channel in its own version: report it.
            Ok(Err(e @ TransportError::VersionMismatch { remote })) => {
                tracing::error!(acceptor = %self.options.label, "rejecting connection: protocol v{remote} (answered in v{remote})");
                let _ = self.rejections.send(e);
                return;
            }
            Ok(Err(_)) => return,
            Ok(Ok(env)) => env,
        };
        let hello = match env.message {
            Message::ChannelHello(hello) => hello,
            other => {
                let ty = other.ty();
                return self.reject(
                    channel,
                    ErrorCode::AUTHENTICATION_FAILED,
                    &format!("first message was {ty}"),
                    TransportError::UnexpectedMessage(ty.to_string()),
                );
            }
        };
        match hello.connection_kind {
            ConnectionKind::Realtime if hello.hmac == ChannelAuth::PAIRING_MAC => {
                let Pairing::Accept { peer, store } = self.options.pairing.clone() else {
                    return self.reject(
                        channel,
                        ErrorCode::AUTHENTICATION_FAILED,
                        "pairing not accepted here",
                        TransportError::AuthenticationFailed,
                    );
                };
                let env = match tokio::time::timeout_at(deadline, channel.recv()).await {
                    Ok(Ok(env)) => env,
                    Err(_) => {
                        tracing::error!(acceptor = %self.options.label, "closing a pairing connection that sent no Pair in {:?}", Self::hello_timeout());
                        return;
                    }
                    Ok(Err(_)) => return,
                };
                let pair = match env.message {
                    Message::Pair(pair) => pair,
                    other => {
                        let ty = other.ty();
                        return self.reject(
                            channel,
                            ErrorCode::AUTHENTICATION_FAILED,
                            &format!("expected Pair, got {ty}"),
                            TransportError::UnexpectedMessage(ty.to_string()),
                        );
                    }
                };
                // A pairing replaces the stored secret, so it's stored only once a version is agreed.
                let Some(version) = self.options.versions.highest_common(&hello.versions) else {
                    return self.refuse_version(channel, &hello);
                };
                // Bounded like the reads (see `candidate`): a store that never finishes answers internal.
                let stored = tokio::time::timeout_at(deadline, store(pair.clone()))
                    .await
                    .unwrap_or_else(|_| Err(Self::store_timed_out()));
                if let Err(e) = stored {
                    return self.reject(
                        channel,
                        ErrorCode::INTERNAL,
                        "could not store pairing secret",
                        TransportError::Secrets(e),
                    );
                }
                tracing::info!(acceptor = %self.options.label, "paired over USB ({peer})");
                self.establish(&hello, peer, pair.secret.to_vec(), true, version, channel);
            }
            ConnectionKind::Realtime => {
                let matched = match self.candidate(&hello, deadline).await {
                    Ok(m) => m,
                    Err(e) => {
                        return self.reject(
                            channel,
                            ErrorCode::INTERNAL,
                            "could not read the pairing secrets",
                            TransportError::Secrets(e),
                        );
                    }
                };
                let Some((peer, secret)) = matched else {
                    return self.reject(
                        channel,
                        ErrorCode::AUTHENTICATION_FAILED,
                        "bad HMAC",
                        TransportError::AuthenticationFailed,
                    );
                };
                if !channel.is_bound_to_secret(&secret) {
                    return self.reject(
                        channel,
                        ErrorCode::AUTHENTICATION_FAILED,
                        "HMAC under another pairing than the TLS key",
                        TransportError::AuthenticationFailed,
                    );
                }
                let Some(version) = self.options.versions.highest_common(&hello.versions) else {
                    return self.refuse_version(channel, &hello);
                };
                self.establish(&hello, peer, secret, false, version, channel);
            }
            ConnectionKind::Video | ConnectionKind::Audio => self.route(hello, channel),
        }
    }

    /// What a secret-store call that outlived the connection's hello deadline counts as: a failed read.
    fn store_timed_out() -> PlatformError {
        PlatformError::Unavailable(format!("the secret store did not answer within {:?}", Self::hello_timeout()))
    }

    /// The stored secret `hello` was made with, and its account (the rules are [`AcceptorOptions`]'s).
    ///
    /// Every read must finish by `deadline` (the connection's hello deadline); one that doesn't counts as a
    /// failed read under the same rules. Difference from Swift, whose Keychain reads are synchronous and
    /// unbounded: a Secret Service read can wait on a locked keyring's prompt, and without a bound every
    /// retry of the dialer (which gave up after its accept timeout anyway) would leave one more connection
    /// parked here. Invisible on the wire to a dialer still waiting: it gets `Error(internal)` and retries.
    async fn candidate(
        &self,
        hello: &ChannelHello,
        deadline: Instant,
    ) -> Result<Option<(String, Vec<u8>)>, PlatformError> {
        let bounded = |read| async move {
            tokio::time::timeout_at(deadline, read).await.unwrap_or_else(|_| Err(Self::store_timed_out()))
        };
        // Few candidates, in account order; each check is constant-time (§7.6).
        let matching = |all: BTreeMap<String, Vec<u8>>, skip: Option<&str>| {
            all.into_iter()
                .find(|(account, secret)| Some(account.as_str()) != skip && ChannelAuth::is_valid(hello, secret))
        };
        let Some(primary) = &self.options.primary_account else {
            return Ok(matching(bounded(self.secrets.all_secrets()).await?, None));
        };
        let read = tokio::time::timeout_at(deadline, self.secrets.secret(primary)).await;
        if let Some(secret) = read.unwrap_or_else(|_| Err(Self::store_timed_out()))?
            && ChannelAuth::is_valid(hello, &secret)
        {
            return Ok(Some((primary.clone(), secret)));
        }
        match bounded(self.secrets.all_secrets()).await {
            Ok(all) => Ok(matching(all, Some(primary))),
            Err(e) => {
                tracing::error!(acceptor = %self.options.label, "could not list the pairing secrets ({e}); only {primary} was tried");
                Ok(None)
            }
        }
    }

    fn establish(
        self: &Arc<Self>,
        hello: &ChannelHello,
        peer: String,
        secret: Vec<u8>,
        paired: bool,
        version: u8,
        realtime: MessageChannel,
    ) {
        let token = hello.session_token;
        let early = {
            let mut s = lock(&self.state);
            if s.cancelled {
                return;
            }
            if s.finished.contains(&token) || s.pending.iter().any(|p| p.token == token) {
                drop(s);
                tracing::error!(acceptor = %self.options.label, "closing a second realtime connection for one session");
                return;
            }
            let accept = ChannelAccept { chosen: version, versions: self.options.versions.clone() };
            let _ = realtime.send(&Message::ChannelAccept(accept));
            realtime.set_version(version);
            s.pending.push(Session {
                token,
                secret: secret.clone(),
                peer,
                paired,
                version,
                peer_versions: hello.versions.clone(),
                realtime,
                video: None,
                audio: None,
            });
            let (early, rest): (Vec<_>, Vec<_>) =
                std::mem::take(&mut s.waiting).into_iter().partition(|w| w.hello.session_token == token);
            s.waiting = rest;
            early
        };
        self.after(Self::hello_timeout(), move |inner| inner.drop_incomplete(token));
        for w in early {
            self.join(w.hello, w.channel, &secret);
        }
    }

    /// A video or audio connection: joins its session, or waits for the session's realtime.
    fn route(self: &Arc<Self>, hello: ChannelHello, channel: MessageChannel) {
        let token = hello.session_token;
        let secret = {
            let mut s = lock(&self.state);
            if s.cancelled {
                return;
            }
            if s.finished.contains(&token) {
                drop(s);
                let kind = kind_name(hello.connection_kind);
                tracing::error!(acceptor = %self.options.label, "closing a late {kind} connection: its session was already delivered or dropped");
                return;
            }
            match s.pending.iter().find(|p| p.token == token) {
                Some(session) => session.secret.clone(),
                None => {
                    let id = s.next_waiting_id;
                    s.next_waiting_id += 1;
                    s.waiting.push(Waiting { id, hello, channel });
                    drop(s);
                    self.after(Self::hello_timeout(), move |inner| inner.drop_waiting(id));
                    return;
                }
            }
        };
        self.join(hello, channel, &secret);
    }

    fn join(&self, hello: ChannelHello, channel: MessageChannel, secret: &[u8]) {
        let kind = kind_name(hello.connection_kind);
        if !ChannelAuth::is_valid(&hello, secret) {
            return self.reject(
                channel,
                ErrorCode::AUTHENTICATION_FAILED,
                &format!("bad HMAC on {kind}"),
                TransportError::AuthenticationFailed,
            );
        }
        if !channel.is_bound_to_secret(secret) {
            return self.reject(
                channel,
                ErrorCode::AUTHENTICATION_FAILED,
                &format!("{kind} under another pairing than its TLS key"),
                TransportError::AuthenticationFailed,
            );
        }
        let mut s = lock(&self.state);
        let Some(i) = s.pending.iter().position(|p| p.token == hello.session_token) else {
            return; // its session was dropped or cancelled meanwhile: dropping the channel closes it
        };
        if s.pending[i].peer_versions != hello.versions {
            let why = format!("{kind} offers {}, its realtime {}", hello.versions, s.pending[i].peer_versions);
            drop(s);
            return self.reject(
                channel,
                ErrorCode::AUTHENTICATION_FAILED,
                &why,
                TransportError::UnexpectedMessage("connections offer different versions".into()),
            );
        }
        // Accepted at the session's version, before the link can reach the consumer.
        let version = s.pending[i].version;
        let accept = ChannelAccept { chosen: version, versions: self.options.versions.clone() };
        let _ = channel.send(&Message::ChannelAccept(accept));
        channel.set_version(version);
        let session = &mut s.pending[i];
        let slot = if hello.connection_kind == ConnectionKind::Video { &mut session.video } else { &mut session.audio };
        let replaced = slot.replace(channel);
        if session.video.is_none() || session.audio.is_none() {
            drop(s);
            drop(replaced);
            return;
        }
        let session = s.pending.remove(i);
        s.finish(session.token);
        drop(s);
        drop(replaced);
        let Session { token, secret, peer, paired, version, peer_versions, realtime, video, audio } = session;
        let transport = self.options.transport.clone().unwrap_or_else(|| realtime.link_transport().clone());
        let link = Link::new(
            token,
            realtime,
            video.expect("joined"),
            audio.expect("joined"),
            transport,
            version,
            Some(peer_versions),
            self.options.versions.clone(),
        );
        let _ = self.links.send(AcceptedLink { link, peer, secret, paired });
    }

    fn drop_waiting(&self, id: u64) {
        let dropped = {
            let mut s = lock(&self.state);
            s.waiting.iter().position(|w| w.id == id).map(|i| s.waiting.remove(i))
        };
        if dropped.is_some() {
            tracing::error!(acceptor = %self.options.label, "closing a video/audio connection whose realtime never came");
        }
    }

    fn drop_incomplete(&self, token: [u8; ChannelHello::TOKEN_SIZE]) {
        let dropped = {
            let mut s = lock(&self.state);
            let i = s.pending.iter().position(|p| p.token == token);
            i.map(|i| {
                s.finish(token);
                s.pending.remove(i)
            })
        };
        if dropped.is_some() {
            tracing::error!(acceptor = %self.options.label, "dropping a session: its video and audio didn't follow realtime within {:?}", Self::hello_timeout());
        }
    }
}

/// The client's single loopback listener (§7.2): a [`LinkAcceptor`] fed by a TCP listener on 127.0.0.1,
/// with `TCP_NODELAY` on every accepted socket (§7.1). `peer_id` (`"host"`, the host last paired over USB)
/// is the first candidate, every other stored account (`mac:<hostId>`) the next ones. With
/// `accepts_pairing`, a pairing stores the secret under `peer_id` and, when the host sent a canonical host
/// id, under `mac:<hostId>` too. Swift: `ClientLinkListener`; here for the tests and a fake iPad (the
/// Linux host never listens on USB).
pub struct ClientLinkListener<S: SecretStore> {
    port: u16,
    acceptor: LinkAcceptor<S>,
}

impl<S: SecretStore + Clone> ClientLinkListener<S> {
    pub const HELLO_TIMEOUT: Duration = LinkAcceptor::<S>::HELLO_TIMEOUT;

    /// `port` `None`: [`USB_PORT`]; `Some(0)` picks an ephemeral port (tests). Swift's `versions` default,
    /// `VersionList.offered`, is passed explicitly.
    pub async fn bind(
        port: Option<u16>,
        secrets: S,
        peer_id: &str,
        accepts_pairing: bool,
        versions: VersionList,
    ) -> std::io::Result<(Self, AcceptorEvents)> {
        let pairing = if accepts_pairing { Pairing::client(secrets.clone(), peer_id) } else { Pairing::Refuse };
        let options = AcceptorOptions {
            primary_account: Some(peer_id.to_owned()),
            pairing,
            label: "lain.client".into(),
            transport: None,
            versions,
        };
        let (acceptor, events) = LinkAcceptor::new(secrets, options);
        let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port.unwrap_or(USB_PORT))).await?;
        let port = listener.local_addr()?.port();
        let inner = acceptor.inner.clone();
        tokio::spawn(async move {
            let mut cancel = inner.cancel.subscribe();
            loop {
                let accepted = tokio::select! {
                    _ = cancel.wait_for(|c| *c) => return,
                    accepted = listener.accept() => accepted,
                };
                match accepted {
                    Ok((socket, _)) => {
                        if let Err(e) = socket.set_nodelay(true) {
                            tracing::warn!("TCP_NODELAY: {e}");
                        }
                        Inner::accept(&inner, socket);
                    }
                    Err(e) => tracing::warn!("accept: {e}"),
                }
            }
        });
        Ok((Self { port, acceptor }, events))
    }
}

impl<S: SecretStore> ClientLinkListener<S> {
    pub fn port(&self) -> u16 {
        self.port
    }

    /// Stops listening and closes everything undelivered. Dropping the listener does the same.
    pub fn cancel(&self) {
        self.acceptor.cancel();
    }
}

impl<S: SecretStore> fmt::Debug for ClientLinkListener<S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClientLinkListener").field("port", &self.port).finish_non_exhaustive()
    }
}
