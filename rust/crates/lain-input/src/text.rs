//! v6 `TextInput`: text for the desktop to type as if on its keyboard, whatever its layout (dictation, the
//! client's on-screen keyboard). Swift: `InputInjector.text(_:modifiers:)`.
//!
//! The Mac posts each character as a key event carrying the character itself, so the layout doesn't matter.
//! Wayland has no such event (Mutter has no virtual-keyboard protocol, and its `NotifyKeyboardKeysym` mistypes
//! level 4 and silently drops characters the layout lacks, Mutter 50.1), so each character is typed as the
//! key that types it in the current layout ([`TextKey`], from the platform), with Shift and the level-3 key
//! (AltGr) pressed around it as needed. A character the layout lacks is replaced by its plain form where
//! there is one ([`plain`]: ’ → ', “ → ", — → -, … → ...), else skipped.
//!
//! - **Plain text** (no modifiers): only the level's own Shift and AltGr are pressed, nothing the client holds.
//! - **With modifiers** (Control-C as text): each character is the key that types it (or its lowercase form),
//!   pressed with the [`ModifierMap`](crate::ModifierMap)'s modifiers for the flags held, and Shift where the
//!   character needs it, as Swift's `key.shift ? modifiers.union(.shift)`.
//! - A line feed (or CR LF, or CR) is the Return key and a tab the Tab key, either way.
//! - Every key is released before the next is pressed: nothing stays held.

use lain_platform::{InputAction, TextKey};

use crate::evdev::{KEY_ENTER, KEY_LEFTSHIFT, KEY_TAB};
use crate::modifiers::{LinuxModifier, ModifierSet};

/// The plain characters for a typographic one a layout may lack (dictation writes curly quotes and dashes).
pub fn plain(c: char) -> Option<&'static str> {
    Some(match c {
        '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}' | '\u{2032}' | '\u{02BC}' => "'",
        '\u{201C}' | '\u{201D}' | '\u{201E}' | '\u{201F}' | '\u{2033}' | '«' | '»' => "\"",
        '\u{2010}' | '\u{2011}' | '\u{2012}' | '\u{2013}' | '\u{2014}' | '\u{2015}' | '\u{2212}' => "-",
        '\u{2026}' => "...",
        '\u{00A0}' | '\u{2007}' | '\u{202F}' | '\u{2009}' | '\u{200A}' => " ",
        '\u{2022}' => "*",
        _ => return None,
    })
}

/// Appends the actions that type `text` with `held` pressed around each key (empty for plain text), the
/// keys from `lookup`. Returns how many characters were skipped (neither the layout nor [`plain`] had them).
pub fn type_text(
    text: &str,
    held: ModifierSet,
    lookup: impl Fn(char) -> Option<TextKey>,
    out: &mut Vec<InputAction>,
) -> usize {
    let mut skipped = 0;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        let special = |code| TextKey { code, shift: false, level3: None };
        match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                tap(special(KEY_ENTER), held, out);
            }
            '\n' => tap(special(KEY_ENTER), held, out),
            '\t' => tap(special(KEY_TAB), held, out),
            _ => {
                let key = lookup(c).or_else(|| {
                    // A chord's character may be typed as its key's lowercase form (Control-C as "C").
                    if held.is_empty() { None } else { c.to_lowercase().next().and_then(&lookup) }
                });
                if let Some(key) = key {
                    tap(key, held, out);
                } else if let Some(p) = plain(c) {
                    for pc in p.chars() {
                        match lookup(pc) {
                            Some(key) => tap(key, held, out),
                            None => skipped += 1,
                        }
                    }
                } else {
                    skipped += 1;
                }
            }
        }
    }
    skipped
}

/// One key typed: `held`, then Shift and level 3 as the key needs, the key, and all released in reverse.
fn tap(key: TextKey, held: ModifierSet, out: &mut Vec<InputAction>) {
    let mut pressed: Vec<u16> = held.iter().map(LinuxModifier::key).collect();
    if key.shift && !held.contains(LinuxModifier::Shift) {
        pressed.push(KEY_LEFTSHIFT);
    }
    if let Some(l3) = key.level3 {
        pressed.push(l3);
    }
    for &code in &pressed {
        out.push(InputAction::Key { code, down: true });
    }
    out.push(InputAction::Key { code: key.code, down: true });
    out.push(InputAction::Key { code: key.code, down: false });
    for &code in pressed.iter().rev() {
        out.push(InputAction::Key { code, down: false });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lain_platform::InputBackend;
    use lain_platform::fake::FakeInput;

    fn typed(text: &str, held: ModifierSet) -> (Vec<(u16, bool)>, usize) {
        let input = FakeInput::default();
        let mut out = Vec::new();
        let skipped = type_text(text, held, |c| input.text_key(c), &mut out);
        let keys = out
            .into_iter()
            .map(|a| match a {
                InputAction::Key { code, down } => (code, down),
                other => panic!("{other:?}"),
            })
            .collect();
        (keys, skipped)
    }

    fn taps(codes: &[u16]) -> Vec<(u16, bool)> {
        codes.iter().flat_map(|&c| [(c, true), (c, false)]).collect()
    }

    #[test]
    fn plain_text_is_each_characters_key_with_its_level() {
        // h i (space) on a US layout.
        assert_eq!(typed("hi ", ModifierSet::EMPTY), (taps(&[35, 23, 57]), 0));
        // A capital: Shift around it.
        assert_eq!(typed("H", ModifierSet::EMPTY).0, [(42, true), (35, true), (35, false), (42, false)]);
        // Level 3 (AltGr) and level 4 (AltGr+Shift), which Mutter's keysym call mistypes.
        assert_eq!(typed("é", ModifierSet::EMPTY).0, [(100, true), (18, true), (18, false), (100, false)]);
        assert_eq!(
            typed("É", ModifierSet::EMPTY).0,
            [(42, true), (100, true), (18, true), (18, false), (100, false), (42, false)]
        );
    }

    #[test]
    fn line_feeds_and_tabs_are_return_and_tab() {
        assert_eq!(typed("a\nb", ModifierSet::EMPTY).0, taps(&[30, KEY_ENTER, 48]));
        assert_eq!(typed("\r\n\r\t", ModifierSet::EMPTY).0, taps(&[KEY_ENTER, KEY_ENTER, KEY_TAB]));
    }

    #[test]
    fn typographic_characters_the_layout_lacks_are_typed_plain() {
        // Dictation's "don’t", “quoted” — and … on a US layout.
        let (keys, skipped) = typed("don\u{2019}t", ModifierSet::EMPTY);
        assert_eq!((keys, skipped), (taps(&[32, 24, 49, 40, 20]), 0));
        let (keys, _) = typed("\u{201C}a\u{201D}", ModifierSet::EMPTY);
        assert_eq!(keys.len(), 4 + 2 + 4, "Shift+' around a");
        assert_eq!(typed("\u{2014}", ModifierSet::EMPTY).0, taps(&[12]));
        assert_eq!(typed("\u{2026}", ModifierSet::EMPTY).0, taps(&[52, 52, 52]));
    }

    #[test]
    fn what_no_layout_types_is_skipped() {
        let (keys, skipped) = typed("a✓😀b", ModifierSet::EMPTY);
        assert_eq!((keys, skipped), (taps(&[30, 48]), 2));
    }

    #[test]
    fn with_modifiers_each_character_is_a_chord() {
        let mut ctrl = ModifierSet::EMPTY;
        ctrl.insert(LinuxModifier::Control);
        // Control-c, and "C" typed as Control+Shift+c.
        assert_eq!(typed("c", ctrl).0, [(29, true), (46, true), (46, false), (29, false)]);
        assert_eq!(typed("C", ctrl).0, [(29, true), (42, true), (46, true), (46, false), (42, false), (29, false)]);
        // Shift held already isn't pressed twice.
        let mut ctrl_shift = ctrl;
        ctrl_shift.insert(LinuxModifier::Shift);
        assert_eq!(typed("C", ctrl_shift).0.iter().filter(|(c, d)| *c == 42 && *d).count(), 1);
        // Return with modifiers holds them too.
        assert_eq!(typed("\n", ctrl).0, [(29, true), (KEY_ENTER, true), (KEY_ENTER, false), (29, false)]);
    }
}
