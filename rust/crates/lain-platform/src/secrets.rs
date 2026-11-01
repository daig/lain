//! Pairing secrets (Swift: `SecretStore`).

use std::collections::BTreeMap;
use std::future::Future;

use crate::Result;

/// Where pairing secrets live: the Secret Service on Linux, memory in tests. Accounts are named by
/// `lain-link`'s `PairingAccounts`.
pub trait SecretStore: Send + Sync + 'static {
    fn secret(&self, account: &str) -> impl Future<Output = Result<Option<Vec<u8>>>> + Send;

    fn set_secret(&self, account: &str, secret: &[u8]) -> impl Future<Output = Result<()>> + Send;

    /// Removing an account that doesn't exist succeeds.
    fn remove_secret(&self, account: &str) -> impl Future<Output = Result<()>> + Send;

    /// Every stored secret by account: an acceptor's candidates, the Wi-Fi listener's PSKs. Deliberately
    /// no default implementation: an empty one would hide a missing enumeration.
    fn all_secrets(&self) -> impl Future<Output = Result<BTreeMap<String, Vec<u8>>>> + Send;
}
