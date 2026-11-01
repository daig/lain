//! Service discovery (Swift: the Wi-Fi listener's Bonjour service).

use std::future::Future;

use crate::Result;

/// One advertised service.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceAd {
    /// `_lain._tcp`.
    pub service_type: String,
    /// The instance name: the host's name.
    pub name: String,
    pub port: u16,
    /// The TXT record, in order: `v`, `vs`, `id`.
    pub txt: Vec<(String, String)>,
}

/// Publishes the host's service on the local network.
pub trait Advertiser: Send + Sync + 'static {
    /// Publishes `ad`, replacing any earlier one. The platform may rename the instance on a name
    /// conflict.
    fn advertise(&self, ad: ServiceAd) -> impl Future<Output = Result<()>> + Send;

    /// Withdraws the service. Idempotent.
    fn withdraw(&self) -> impl Future<Output = ()> + Send;
}
