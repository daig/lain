//! The desktop's input settings that the client needs in `HelloAck` (Swift: `HostInputSettings`).

/// Input settings, read when a session starts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputSettings {
    pub double_click_ms: u32,
    pub key_repeat_delay_ms: u32,
    pub key_repeat_interval_ms: u32,
    /// The current keyboard layout's identifier, sent as `HelloAck.macInputSource`. The client only
    /// displays it: e.g. `xkb:us+colemak` on GNOME, `com.apple.keylayout.Colemak` on a Mac.
    pub input_source: String,
}

/// Where the core reads [`InputSettings`].
pub trait SettingsSource: Send + Sync + 'static {
    fn input_settings(&self) -> InputSettings;
}
