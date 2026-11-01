//! The daemon's settings: `$XDG_CONFIG_HOME/lain/config.toml`.
//!
//! No single Swift counterpart: the Mac host has no settings file. Its values are constants in `HostSession`,
//! `HostVideoPipeline` and `HostInputRouter`, and each key's default here is that constant, or the Linux
//! crate's default where the Linux behaviour is new (the modifier map, the scroll policy, the panel barrier).
//!
//! Every key is optional and a missing file means the defaults. A key the daemon doesn't know, a value of the
//! wrong type and a value out of bounds are refused with the file, the key and the reason, and the daemon exits
//! rather than run with a setting it didn't understand. `config.example.toml` (next to this crate's manifest)
//! documents every key; a test checks that it parses to the defaults.

use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

use lain_gnome::Barrier;
use lain_input::{CommandShortcut, InputConfig, LinuxModifier, ModifierMap, Momentum, ScrollConfig, ZoomAction};
use lain_media::PipelineOptions;
use lain_platform::ScrollSource;
use serde::Deserialize;

/// The file name in lain's directory (`lain_linux_system::paths::lain_dir`).
pub const CONFIG_FILE: &str = "config.toml";

/// The bitrate's bounds, in Mb/s. 60 is Swift's `HostVideoPipeline` default; the iGPU's encoder was measured
/// at 60 (SL2, SL7). Below 1 the picture is unusable, and above 200 a 2752×2064 stream gains nothing visible
/// while the coded buffer and the Wi-Fi link suffer.
pub const BITRATE_MBPS: (u32, u32) = (1, 200);
/// The panel band's bounds in logical pixels (GNOME's top bar is about 32).
pub const BARRIER_BAND: (f64, f64) = (0.0, 200.0);
/// The pinch threshold's bounds: above 1 (`PinchZoomMapper` asserts it), at most 4 (a 4× pinch per step).
pub const PINCH_THRESHOLD: (f64, f64) = (1.0, 4.0);
/// `client_stop_delay_ms`'s bounds.
pub const CLIENT_STOP_DELAY_MS: (u64, u64) = (0, 2_000);

/// Why the config can't be used. Each names the file; [`Invalid`](Self::Invalid) and most
/// [`Parse`](Self::Parse) errors name the key.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("{}: can't be read: {source}", path.display())]
    Read { path: PathBuf, source: io::Error },
    /// Not TOML, an unknown key, or a value of the wrong type.
    #[error("{}: {}{message}", path.display(), key.as_ref().map(|k| format!("{k}: ")).unwrap_or_default())]
    Parse { path: PathBuf, key: Option<String>, message: String },
    /// A value out of its bounds.
    #[error("{}: {key}: {reason}", path.display())]
    Invalid { path: PathBuf, key: String, reason: String },
}

/// The whole file. Swift: the constants it replaces are named on each field.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    /// Listen for and advertise Wi-Fi links. Swift's host does whenever its id loads (`HostWiFiConfig(advertise:
    /// true)`), so the default is on.
    pub wifi: bool,
    /// The encoder's average bitrate and `HelloAck.bitrate` (Swift: `HostVideoPipeline`'s 60 Mb/s).
    pub bitrate_mbps: u32,
    /// The panel-barrier detour of pointer moves (`lain_gnome::Barrier`; no Swift counterpart).
    pub barrier: BarrierConfig,
    pub input: InputSection,
}

impl Default for Config {
    fn default() -> Self {
        let barrier = Barrier::default();
        Self {
            wifi: true,
            bitrate_mbps: PipelineOptions::default().average_bit_rate / 1_000_000,
            barrier: BarrierConfig { detour: barrier.detour, band: barrier.band },
            input: InputSection::from(&InputConfig::default()),
        }
    }
}

/// `[barrier]`: `lain_gnome::Barrier`.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct BarrierConfig {
    pub detour: bool,
    /// The panel's height in logical pixels.
    pub band: f64,
}

impl Default for BarrierConfig {
    fn default() -> Self {
        Config::default().barrier
    }
}

/// `[input]`: `lain_input::InputConfig`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct InputSection {
    pub modifiers: ModifiersConfig,
    pub scroll: ScrollSection,
    pub zoom: Zoom,
    pub pinch_threshold: f64,
    pub swap_iso_keys: bool,
    pub allow_system_keys: bool,
    pub command_shortcuts: Vec<ShortcutConfig>,
}

impl Default for InputSection {
    fn default() -> Self {
        Self::from(&InputConfig::default())
    }
}

impl From<&InputConfig> for InputSection {
    fn from(c: &InputConfig) -> Self {
        Self {
            modifiers: ModifiersConfig {
                shift: c.modifiers.shift.into(),
                control: c.modifiers.control.into(),
                option: c.modifiers.option.into(),
                command: c.modifiers.command.into(),
                function: c.modifiers.function.into(),
            },
            scroll: ScrollSection {
                momentum: c.scroll.momentum.into(),
                source: c.scroll.phased_source.into(),
                client_stop_delay_ms: c.scroll.client_stop_delay_ns / 1_000_000,
            },
            zoom: c.zoom.into(),
            pinch_threshold: c.pinch_threshold,
            swap_iso_keys: c.swap_iso_keys,
            allow_system_keys: c.allow_system_keys,
            command_shortcuts: c
                .command_shortcuts
                .iter()
                .map(|s| ShortcutConfig { usage: s.usage, hold: s.hold.into() })
                .collect(),
        }
    }
}

/// `[input.modifiers]`: which desktop modifier each Mac modifier holds (`lain_input::ModifierMap`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ModifiersConfig {
    pub shift: Modifier,
    pub control: Modifier,
    pub option: Modifier,
    pub command: Modifier,
    pub function: Modifier,
}

impl Default for ModifiersConfig {
    fn default() -> Self {
        InputSection::default().modifiers
    }
}

/// A desktop modifier, or `"none"` (`lain_input::LinuxModifier`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Modifier {
    Shift,
    Control,
    Alt,
    Super,
    AltGr,
    None,
}

impl From<Option<LinuxModifier>> for Modifier {
    fn from(m: Option<LinuxModifier>) -> Self {
        match m {
            Some(LinuxModifier::Shift) => Self::Shift,
            Some(LinuxModifier::Control) => Self::Control,
            Some(LinuxModifier::Alt) => Self::Alt,
            Some(LinuxModifier::Super) => Self::Super,
            Some(LinuxModifier::AltGr) => Self::AltGr,
            None => Self::None,
        }
    }
}

impl From<LinuxModifier> for Modifier {
    fn from(m: LinuxModifier) -> Self {
        Some(m).into()
    }
}

impl Modifier {
    pub fn linux(self) -> Option<LinuxModifier> {
        match self {
            Self::Shift => Some(LinuxModifier::Shift),
            Self::Control => Some(LinuxModifier::Control),
            Self::Alt => Some(LinuxModifier::Alt),
            Self::Super => Some(LinuxModifier::Super),
            Self::AltGr => Some(LinuxModifier::AltGr),
            Self::None => None,
        }
    }
}

/// `[input.scroll]`: `lain_input::ScrollConfig`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ScrollSection {
    /// Whose kinetic continuation follows a trackpad scroll (`lain_input::Momentum`).
    pub momentum: MomentumConfig,
    /// The source of trackpad scrolls (`ScrollConfig::phased_source`).
    pub source: SourceConfig,
    /// `client` momentum only: how long after the last delta the held-back stop goes out.
    pub client_stop_delay_ms: u64,
}

impl Default for ScrollSection {
    fn default() -> Self {
        InputSection::default().scroll
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MomentumConfig {
    Desktop,
    Client,
}

impl From<Momentum> for MomentumConfig {
    fn from(m: Momentum) -> Self {
        match m {
            Momentum::Desktop => Self::Desktop,
            Momentum::Client => Self::Client,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SourceConfig {
    Finger,
    Continuous,
    Wheel,
}

impl From<ScrollSource> for SourceConfig {
    fn from(s: ScrollSource) -> Self {
        match s {
            ScrollSource::Finger => Self::Finger,
            ScrollSource::Continuous => Self::Continuous,
            ScrollSource::Wheel => Self::Wheel,
        }
    }
}

/// `lain_input::ZoomAction`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Zoom {
    CtrlWheel,
    CtrlKeys,
}

impl From<ZoomAction> for Zoom {
    fn from(z: ZoomAction) -> Self {
        match z {
            ZoomAction::CtrlWheel => Self::CtrlWheel,
            ZoomAction::CtrlKeys => Self::CtrlKeys,
        }
    }
}

/// One `[[input.command_shortcuts]]`: `lain_input::CommandShortcut`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ShortcutConfig {
    /// A HID keyboard-page usage (TOML takes hex: `0x2B` is Tab).
    pub usage: u16,
    pub hold: Modifier,
}

impl Config {
    /// The config at `path`: the defaults if there is no file, else the file, checked.
    pub fn load(path: &Path) -> Result<Config, ConfigError> {
        match std::fs::read_to_string(path) {
            Ok(text) => Self::parse(path, &text),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Config::default()),
            Err(source) => Err(ConfigError::Read { path: path.to_owned(), source }),
        }
    }

    /// `text`, read from `path` (named in errors), checked.
    pub fn parse(path: &Path, text: &str) -> Result<Config, ConfigError> {
        let config: Config = toml::from_str(text).map_err(|e| ConfigError::Parse {
            path: path.to_owned(),
            key: e.span().and_then(|span| key_at(text, span)),
            message: e.message().trim().to_owned(),
        })?;
        config.check().map_err(|(key, reason)| ConfigError::Invalid { path: path.to_owned(), key, reason })?;
        Ok(config)
    }

    /// The bounds of every value: `Err((key, reason))` for the first one out of them.
    fn check(&self) -> Result<(), (String, String)> {
        let bad = |key: &str, reason: String| Err((key.to_owned(), reason));
        let (lo, hi) = BITRATE_MBPS;
        if !(lo..=hi).contains(&self.bitrate_mbps) {
            return bad("bitrate_mbps", format!("must be between {lo} and {hi} Mb/s, not {}", self.bitrate_mbps));
        }
        let (lo, hi) = BARRIER_BAND;
        let band = self.barrier.band;
        if !(band.is_finite() && (lo..=hi).contains(&band)) {
            return bad("barrier.band", format!("must be between {lo} and {hi} logical pixels, not {band}"));
        }
        let (lo, hi) = PINCH_THRESHOLD;
        let t = self.input.pinch_threshold;
        if !(t.is_finite() && t > lo && t <= hi) {
            return bad("input.pinch_threshold", format!("must be above {lo} and at most {hi}, not {t}"));
        }
        let (lo, hi) = CLIENT_STOP_DELAY_MS;
        let delay = self.input.scroll.client_stop_delay_ms;
        if !(lo..=hi).contains(&delay) {
            return bad("input.scroll.client_stop_delay_ms", format!("must be between {lo} and {hi} ms, not {delay}"));
        }
        for (i, s) in self.input.command_shortcuts.iter().enumerate() {
            let key = format!("input.command_shortcuts[{i}]");
            if lain_input::keymap::evdev_key(s.usage).is_none() {
                return bad(
                    &format!("{key}.usage"),
                    format!("{:#04X} is no key lain maps on the HID keyboard page", s.usage),
                );
            }
            if s.hold == Modifier::None {
                return bad(&format!("{key}.hold"), "must name a modifier (shift, control, alt, super, altgr)".into());
            }
            if self.input.command_shortcuts[..i].iter().any(|o| o.usage == s.usage) {
                return bad(&format!("{key}.usage"), format!("{:#04X} is listed twice", s.usage));
            }
        }
        Ok(())
    }

    /// `lain_input::InputConfig` from `[input]`. The shortcuts are leaked once when they differ from the
    /// defaults (`InputConfig::command_shortcuts` is `&'static`): call this once per process.
    pub fn input_config(&self) -> InputConfig {
        let i = &self.input;
        let m = &i.modifiers;
        let shortcuts: Vec<CommandShortcut> = i
            .command_shortcuts
            .iter()
            .filter_map(|s| Some(CommandShortcut { usage: s.usage, hold: s.hold.linux()? }))
            .collect();
        let command_shortcuts: &'static [CommandShortcut] =
            if shortcuts == CommandShortcut::DEFAULTS { CommandShortcut::DEFAULTS } else { shortcuts.leak() };
        InputConfig {
            modifiers: ModifierMap {
                shift: m.shift.linux(),
                control: m.control.linux(),
                option: m.option.linux(),
                command: m.command.linux(),
                function: m.function.linux(),
            },
            scroll: ScrollConfig {
                momentum: match i.scroll.momentum {
                    MomentumConfig::Desktop => Momentum::Desktop,
                    MomentumConfig::Client => Momentum::Client,
                },
                phased_source: match i.scroll.source {
                    SourceConfig::Finger => ScrollSource::Finger,
                    SourceConfig::Continuous => ScrollSource::Continuous,
                    SourceConfig::Wheel => ScrollSource::Wheel,
                },
                client_stop_delay_ns: i.scroll.client_stop_delay_ms * 1_000_000,
            },
            zoom: match i.zoom {
                Zoom::CtrlWheel => ZoomAction::CtrlWheel,
                Zoom::CtrlKeys => ZoomAction::CtrlKeys,
            },
            pinch_threshold: i.pinch_threshold,
            swap_iso_keys: i.swap_iso_keys,
            command_shortcuts,
            allow_system_keys: i.allow_system_keys,
        }
    }

    /// `lain_gnome::Barrier` from `[barrier]`.
    pub fn barrier(&self) -> Barrier {
        Barrier { detour: self.barrier.detour, band: self.barrier.band }
    }

    /// The video pipeline's options: the defaults with the bitrate.
    pub fn pipeline_options(&self) -> PipelineOptions {
        PipelineOptions { average_bit_rate: self.bitrate_mbps * 1_000_000, ..PipelineOptions::default() }
    }
}

impl fmt::Display for Modifier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Shift => "shift",
            Self::Control => "control",
            Self::Alt => "alt",
            Self::Super => "super",
            Self::AltGr => "altgr",
            Self::None => "none",
        })
    }
}

/// The dotted key a parse error's span points at: the key itself (an unknown key), or the key whose value it
/// is, under the table header above it. `None` if the line has no key.
fn key_at(text: &str, span: std::ops::Range<usize>) -> Option<String> {
    let start = span.start.min(text.len());
    let line_start = text[..start].rfind('\n').map_or(0, |i| i + 1);
    let before = &text[line_start..start];
    let token = |s: &str| {
        s.rsplit(|c: char| c.is_whitespace() || matches!(c, '{' | ',' | '[' | ']'))
            .find(|t| !t.is_empty())
            .map(|t| t.trim_matches('"').to_owned())
    };
    let key = match before.rfind('=') {
        Some(eq) => token(&before[..eq])?,
        None => {
            let end = span.end.clamp(start, text.len());
            let own = text[start..end].trim().trim_matches('"');
            if own.is_empty() || own.starts_with('[') {
                return None;
            }
            own.to_owned()
        }
    };
    let table = text[..line_start]
        .lines()
        .rev()
        .map(str::trim)
        .find(|l| l.starts_with('['))
        .map(|l| l.trim_start_matches('[').split(']').next().unwrap_or_default().trim().to_owned());
    Some(match table {
        Some(t) if !t.is_empty() => format!("{t}.{key}"),
        _ => key,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Result<Config, ConfigError> {
        Config::parse(Path::new("/x/lain/config.toml"), text)
    }

    fn refused(text: &str) -> String {
        let e = parse(text).expect_err(text);
        e.to_string()
    }

    #[test]
    fn defaults_are_swifts_and_the_crates() {
        let c = Config::default();
        assert!(c.wifi);
        assert_eq!(c.bitrate_mbps, 60);
        assert_eq!(c.input_config(), InputConfig::default());
        assert_eq!(c.barrier(), Barrier::default());
        assert_eq!(c.pipeline_options(), PipelineOptions::default());
        assert!(!c.input.allow_system_keys);
        assert_eq!(parse("").unwrap(), c);
        assert_eq!(parse("# nothing\n[input]\n[input.scroll]\n[barrier]\n").unwrap(), c);
    }

    #[test]
    fn a_missing_file_means_the_defaults() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(Config::load(&dir.path().join("config.toml")).unwrap(), Config::default());
        let path = dir.path().join("dir.toml");
        std::fs::create_dir(&path).unwrap();
        assert!(matches!(Config::load(&path), Err(ConfigError::Read { .. })));
    }

    #[test]
    fn the_example_parses_to_the_defaults() {
        let text = include_str!("../config.example.toml");
        assert_eq!(parse(text).unwrap(), Config::default());
        // Every key in it is set (commented out), so uncommenting them all gives the defaults too.
        let uncommented: String = text
            .lines()
            .map(|l| l.strip_prefix("# ").filter(|l| l.contains(" = ") || l.starts_with('[')).unwrap_or(l))
            .map(|l| format!("{l}\n"))
            .collect();
        assert!(uncommented.contains("\nwifi = true\n"), "{uncommented}");
        assert_eq!(parse(&uncommented).unwrap(), Config::default(), "{uncommented}");
    }

    #[test]
    fn every_key() {
        let c = parse(
            r#"
wifi = false
bitrate_mbps = 90

[barrier]
detour = false
band = 40.5

[input]
zoom = "ctrl-keys"
pinch_threshold = 1.5
swap_iso_keys = true
allow_system_keys = true
command_shortcuts = [{ usage = 0x2B, hold = "super" }, { usage = 0x29, hold = "altgr" }]

[input.modifiers]
shift = "shift"
control = "super"
option = "alt"
command = "control"
function = "altgr"

[input.scroll]
momentum = "client"
source = "continuous"
client_stop_delay_ms = 300
"#,
        )
        .unwrap();
        assert!(!c.wifi);
        assert_eq!(c.pipeline_options().average_bit_rate, 90_000_000);
        assert_eq!(c.barrier(), Barrier { detour: false, band: 40.5 });
        let input = c.input_config();
        assert_eq!(
            input.modifiers,
            ModifierMap {
                shift: Some(LinuxModifier::Shift),
                control: Some(LinuxModifier::Super),
                option: Some(LinuxModifier::Alt),
                command: Some(LinuxModifier::Control),
                function: Some(LinuxModifier::AltGr),
            }
        );
        assert_eq!(
            input.scroll,
            ScrollConfig {
                momentum: Momentum::Client,
                phased_source: ScrollSource::Continuous,
                client_stop_delay_ns: 300_000_000
            }
        );
        assert_eq!(input.zoom, ZoomAction::CtrlKeys);
        assert_eq!(input.pinch_threshold, 1.5);
        assert!(input.swap_iso_keys && input.allow_system_keys);
        assert_eq!(
            input.command_shortcuts,
            &[
                CommandShortcut { usage: 0x2B, hold: LinuxModifier::Super },
                CommandShortcut { usage: 0x29, hold: LinuxModifier::AltGr }
            ]
        );

        // "none" maps a modifier to nothing; an empty list turns the shortcuts off; the array-of-tables form.
        let c = parse(
            "[input]\ncommand_shortcuts = []\n[input.modifiers]\ncommand = \"none\"\n[input.scroll]\nsource = \"wheel\"\n",
        )
        .unwrap();
        assert_eq!(c.input_config().modifiers.command, None);
        assert!(c.input_config().command_shortcuts.is_empty());
        assert_eq!(c.input_config().scroll.phased_source, ScrollSource::Wheel);
        let c = parse("[[input.command_shortcuts]]\nusage = 0x35\nhold = \"alt\"\n").unwrap();
        assert_eq!(c.input_config().command_shortcuts, &[CommandShortcut { usage: 0x35, hold: LinuxModifier::Alt }]);
    }

    #[test]
    fn unknown_keys_are_refused_by_name() {
        let e = refused("wifi = true\nwi_fi = false\n");
        assert!(e.starts_with("/x/lain/config.toml: wi_fi: unknown field `wi_fi`"), "{e}");
        let e = refused("[input]\nmodifier = {}\n");
        assert!(e.starts_with("/x/lain/config.toml: input.modifier: unknown field"), "{e}");
        let e = refused("[input.modifiers]\nhyper = \"super\"\n");
        assert!(e.starts_with("/x/lain/config.toml: input.modifiers.hyper: unknown field"), "{e}");
        let e = refused("[input.scroll]\nspeed = 2\n");
        assert!(e.contains("input.scroll.speed: unknown field"), "{e}");
        let e = refused("[video]\nfps = 60\n");
        assert!(e.contains("unknown field `video`"), "{e}");
        let e = refused("[[input.command_shortcuts]]\nusage = 0x2B\nhold = \"alt\"\nrepeat = true\n");
        assert!(e.contains("input.command_shortcuts.repeat: unknown field"), "{e}");
    }

    #[test]
    fn bad_values_are_refused_by_name() {
        let e = refused("wifi = \"yes\"\n");
        assert!(e.starts_with("/x/lain/config.toml: wifi: invalid type: string \"yes\", expected a boolean"), "{e}");
        let e = refused("bitrate_mbps = 60.5\n");
        assert!(e.contains("bitrate_mbps: invalid type"), "{e}");
        let e = refused("bitrate_mbps = -3\n");
        assert!(e.contains("bitrate_mbps: "), "{e}");
        let e = refused("bitrate_mbps = 0\n");
        assert_eq!(e, "/x/lain/config.toml: bitrate_mbps: must be between 1 and 200 Mb/s, not 0");
        assert!(refused("bitrate_mbps = 201\n").contains("not 201"));
        assert_eq!(parse("bitrate_mbps = 200\n").unwrap().bitrate_mbps, 200);
        let e = refused("[input.modifiers]\ncommand = \"meta\"\n");
        assert!(e.contains("input.modifiers.command: unknown variant `meta`"), "{e}");
        let e = refused("[input]\nzoom = \"ctrl_wheel\"\n");
        assert!(e.contains("input.zoom: unknown variant"), "{e}");
        let e = refused("[input]\npinch_threshold = 1.0\n");
        assert_eq!(e, "/x/lain/config.toml: input.pinch_threshold: must be above 1 and at most 4, not 1");
        assert!(refused("[input]\npinch_threshold = nan\n").contains("input.pinch_threshold"));
        assert!(refused("[barrier]\nband = -1.0\n").contains("barrier.band: must be between 0 and 200"));
        assert!(refused("[barrier]\nband = inf\n").contains("barrier.band"));
        assert!(refused("[input.scroll]\nclient_stop_delay_ms = 5000\n").contains("client_stop_delay_ms: must be"));
        let e = refused("[input.scroll]\nmomentum = 1\n");
        assert!(e.contains("input.scroll.momentum: wanted string"), "{e}");
        let e = refused("[input]\ncommand_shortcuts = [{ usage = 0x2B, hold = \"none\" }]\n");
        assert_eq!(
            e,
            "/x/lain/config.toml: input.command_shortcuts[0].hold: must name a modifier (shift, control, alt, super, altgr)"
        );
        let e = refused("[input]\ncommand_shortcuts = [{ usage = 0x00, hold = \"alt\" }]\n");
        assert!(e.contains("input.command_shortcuts[0].usage: 0x00 is no key"), "{e}");
        let e = refused(
            "[input]\ncommand_shortcuts = [{ usage = 0x2B, hold = \"alt\" }, { usage = 0x2B, hold = \"super\" }]\n",
        );
        assert!(e.contains("input.command_shortcuts[1].usage: 0x2B is listed twice"), "{e}");
        let e = refused("[input]\ncommand_shortcuts = [{ usage = 70000, hold = \"alt\" }]\n");
        assert!(e.contains("usage: "), "{e}");
        let e = refused("[input]\ncommand_shortcuts = [{ hold = \"alt\" }]\n");
        assert!(e.contains("missing field `usage`"), "{e}");
        let e = refused("wifi = true\nwifi = false\n");
        assert!(e.contains("/x/lain/config.toml: "), "{e}");
        let e = refused("this isn't toml");
        assert!(e.starts_with("/x/lain/config.toml: "), "{e}");
    }
}
