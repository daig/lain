//! The desktop's input settings from gsettings (Swift: `HostInputSettings.current`, read from macOS defaults
//! and TIS).
//!
//! [`SettingsSource::input_settings`] is synchronous and called at session start, so it returns a cached
//! copy. The cache is read with `gsettings get` once at start, and again whenever dconf announces a change
//! under the keys' paths (`ca.desrt.dconf.Writer.Notify` on the session bus). The subprocesses run on tokio's
//! process support, never on a worker's thread, and only then: not per call. gsettings rather than dconf
//! directly, because only gsettings knows the schemas' defaults for keys the owner never set.

use std::sync::{Arc, RwLock};

use futures::StreamExt;
use lain_platform::{InputSettings, SettingsSource};
use zbus::{Connection, MatchRule, MessageStream};

use crate::bus;
use crate::text_keys::TextKeys;

/// The current layout's [`TextKeys`], shared with [`GnomeInput`](crate::GnomeInput) and replaced whenever the
/// input sources change.
pub type SharedTextKeys = Arc<RwLock<Arc<TextKeys>>>;

/// GNOME's schema defaults, used when gsettings can't be read.
pub const DEFAULTS: InputSettings = InputSettings {
    double_click_ms: 400,
    key_repeat_delay_ms: 500,
    key_repeat_interval_ms: 30,
    input_source: String::new(),
};

const MOUSE: &str = "org.gnome.desktop.peripherals.mouse";
const KEYBOARD: &str = "org.gnome.desktop.peripherals.keyboard";
const SOURCES: &str = "org.gnome.desktop.input-sources";
/// The dconf paths of those schemas: a change notification under one refreshes the cache.
const WATCHED: [&str; 3] = [
    "/org/gnome/desktop/peripherals/mouse/",
    "/org/gnome/desktop/peripherals/keyboard/",
    "/org/gnome/desktop/input-sources/",
];

/// A gsettings `uint32`/`int32` as `gsettings get` prints it: `uint32 500`, `400`.
pub fn parse_uint(text: &str) -> Option<u32> {
    let t = text.trim();
    let t = t.strip_prefix("uint32 ").or_else(|| t.strip_prefix("int32 ")).unwrap_or(t);
    t.trim().parse().ok()
}

/// A GVariant text string literal: `'…'` or `"…"`, with backslash escapes. Returns it and the rest.
fn string_literal(text: &str) -> Option<(String, &str)> {
    let mut chars = text.char_indices();
    let (_, quote) = chars.next()?;
    if quote != '\'' && quote != '"' {
        return None;
    }
    let mut out = String::new();
    let mut escaped = false;
    for (i, c) in chars {
        if escaped {
            out.push(c);
            escaped = false;
        } else if c == '\\' {
            escaped = true;
        } else if c == quote {
            return Some((out, &text[i + c.len_utf8()..]));
        } else {
            out.push(c);
        }
    }
    None
}

/// An `a(ss)` as `gsettings get` prints it: `[('xkb', 'us+colemak'), ('ibus', 'mozc-jp')]`, `@a(ss) []`.
pub fn parse_pairs(text: &str) -> Option<Vec<(String, String)>> {
    let t = text.trim();
    let t = t.strip_prefix("@a(ss)").unwrap_or(t).trim();
    let mut rest = t.strip_prefix('[')?.trim_start();
    let mut out = Vec::new();
    loop {
        if let Some(r) = rest.strip_prefix(']') {
            return r.trim().is_empty().then_some(out);
        }
        rest = rest.strip_prefix('(')?.trim_start();
        let (a, r) = string_literal(rest)?;
        rest = r.trim_start().strip_prefix(',')?.trim_start();
        let (b, r) = string_literal(rest)?;
        rest = r.trim_start().strip_prefix(')')?.trim_start();
        out.push((a, b));
        rest = rest.strip_prefix(',').unwrap_or(rest).trim_start();
    }
}

/// The current input source's identifier, `type:id` (e.g. `xkb:us+colemak`): the most recently used source
/// that is still configured (GNOME Shell keeps `mru-sources` in use order), else the first configured one,
/// else empty. The client only displays it (`HelloAck.macInputSource`).
pub fn input_source(sources: &[(String, String)], mru: &[(String, String)]) -> String {
    mru.iter()
        .find(|m| sources.contains(m))
        .or_else(|| sources.first())
        .map(|(kind, id)| format!("{kind}:{id}"))
        .unwrap_or_default()
}

/// Whether a dconf change notification `(prefix, changes)` touches one of the watched schemas.
pub fn touches_watched(prefix: &str, changes: &[String]) -> bool {
    let paths: Vec<String> = if changes.is_empty() {
        vec![prefix.to_owned()]
    } else {
        changes.iter().map(|c| format!("{prefix}{c}")).collect()
    };
    paths.iter().any(|p| WATCHED.iter().any(|w| p.starts_with(w) || w.starts_with(p.as_str())))
}

async fn gsettings_get(schema: &str, key: &str) -> Option<String> {
    let out = tokio::process::Command::new("gsettings").args(["get", schema, key]).output().await.ok()?;
    if !out.status.success() {
        tracing::debug!(schema, key, "gsettings get failed: {}", String::from_utf8_lossy(&out.stderr).trim());
        return None;
    }
    String::from_utf8(out.stdout).ok()
}

/// An `as` as `gsettings get` prints it: `['caps:backspace', 'compose:ralt']`, `@as []`.
pub fn parse_strings(text: &str) -> Option<Vec<String>> {
    let t = text.trim();
    let t = t.strip_prefix("@as").unwrap_or(t).trim();
    let mut rest = t.strip_prefix('[')?.trim_start();
    let mut out = Vec::new();
    loop {
        if let Some(r) = rest.strip_prefix(']') {
            return r.trim().is_empty().then_some(out);
        }
        let (s, r) = string_literal(rest)?;
        out.push(s);
        rest = r.trim_start();
        rest = rest.strip_prefix(',').unwrap_or(rest).trim_start();
    }
}

/// The XKB layout id of the current input source (`us+colemak`), or `None` for a source that isn't XKB.
pub fn current_xkb(sources: &[(String, String)], mru: &[(String, String)]) -> Option<String> {
    input_source(sources, mru).strip_prefix("xkb:").map(str::to_owned)
}

/// The key table for the current input source and `xkb-options`, read now.
pub async fn read_text_keys() -> TextKeys {
    let pairs =
        |key| async move { gsettings_get(SOURCES, key).await.as_deref().and_then(parse_pairs).unwrap_or_default() };
    let (sources, mru) = (pairs("sources").await, pairs("mru-sources").await);
    let options = gsettings_get(SOURCES, "xkb-options").await.as_deref().and_then(parse_strings).unwrap_or_default();
    let keys = TextKeys::build(current_xkb(&sources, &mru).as_deref(), &options);
    tracing::info!(layout = keys.source, characters = keys.len(), "typed text: the keyboard layout");
    keys
}

/// Reads the settings now; each key that can't be read keeps GNOME's default.
pub async fn read() -> InputSettings {
    let uint = |schema, key, default| async move {
        gsettings_get(schema, key).await.as_deref().and_then(parse_uint).unwrap_or(default)
    };
    let pairs =
        |key| async move { gsettings_get(SOURCES, key).await.as_deref().and_then(parse_pairs).unwrap_or_default() };
    let sources = pairs("sources").await;
    let mru = pairs("mru-sources").await;
    InputSettings {
        double_click_ms: uint(MOUSE, "double-click", DEFAULTS.double_click_ms).await,
        key_repeat_delay_ms: uint(KEYBOARD, "delay", DEFAULTS.key_repeat_delay_ms).await,
        key_repeat_interval_ms: uint(KEYBOARD, "repeat-interval", DEFAULTS.key_repeat_interval_ms).await,
        input_source: input_source(&sources, &mru),
    }
}

/// The settings source (Swift: `HostInputSettings.current`).
#[derive(Debug, Clone)]
pub struct GnomeSettings {
    current: Arc<RwLock<InputSettings>>,
    text_keys: SharedTextKeys,
}

impl SettingsSource for GnomeSettings {
    fn input_settings(&self) -> InputSettings {
        self.current.read().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

impl GnomeSettings {
    /// Reads the settings, then keeps them current from dconf's change notifications.
    pub async fn start(conn: &Connection) -> Self {
        let current = Arc::new(RwLock::new(read().await));
        let text_keys = Arc::new(RwLock::new(Arc::new(read_text_keys().await)));
        tracing::debug!(settings = ?*current.read().unwrap_or_else(|e| e.into_inner()), "input settings");
        let rule = MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .interface(bus::DCONF_WRITER)
            .and_then(|b| b.member("Notify"))
            .map(|b| b.build());
        let stream = match rule {
            Ok(rule) => MessageStream::for_match_rule(rule, conn, Some(16)).await,
            Err(e) => Err(e),
        };
        match stream {
            Ok(stream) => {
                tokio::spawn(watch(stream, current.clone(), text_keys.clone()));
            }
            Err(e) => tracing::warn!("can't watch dconf; input settings are read once: {e}"),
        }
        Self { current, text_keys }
    }

    /// The current layout's key table, kept current: for [`GnomeInput`](crate::GnomeInput).
    pub fn text_keys(&self) -> SharedTextKeys {
        self.text_keys.clone()
    }

    /// Fixed settings, for tests of code that takes a `GnomeSettings`.
    pub fn fixed(settings: InputSettings) -> Self {
        Self { current: Arc::new(RwLock::new(settings)), text_keys: SharedTextKeys::default() }
    }
}

async fn watch(mut stream: MessageStream, current: Arc<RwLock<InputSettings>>, text_keys: SharedTextKeys) {
    while let Some(msg) = stream.next().await {
        let Ok(msg) = msg else { continue };
        let Ok((prefix, changes, _tag)) = msg.body().deserialize::<(String, Vec<String>, String)>() else { continue };
        if !touches_watched(&prefix, &changes) {
            continue;
        }
        let settings = read().await;
        tracing::debug!(?settings, "input settings changed");
        *current.write().unwrap_or_else(|e| e.into_inner()) = settings;
        let keys = Arc::new(read_text_keys().await);
        *text_keys.write().unwrap_or_else(|e| e.into_inner()) = keys;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_string_lists_and_the_xkb_source() {
        assert_eq!(
            parse_strings("['caps:backspace', 'compose:ralt']\n"),
            Some(vec!["caps:backspace".into(), "compose:ralt".into()])
        );
        assert_eq!(parse_strings("@as []"), Some(vec![]));
        let s = |a: &str, b: &str| (a.to_owned(), b.to_owned());
        assert_eq!(current_xkb(&[s("xkb", "us+colemak")], &[]).as_deref(), Some("us+colemak"));
        assert_eq!(current_xkb(&[s("ibus", "mozc-jp")], &[]), None);
    }

    #[test]
    fn parses_gsettings_numbers() {
        assert_eq!(parse_uint("uint32 500\n"), Some(500));
        assert_eq!(parse_uint("400\n"), Some(400));
        assert_eq!(parse_uint("int32 30"), Some(30));
        assert_eq!(parse_uint("true"), None);
    }

    #[test]
    fn parses_input_sources() {
        assert_eq!(parse_pairs("[('xkb', 'us+colemak')]\n"), Some(vec![("xkb".into(), "us+colemak".into())]));
        assert_eq!(parse_pairs("@a(ss) []\n"), Some(vec![]));
        assert_eq!(
            parse_pairs("[('xkb', 'de'), ('ibus', \"mozc-jp\"), ('xkb', 'it\\'s')]"),
            Some(vec![("xkb".into(), "de".into()), ("ibus".into(), "mozc-jp".into()), ("xkb".into(), "it's".into())])
        );
        assert_eq!(parse_pairs("[('xkb', 'de')"), None);
        assert_eq!(parse_pairs("nonsense"), None);
    }

    #[test]
    fn the_input_source_is_the_most_recent_configured_one() {
        let s = |k: &str, v: &str| (k.to_owned(), v.to_owned());
        let sources = vec![s("xkb", "us+colemak"), s("xkb", "de")];
        assert_eq!(input_source(&sources, &[]), "xkb:us+colemak");
        assert_eq!(input_source(&sources, &[s("xkb", "de"), s("xkb", "us+colemak")]), "xkb:de");
        assert_eq!(input_source(&sources, &[s("xkb", "fr")]), "xkb:us+colemak");
        assert_eq!(input_source(&[], &[]), "");
    }

    #[test]
    fn dconf_notifications_for_the_watched_keys() {
        assert!(touches_watched("/org/gnome/desktop/peripherals/keyboard/delay", &[]));
        assert!(touches_watched("/org/gnome/desktop/input-sources/", &["mru-sources".into()]));
        assert!(touches_watched("/org/gnome/desktop/", &["peripherals/mouse/double-click".into()]));
        // A reset of a whole parent directory.
        assert!(touches_watched("/org/gnome/", &[]));
        assert!(!touches_watched("/org/gnome/desktop/interface/", &["gtk-theme".into()]));
        assert!(!touches_watched("/org/gnome/desktop/peripherals/touchpad/speed", &[]));
    }

    #[test]
    fn fixed_settings() {
        let s = GnomeSettings::fixed(DEFAULTS);
        assert_eq!(s.input_settings().double_click_ms, 400);
    }
}
