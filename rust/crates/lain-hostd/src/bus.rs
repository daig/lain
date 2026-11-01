//! Single instance: the daemon owns `dev.sub.lain.Host` on the session bus, which 4b's control interface will
//! serve. This replaces Swift's `LoginAgent.settleInstance` (the launchd-managed agent wins there; here whoever
//! owns the name first).

use zbus::fdo::RequestNameFlags;

/// The daemon's well-known name.
pub const BUS_NAME: &str = "dev.sub.lain.Host";

/// Requests [`BUS_NAME`] on `conn` with `DoNotQueue`: `Ok(true)` if this process owns it now, `Ok(false)` if
/// another process does (another lain host is running).
pub async fn claim_bus_name(conn: &zbus::Connection) -> zbus::Result<bool> {
    claim_name(conn, BUS_NAME).await
}

/// [`claim_bus_name`] for any name (tests).
pub async fn claim_name(conn: &zbus::Connection, name: &str) -> zbus::Result<bool> {
    // The object server first, so that method calls arriving once the name is owned aren't lost (zbus warns
    // otherwise); 4b registers its interface on it.
    let _ = conn.object_server();
    match conn.request_name_with_flags(name, RequestNameFlags::DoNotQueue.into()).await {
        Ok(_) => Ok(true),
        Err(zbus::Error::NameTaken) => Ok(false),
        Err(e) => Err(e),
    }
}
