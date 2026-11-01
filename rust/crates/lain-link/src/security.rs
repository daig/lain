//! `ChannelHello` authentication and the secret-store accounts. Swift: `Security.swift`.

use hmac::{Hmac, KeyInit, Mac};
use lain_platform::{PlatformError, SecretStore};
use lain_proto::{ChannelHello, ConnectionKind, Pair, VersionList};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

/// `ChannelHello` authentication (§7.6): HMAC-SHA256 over the offered versions, kind and session token,
/// keyed by the 32-byte pairing secret. Swift: `ChannelAuth`.
pub struct ChannelAuth;

impl ChannelAuth {
    /// An all-zero HMAC asks for USB pairing.
    pub const PAIRING_MAC: [u8; ChannelHello::MAC_SIZE] = [0; ChannelHello::MAC_SIZE];

    pub fn mac(secret: &[u8], hello: &ChannelHello) -> [u8; ChannelHello::MAC_SIZE] {
        let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC takes a key of any length");
        mac.update(&hello.authenticated_bytes());
        mac.finalize().into_bytes().into()
    }

    /// Whether `hello`'s HMAC was made with `secret`. Constant-time in the HMAC (§7.6).
    pub fn is_valid(hello: &ChannelHello, secret: &[u8]) -> bool {
        let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC takes a key of any length");
        mac.update(&hello.authenticated_bytes());
        mac.verify_slice(&hello.hmac).is_ok()
    }

    /// A `ChannelHello` carrying its HMAC; `secret` `None`: the pairing (all-zero) HMAC. Swift's `versions`
    /// defaults to `VersionList.offered`; here the caller passes it ([`VersionList::offered`]).
    pub fn hello(
        kind: ConnectionKind,
        token: [u8; ChannelHello::TOKEN_SIZE],
        secret: Option<&[u8]>,
        versions: &VersionList,
    ) -> ChannelHello {
        let mut hello = ChannelHello {
            versions: versions.clone(),
            connection_kind: kind,
            session_token: token,
            hmac: Self::PAIRING_MAC,
        };
        if let Some(secret) = secret {
            hello.hmac = Self::mac(secret, &hello);
        }
        hello
    }

    /// `N` bytes from the operating system's CSPRNG (through `rand`'s thread RNG, seeded from it).
    pub fn random_bytes<const N: usize>() -> [u8; N] {
        rand::random()
    }
}

/// The secret-store accounts (§7.7 D29). On the client: `"host"` (the Mac last paired over USB) and
/// `mac:<hostId>` (a host's secret usable over Wi-Fi). On the Linux host an iPad's account is its USB serial
/// number: `lain-host` chooses it and passes it as `peer_id`; nothing here names it. Swift:
/// `PairingAccounts`, plus `ClientLinkListener.storePairing` as [`store_pairing`](Self::store_pairing).
pub struct PairingAccounts;

impl PairingAccounts {
    /// The host last paired over USB (D23), on the client.
    pub const USB_HOST: &'static str = "host";
    const MAC_PREFIX: &'static str = "mac:";

    /// A host's secret usable over Wi-Fi, by the host id it advertises.
    pub fn mac(host_id: &str) -> String {
        format!("{}{host_id}", Self::MAC_PREFIX)
    }

    /// The host id of a `mac:<hostId>` account; `None` for other accounts and non-canonical ids.
    pub fn host_id_from_account(account: &str) -> Option<&str> {
        let id = account.strip_prefix(Self::MAC_PREFIX)?;
        Self::is_canonical_host_id(id).then_some(id)
    }

    /// Host ids are `UUID().uuidString` exactly: 36 characters, uppercase hex, hyphens after the 8th, 12th,
    /// 16th and 20th digit. The id is self-asserted and public, so nothing else becomes an account or a
    /// browse filter. Swift checks `UUID(uuidString: id)?.uuidString == id`, which accepts exactly these.
    pub fn is_canonical_host_id(id: &str) -> bool {
        id.len() == 36
            && id.bytes().enumerate().all(|(i, b)| match i {
                8 | 13 | 18 | 23 => b == b'-',
                _ => b.is_ascii_digit() || (b'A'..=b'F').contains(&b),
            })
    }

    /// The client's USB pairing: the host's secret for USB (`peer`) and, given a canonical host id, for
    /// Wi-Fi (`mac:<hostId>`) together, so a cable pull can't leave a stale Wi-Fi secret behind (§7.7 D29).
    /// A malformed host id is logged and stored for USB only. Swift: `ClientLinkListener.storePairing`.
    pub async fn store_pairing(secrets: &impl SecretStore, pair: &Pair, peer: &str) -> Result<(), PlatformError> {
        secrets.set_secret(peer, &pair.secret).await?;
        if Self::is_canonical_host_id(&pair.host_id) {
            secrets.set_secret(&Self::mac(&pair.host_id), &pair.secret).await?;
        } else if !pair.host_id.is_empty() {
            tracing::error!("Pair carried a malformed host id; stored for USB only");
        }
        Ok(())
    }
}
