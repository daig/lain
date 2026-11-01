//! Secret Service secrets, Avahi advertising, host identity, systemd autostart (wave 2).
//!
//! Swift reference (behaviour): `Packages/LainKit/Sources/LainTransport/Security.swift` (`SecretStore`,
//! `KeychainSecretStore`), `LainTransport/Discovery.swift` (`LainTXT`), `LainHostCore/Session/HostIdentity.swift`,
//! `LainHostCore/Service/LoginAgent.swift`. Brief: `docs/LINUX-HOST-PLAN.md`, `lain-linux-system`.
//!
//! - [`secrets`]: [`SystemSecretStore`], the Secret Service through `oo7` with a 0600 file fallback.
//! - [`avahi`]: [`AvahiAdvertiser`], an Avahi entry group over the system bus.
//! - [`identity`]: the host id in `$XDG_CONFIG_HOME/lain/host-id` and the name from `hostname1`.
//! - [`autostart`]: [`Autostart`], a systemd user unit bound to `graphical-session.target`.
//! - [`paths`]: where the files live.
//!
//! Nothing here starts a desktop session, touches a GPU or injects input.

pub mod autostart;
pub mod avahi;
pub mod identity;
pub mod paths;
pub mod secrets;

#[cfg(test)]
mod testbus;

pub use autostart::{Autostart, AutostartState};
pub use avahi::AvahiAdvertiser;
pub use identity::{is_canonical_host_id, load_host_identity, load_host_identity_in};
pub use secrets::{FileSecretStore, PAIRING_SERVICE, SecretServiceStore, SystemSecretStore};
