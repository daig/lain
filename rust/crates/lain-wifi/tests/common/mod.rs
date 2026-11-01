//! Test helpers, after Swift's `NetworkStreamTests.swift` (`LoopbackTLSServer`, `patternBytes`, the
//! hand-built TLS peers). Loopback only: listeners bind 127.0.0.1, every dial goes to 127.0.0.1.
#![allow(dead_code)]

use std::net::SocketAddr;
use std::pin::Pin;
use std::time::Duration;

use lain_wifi::*;
use openssl::ssl::{Ssl, SslContext, SslContextBuilder, SslMethod, SslVerifyMode, SslVersion};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_openssl::SslStream;

pub const T: Duration = Duration::from_secs(3);

/// Swift's `wifiPSKA` and `wifiPSKB` secrets.
pub fn secret_a() -> Vec<u8> {
    (0..32).collect()
}

pub fn secret_b() -> Vec<u8> {
    vec![0xA5; 32]
}

/// Swift: `patternBytes`.
pub fn pattern(count: usize, seed: usize) -> Vec<u8> {
    (0..count).map(|i| (i.wrapping_mul(seed).wrapping_add(i >> 13)) as u8).collect()
}

/// The next value within `within`, else `None`.
pub async fn next<T>(rx: &mut mpsc::Receiver<T>, within: Duration) -> Option<T> {
    tokio::time::timeout(within, rx.recv()).await.ok().flatten()
}

/// Polls `condition` every 10 ms for up to `within`.
pub async fn poll_until(within: Duration, mut condition: impl FnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + within;
    while !condition() {
        if tokio::time::Instant::now() > deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    true
}

/// A loopback TLS-PSK listener and what it hands over or rejects. Swift: `LoopbackTLSServer`.
pub struct Server {
    pub listener: TlsPskListener,
    pub accepted: mpsc::Receiver<WiFiConnection>,
    pub rejected: mpsc::Receiver<WiFiError>,
}

impl Server {
    pub fn new(secrets: &[Vec<u8>]) -> Self {
        Self::with_options(secrets, ListenerOptions::loopback())
    }

    pub fn with_handshake_timeout(secrets: &[Vec<u8>], timeout: Duration) -> Self {
        Self::with_options(secrets, ListenerOptions { handshake_timeout: timeout, ..ListenerOptions::loopback() })
    }

    pub fn with_options(secrets: &[Vec<u8>], options: ListenerOptions) -> Self {
        let (tx, accepted) = mpsc::channel(256);
        let (listener, rejected) = TlsPskListener::bind(PskTable::with_secrets(secrets), &options, move |c| {
            let _ = tx.try_send(c);
        })
        .unwrap();
        Self { listener, accepted, rejected }
    }

    pub fn addr(&self) -> SocketAddr {
        self.listener.local_addr()
    }

    /// Dials with `secret`'s PSK and returns both ends.
    pub async fn pair(&mut self, secret: &[u8]) -> (WiFiConnection, WiFiConnection) {
        let client = connect(self.addr(), secret).await.unwrap();
        let server = next(&mut self.accepted, T).await.expect("handed over");
        (client, server)
    }
}

/// A TLS 1.2 client lain didn't build, for the suite checks (D29): `psk` with OpenSSL's `ciphers`.
pub fn hand_client(psk: &WiFiPsk, ciphers: &str, versions: (SslVersion, SslVersion)) -> SslContext {
    hand_client_builder(psk, ciphers, versions).build()
}

/// [`hand_client`], before it is built (to set groups or a session cache).
pub fn hand_client_builder(psk: &WiFiPsk, ciphers: &str, versions: (SslVersion, SslVersion)) -> SslContextBuilder {
    let mut b = SslContext::builder(SslMethod::tls_client()).unwrap();
    b.set_min_proto_version(Some(versions.0)).unwrap();
    b.set_max_proto_version(Some(versions.1)).unwrap();
    b.set_cipher_list(ciphers).unwrap();
    b.set_ciphersuites("TLS_CHACHA20_POLY1305_SHA256").unwrap();
    b.set_verify(SslVerifyMode::NONE);
    let (identity, key) = (psk.identity().as_bytes().to_vec(), *psk.key());
    b.set_psk_client_callback(move |_, _, id, k| {
        id[..identity.len()].copy_from_slice(&identity);
        id[identity.len()] = 0;
        k[..32].copy_from_slice(&key);
        Ok(32)
    });
    b
}

/// A TLS 1.2 PSK server lain didn't build, holding `psk`, with OpenSSL's `ciphers`.
pub fn hand_server(psk: &WiFiPsk, ciphers: &str) -> SslContext {
    let mut b = SslContext::builder(SslMethod::tls_server()).unwrap();
    b.set_min_proto_version(Some(SslVersion::TLS1_2)).unwrap();
    b.set_max_proto_version(Some(SslVersion::TLS1_2)).unwrap();
    b.set_cipher_list(ciphers).unwrap();
    let (identity, key) = (psk.identity().as_bytes().to_vec(), *psk.key());
    b.set_psk_server_callback(move |_, offered, k| {
        if offered != Some(&identity[..]) {
            return Ok(0);
        }
        k[..32].copy_from_slice(&key);
        Ok(32)
    });
    b.build()
}

pub async fn hand_connect(addr: SocketAddr, context: &SslContext) -> Result<SslStream<TcpStream>, String> {
    let tcp = TcpStream::connect(addr).await.map_err(|e| e.to_string())?;
    let mut stream = SslStream::new(Ssl::new(context).unwrap(), tcp).unwrap();
    Pin::new(&mut stream).connect().await.map_err(|e| e.to_string())?;
    Ok(stream)
}

pub async fn hand_accept(tcp: TcpStream, context: &SslContext) -> Result<SslStream<TcpStream>, String> {
    let mut stream = SslStream::new(Ssl::new(context).unwrap(), tcp).unwrap();
    Pin::new(&mut stream).accept().await.map_err(|e| e.to_string())?;
    Ok(stream)
}
