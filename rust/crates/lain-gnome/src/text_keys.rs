//! Which key types each character in the desktop's current keyboard layout (v6 `TextInput`), from
//! libxkbcommon. No Swift counterpart: the Mac posts characters themselves (`keyboardSetUnicodeString`);
//! Wayland has no such event, so `lain-input` types each character as its key (see `lain_input::text`).
//!
//! The layout is compiled from the same RMLVO names GNOME gives Mutter: rules `evdev`, model `pc105`, the
//! current input source's layout and variant (`xkb:us+colemak` → `us`, `colemak`), and the `xkb-options`. An
//! input source that isn't XKB (an IBus engine) types through the `us` layout, as GNOME's IBus engines do by
//! default. For each character the first key that types it is kept, preferring the lowest level: level 1 as
//! is, level 2 with Shift, level 3 with the layout's `ISO_Level3_Shift` key (AltGr), level 4 with both. Levels
//! reached otherwise (Level5, Caps-only types) are left out.

use std::collections::HashMap;

use lain_platform::TextKey;
use xkbcommon::xkb;

/// The characters of one layout and the keys that type them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TextKeys {
    /// What the table was built from (`us+colemak`, options), for the log.
    pub source: String,
    keys: HashMap<char, TextKey>,
}

/// evdev codes are XKB keycodes less 8.
const EVDEV_OFFSET: u32 = 8;

impl TextKeys {
    /// The key for `c`, if the layout types it.
    pub fn get(&self, c: char) -> Option<TextKey> {
        self.keys.get(&c).copied()
    }

    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// The table for GNOME's input source id (`us+colemak`, `de`; `None` or a non-XKB source: `us`) with
    /// `options` (`caps:backspace`, …). Empty if libxkbcommon can't compile it.
    pub fn build(xkb_source: Option<&str>, options: &[String]) -> Self {
        let id = xkb_source.unwrap_or("us");
        let (layout, variant) = id.split_once('+').unwrap_or((id, ""));
        let source = if options.is_empty() { id.to_owned() } else { format!("{id} ({})", options.join(",")) };
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let options = (!options.is_empty()).then(|| options.join(","));
        let Some(keymap) = xkb::Keymap::new_from_names(
            &context,
            "evdev",
            "pc105",
            layout,
            variant,
            options,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        ) else {
            tracing::warn!(source, "libxkbcommon can't compile the keyboard layout: typed text is left out");
            return Self { source, keys: HashMap::new() };
        };
        Self { keys: table(&keymap), source }
    }
}

/// The modifier mask a key sets while held, and its keycode: `preferred` (an evdev code) if its level 1 keysym is
/// `keysym`, else the first key whose is (some layouts also bind it to virtual keycodes, like `<LVL3>`).
fn modifier_key(keymap: &xkb::Keymap, keysym: u32, preferred: u16) -> Option<(xkb::Keycode, xkb::ModMask)> {
    let mask_of = |code: xkb::Keycode| {
        let mut state = xkb::State::new(keymap);
        state.update_key(code, xkb::KeyDirection::Down);
        state.serialize_mods(xkb::STATE_MODS_DEPRESSED)
    };
    let types = |code: xkb::Keycode| keymap.key_get_syms_by_level(code, 0, 0).iter().any(|s| s.raw() == keysym);
    let preferred = xkb::Keycode::new(u32::from(preferred) + EVDEV_OFFSET);
    if types(preferred) && mask_of(preferred) != 0 {
        return Some((preferred, mask_of(preferred)));
    }
    let mut found = None;
    keymap.key_for_each(|_, code| {
        if found.is_none() && types(code) && mask_of(code) != 0 {
            found = Some((code, mask_of(code)));
        }
    });
    found
}

fn table(keymap: &xkb::Keymap) -> HashMap<char, TextKey> {
    let shift = modifier_key(keymap, xkb::keysyms::KEY_Shift_L, 42); // KEY_LEFTSHIFT
    let level3 = modifier_key(keymap, xkb::keysyms::KEY_ISO_Level3_Shift, 100); // KEY_RIGHTALT
    let shift_mask = shift.map_or(0, |(_, m)| m);
    let level3_mask = level3.map_or(0, |(_, m)| m);
    let level3_code = level3.map(|(code, _)| (code.raw() - EVDEV_OFFSET) as u16);
    // (Shift, level 3) for a mask a level is reached with, if that is one lain can press.
    let reach = |mask: xkb::ModMask| -> Option<(bool, bool)> {
        let options = [
            (true, false, false),
            (shift_mask != 0, true, false),
            (level3_mask != 0, false, true),
            (shift_mask != 0 && level3_mask != 0, true, true),
        ];
        options
            .into_iter()
            .filter(|&(possible, ..)| possible)
            .map(|(_, s, l3)| (s, l3))
            .find(|&(s, l3)| mask == (if s { shift_mask } else { 0 }) | (if l3 { level3_mask } else { 0 }))
    };
    // Best per character: fewest modifiers, then the lowest key code.
    let mut best: HashMap<char, (u8, TextKey)> = HashMap::new();
    keymap.key_for_each(|keymap, code| {
        let Some(evdev) = code.raw().checked_sub(EVDEV_OFFSET).and_then(|c| u16::try_from(c).ok()) else { return };
        for level in 0..keymap.num_levels_for_key(code, 0) {
            let syms = keymap.key_get_syms_by_level(code, 0, level);
            let [sym] = syms else { continue };
            let Some(c) = char::from_u32(xkb::keysym_to_utf32(*sym)).filter(|c| *c != '\0' && !c.is_control()) else {
                continue;
            };
            let mut masks = [0; 8];
            let n = keymap.key_get_mods_for_level(code, 0, level, &mut masks);
            let Some((s, l3)) = masks[..n.min(masks.len())]
                .iter()
                .filter_map(|&m| reach(m))
                .min_by_key(|&(s, l3)| u8::from(s) + 2 * u8::from(l3))
            else {
                continue;
            };
            let cost = u8::from(s) + 2 * u8::from(l3);
            let key = TextKey { code: evdev, shift: s, level3: if l3 { level3_code } else { None } };
            match best.get(&c) {
                Some(&(c0, k0)) if (c0, k0.code) <= (cost, evdev) => {}
                _ => {
                    best.insert(c, (cost, key));
                }
            }
        }
    });
    best.into_iter().map(|(c, (_, k))| (c, k)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: u16, shift: bool, level3: Option<u16>) -> Option<TextKey> {
        Some(TextKey { code, shift, level3 })
    }

    #[test]
    fn us_types_ascii_with_shift() {
        let us = TextKeys::build(Some("us"), &[]);
        assert_eq!(us.get('a'), key(30, false, None));
        assert_eq!(us.get('A'), key(30, true, None));
        assert_eq!(us.get('1'), key(2, false, None), "the main row's digit, not the keypad's");
        assert_eq!(us.get('!'), key(2, true, None));
        assert_eq!(us.get(' '), key(57, false, None));
        assert_eq!(us.get('\''), key(40, false, None));
        assert_eq!(us.get('é'), None);
        assert_eq!(us.get('\u{2019}'), None, "no typographic apostrophe on plain US");
    }

    #[test]
    fn colemak_reaches_levels_three_and_four_with_altgr() {
        let colemak = TextKeys::build(Some("us+colemak"), &["caps:backspace".into()]);
        // Colemak: f on AD03 (evdev 18), e on AC… (`k` key, 37).
        assert_eq!(colemak.get('f'), key(18, false, None));
        assert_eq!(colemak.get('e'), key(37, false, None));
        // AltGr is Right Alt (evdev 100): ’ on AltGr+0 (level 3), ” on AltGr+Shift+0 (level 4), — on AltGr+Shift+-.
        assert_eq!(colemak.get('\u{2019}'), key(11, false, Some(100)));
        assert_eq!(colemak.get('\u{201D}'), key(11, true, Some(100)));
        assert_eq!(colemak.get('\u{2014}'), key(12, true, Some(100)));
        assert!(colemak.len() > 150, "{} characters", colemak.len());
    }

    #[test]
    fn a_layout_libxkbcommon_cant_compile_types_nothing() {
        assert!(TextKeys::build(Some("no-such-layout"), &[]).is_empty());
    }
}
