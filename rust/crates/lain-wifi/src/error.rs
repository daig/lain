//! Why a Wi-Fi dial, handshake or listener failed. Swift: `NetworkStreamError` (`NetworkStream.swift`).

use std::io;

use crate::NegotiatedTls;

/// Why a TLS-PSK dial or handshake failed, classified for status and backoff. Swift: `NetworkStreamError`.
///
/// Intended differences from Swift:
/// - `tls(OSStatus)` is [`Tls`](Self::Tls) with OpenSSL's error text; `posix(Int32)` and `other(String)`
///   are [`Io`](Self::Io) with the error's text (`Clone + PartialEq` stay possible).
/// - No `localNetworkDenied` and no `dns`: Linux has no Local Network permission, and this crate dials
///   socket addresses, never names.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WiFiError {
    /// The peer holds no PSK with our identity (Swift -9864; OpenSSL: alert `unknown_psk_identity`, or
    /// on the server `psk identity not found`): the host doesn't have this pairing loaded.
    #[error("unknown PSK identity")]
    UnknownIdentity,
    /// The identity matched but the key didn't: the handshake's MAC check failed (alert
    /// `bad_record_mac` or `decrypt_error`).
    #[error("wrong PSK key")]
    WrongKey,
    /// Any other TLS failure, with OpenSSL's text.
    #[error("TLS: {0}")]
    Tls(String),
    /// TLS completed on something other than [`NegotiatedTls::REQUIRED`] (`None`: not reported): refused
    /// like a failed handshake (D29).
    #[error("unexpected TLS: {}", .0.map_or("none".to_owned(), |t| t.to_string()))]
    UnexpectedTls(Option<NegotiatedTls>),
    /// Nothing listens there (ECONNREFUSED).
    #[error("connection refused")]
    Refused,
    /// Not done within the dial or handshake deadline.
    #[error("timed out")]
    Timeout,
    /// A socket error, with its text.
    #[error("i/o: {0}")]
    Io(String),
}

impl From<io::Error> for WiFiError {
    fn from(e: io::Error) -> Self {
        if e.kind() == io::ErrorKind::ConnectionRefused { Self::Refused } else { Self::Io(e.to_string()) }
    }
}

/// OpenSSL reason codes (`ERR_GET_REASON`, OpenSSL 3; stable ABI values from `sslerr.h`).
mod reason {
    /// `SSL_R_PSK_IDENTITY_NOT_FOUND`: the server's PSK callback knew no such identity.
    pub const PSK_IDENTITY_NOT_FOUND: i32 = 223;
    /// `SSL_R_TLSV1_ALERT_UNKNOWN_PSK_IDENTITY` (`SSL_AD_REASON_OFFSET` 1000 + alert 115).
    pub const ALERT_UNKNOWN_PSK_IDENTITY: i32 = 1115;
    /// `SSL_R_DECRYPTION_FAILED_OR_BAD_RECORD_MAC`: this side's record or Finished check failed.
    pub const DECRYPTION_FAILED_OR_BAD_RECORD_MAC: i32 = 281;
    /// `SSL_R_DECRYPTION_FAILED`.
    pub const DECRYPTION_FAILED: i32 = 147;
    /// `SSL_R_DIGEST_CHECK_FAILED`: the peer's Finished didn't verify.
    pub const DIGEST_CHECK_FAILED: i32 = 149;
    /// `SSL_R_SSLV3_ALERT_BAD_RECORD_MAC` (1000 + alert 20).
    pub const ALERT_BAD_RECORD_MAC: i32 = 1020;
    /// `SSL_R_TLSV1_ALERT_DECRYPTION_FAILED` (1000 + alert 21).
    pub const ALERT_DECRYPTION_FAILED: i32 = 1021;
    /// `SSL_R_TLSV1_ALERT_DECRYPT_ERROR` (1000 + alert 51).
    pub const ALERT_DECRYPT_ERROR: i32 = 1051;
}

/// Classifies a failed `accept` or `connect`. Swift: `NetworkStreamError.classify`, from OSStatus codes;
/// here from OpenSSL's reason codes, in either role.
pub(crate) fn classify(error: &openssl::ssl::Error) -> WiFiError {
    if let Some(stack) = error.ssl_error() {
        for e in stack.errors() {
            match e.reason_code() {
                reason::PSK_IDENTITY_NOT_FOUND | reason::ALERT_UNKNOWN_PSK_IDENTITY => {
                    return WiFiError::UnknownIdentity;
                }
                reason::DECRYPTION_FAILED_OR_BAD_RECORD_MAC
                | reason::DECRYPTION_FAILED
                | reason::DIGEST_CHECK_FAILED
                | reason::ALERT_BAD_RECORD_MAC
                | reason::ALERT_DECRYPTION_FAILED
                | reason::ALERT_DECRYPT_ERROR => return WiFiError::WrongKey,
                _ => {}
            }
        }
        return WiFiError::Tls(stack.to_string());
    }
    match error.io_error() {
        Some(io) => WiFiError::from(io::Error::new(io.kind(), io.to_string())),
        // The peer closed during the handshake (`SSL_ERROR_ZERO_RETURN` or `SSL_ERROR_SYSCALL` at EOF).
        None => WiFiError::Tls(error.to_string()),
    }
}
