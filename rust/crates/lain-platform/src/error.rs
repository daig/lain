//! The one error type of the contract.

/// Why a platform call failed. Implementations put the underlying cause in the message.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PlatformError {
    /// The facility doesn't exist or can't be reached now: no compositor session, a daemon not running,
    /// a device missing.
    #[error("unavailable: {0}")]
    Unavailable(String),
    /// The owner or the system refused: a locked keyring, a denied capture.
    #[error("denied: {0}")]
    Denied(String),
    /// Anything else.
    #[error("{0}")]
    Failed(String),
}

pub type Result<T, E = PlatformError> = std::result::Result<T, E>;
