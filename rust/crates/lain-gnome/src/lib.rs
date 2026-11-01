//! The GNOME bridge (decisions L2 and L8): the GNOME side of `DisplayBackend`, `InputBackend`,
//! `CursorSource`, `PowerBackend`, `SettingsSource` and `SetupSource`, over Mutter's and gnome-session's
//! D-Bus APIs, gsettings, and a short-lived PipeWire consumer. No Swift counterpart for the APIs; the
//! behaviour follows `LainHostCore/Video/StreamedDisplay` and `Session/HostEnvironment`.
//!
//! [`Gnome::connect`] opens one session-bus connection and builds every component on it:
//! - [`GnomeDisplay`]: lain's display, `ScreenCast.RecordVirtual` in a ScreenCast session linked to a
//!   RemoteDesktop session; its mode set by [`negotiate`], its place and scale by the [`arrangement`] rules
//!   with `ApplyMonitorsConfig` method 1 only ([`display_config::APPLY_METHOD`]); `monitors()` from
//!   `GetCurrentState` on every `MonitorsChanged`. Its source, [`GnomeSource`], is what `lain-linux-video`
//!   captures.
//! - [`GnomeInput`]: `RemoteDesktop.Notify*` in a session of its own ([`input`], [`input_map`]).
//! - [`GnomeCursor`] and [`CursorState`]: the cursor from lain's stream's metadata, which `lain-linux-video`
//!   writes.
//! - [`GnomePower`]: `SessionManager.Inhibit`. [`GnomeSettings`]: gsettings. [`GnomeSetup`]: `has_other_display`.
//!
//! Nothing here touches a GPU: the PipeWire consumer negotiates a format and takes no buffers it maps.

pub mod arrangement;
pub mod bus;
pub mod cursor;
pub mod desktop;
pub mod display;
pub mod display_config;
#[cfg(test)]
mod fake_mutter;
pub mod input;
pub mod input_map;
pub mod monitors;
pub mod negotiate;
pub mod power;
pub mod settings;
pub mod setup;

use std::path::PathBuf;
use std::sync::Arc;

pub use cursor::{BitmapFormat, CursorState, GnomeCursor, StreamGeometry};
pub use display::{DisplayEnd, GnomeDisplay, GnomeSource};
pub use input::GnomeInput;
pub use input_map::Barrier;
use lain_platform::PlatformError;
pub use power::GnomePower;
pub use settings::GnomeSettings;
pub use setup::GnomeSetup;
use zbus::Connection;

/// How the bridge is set up.
#[derive(Debug, Clone, Default)]
pub struct GnomeConfig {
    /// The panel-barrier detour for pointer moves ([`Barrier`]): on by default.
    pub barrier: Barrier,
    /// Where the owner's arrangement is stored; `None` means `$XDG_CONFIG_HOME/lain/arrangement.toml`.
    pub arrangement_path: Option<PathBuf>,
}

/// Every GNOME component, sharing one session-bus connection. `lain-hostd` composes it with
/// `lain-linux-video` and `lain-linux-system` into a `Platform`.
#[derive(Clone)]
pub struct Gnome {
    pub display: GnomeDisplay,
    pub input: GnomeInput,
    pub cursor: GnomeCursor,
    pub cursor_state: Arc<CursorState>,
    pub power: GnomePower,
    pub settings: GnomeSettings,
    pub setup: GnomeSetup,
    conn: Connection,
}

impl Gnome {
    /// Connects to the session bus and starts every component. Must run inside a tokio runtime; the tasks it
    /// spawns end when the connection does.
    pub async fn connect(config: GnomeConfig) -> Result<Self, PlatformError> {
        let conn =
            Connection::session().await.map_err(|e| PlatformError::Unavailable(format!("the session bus: {e}")))?;
        Self::with_connection(conn, config).await
    }

    /// The same, on a connection the caller made (the daemon's own, for its other services).
    pub async fn with_connection(conn: Connection, config: GnomeConfig) -> Result<Self, PlatformError> {
        let cursor_state = CursorState::new();
        let store = config.arrangement_path.or_else(arrangement::Store::default_path).map(arrangement::Store::new);
        let desktop = monitors::spawn(&conn, cursor_state.clone(), store).await?;
        let display = GnomeDisplay::new(conn.clone(), desktop.clone(), cursor_state.clone());
        let input = GnomeInput::spawn(conn.clone(), desktop.desktop.clone(), cursor_state.clone(), config.barrier);
        let power = GnomePower::spawn(conn.clone());
        let settings = GnomeSettings::start(&conn).await;
        let setup = GnomeSetup::new(desktop.desktop.clone());
        Ok(Self {
            display,
            input,
            cursor: GnomeCursor::new(cursor_state.clone()),
            cursor_state,
            power,
            settings,
            setup,
            conn,
        })
    }

    /// The shared connection.
    pub fn connection(&self) -> &Connection {
        &self.conn
    }
}
