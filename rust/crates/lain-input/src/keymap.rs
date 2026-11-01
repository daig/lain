//! HID usage → evdev key code. Swift: `MacKeyCode` (which maps the same usages to Carbon `kVK_*` codes).
//!
//! The table for usage page 7 (Keyboard/Keypad) is the Linux kernel's own, `hid_keyboard[]` in
//! `drivers/hid/hid-input.c`, so a key reaches the desktop exactly as it would from a USB keyboard plugged
//! into this machine. Usages the kernel maps to `KEY_UNKNOWN` (`unk`) or ignores (`0`) have no code here.
//!
//! Intended differences from `MacKeyCode`, all because Linux keeps the PC meaning of a key where the Mac
//! renames it:
//! - Print Screen, Scroll Lock and Pause (`0x46`–`0x48`) are `KEY_SYSRQ`, `KEY_SCROLLLOCK` and `KEY_PAUSE`, not
//!   F13–F15.
//! - Insert (`0x49`) is `KEY_INSERT`, not Help.
//! - Keypad Num Lock (`0x53`, the Mac's keypad Clear) is `KEY_NUMLOCK`, which toggles the desktop's Num Lock.
//!   The keypad then follows that lock state, which is the desktop's (shared with its local keyboard) and
//!   which neither lain-input nor the client can see. GNOME starts with Num Lock off
//!   (`org.gnome.desktop.peripherals.keyboard numlock-state`), and XKB's keypad keys are `KEYPAD`-typed
//!   (`<KP7> = [KP_Home, KP_7]`), so a keypad digit types Home, End or an arrow until Num Lock is on; on the
//!   Mac the keypad always types digits and Clear is an ordinary key. `KEY_NUMLOCK` is kept deliberately: it
//!   is how a PC keyboard on the iPad turns digits on. A Mac-like keypad is a desktop setting (the XKB option
//!   `numpad:mac`, or `numlock-state` true), for `lain-gnome`/`lain-hostd` to offer or check, not this table.
//!   Only external keyboards are affected: the iPad's Magic Keyboard has no keypad.
//! - Every page-7 usage the kernel knows is in the table, including those `MacKeyCode` lacks (F21–F24, the
//!   editing keys `0x74`–`0x7E`, the JIS/Korean keys `0x88`, `0x8A`–`0x8C`, `0x92`–`0x94`, and the
//!   non-standard media usages `0xE8`–`0xFB` the kernel accepts). But the router drops the [`SYSTEM_KEYS`] by
//!   default, as Swift drops them (`MacKeyCode` has no `0x66` and nothing from `0xE8`): Power (`0x66`), Sleep
//!   (`0xF8`), Coffee, GNOME's screen lock (`0xF9`), and Eject (`0xEC`), which gnome-settings-daemon turns
//!   into a power action, a suspend (ending the session the input came from, with no way to wake the host
//!   from the iPad), a lock or an eject.
//! - The Globe/fn key (consumer `0x29D`, Apple top-case `0x03`) is a modifier, handled by
//!   [`ModifierMap`](crate::ModifierMap) (Function, mapped to nothing by default), never a key code.
//!
//! JIS: International1 (`0x87`, ろ) is `KEY_RO`, International3 (`0x89`, ¥) `KEY_YEN`, Keypad `,` (`0x85`)
//! `KEY_KPCOMMA`, LANG1 (`0x90`, かな) `KEY_HANGEUL` and LANG2 (`0x91`, 英数) `KEY_HANJA`, as the kernel maps
//! them; the desktop's XKB layout gives them their meaning.

use crate::evdev::*;

/// HID usage page 7, Keyboard/Keypad. Swift: `PhysicalKey.keyboardPage`.
pub const KEYBOARD_PAGE: u16 = 0x07;
/// HID usage page 12, Consumer (the Globe key is `0x29D` there). Swift: `PhysicalKey.consumerPage`.
pub const CONSUMER_PAGE: u16 = 0x0C;
/// Apple's vendor top-case page (Apple keyboards' fn is `0x03`). Swift: `PhysicalKey.appleVendorTopCasePage`.
pub const APPLE_VENDOR_TOP_CASE_PAGE: u16 = 0xFF;

/// The kernel's `hid_keyboard[]`, by name. Index: page-7 usage; 0: no key.
static HID_KEYBOARD: [u16; 256] = build();

const fn build() -> [u16; 256] {
    let mut t = [0u16; 256];
    // Letters A–Z.
    t[0x04] = KEY_A;
    t[0x05] = KEY_B;
    t[0x06] = KEY_C;
    t[0x07] = KEY_D;
    t[0x08] = KEY_E;
    t[0x09] = KEY_F;
    t[0x0A] = KEY_G;
    t[0x0B] = KEY_H;
    t[0x0C] = KEY_I;
    t[0x0D] = KEY_J;
    t[0x0E] = KEY_K;
    t[0x0F] = KEY_L;
    t[0x10] = KEY_M;
    t[0x11] = KEY_N;
    t[0x12] = KEY_O;
    t[0x13] = KEY_P;
    t[0x14] = KEY_Q;
    t[0x15] = KEY_R;
    t[0x16] = KEY_S;
    t[0x17] = KEY_T;
    t[0x18] = KEY_U;
    t[0x19] = KEY_V;
    t[0x1A] = KEY_W;
    t[0x1B] = KEY_X;
    t[0x1C] = KEY_Y;
    t[0x1D] = KEY_Z;
    // Digits 1–9, 0.
    t[0x1E] = KEY_1;
    t[0x1F] = KEY_2;
    t[0x20] = KEY_3;
    t[0x21] = KEY_4;
    t[0x22] = KEY_5;
    t[0x23] = KEY_6;
    t[0x24] = KEY_7;
    t[0x25] = KEY_8;
    t[0x26] = KEY_9;
    t[0x27] = KEY_0;
    // Return, Escape, Backspace, Tab, Space, - = [ ] \, non-US # (the kernel gives it KEY_BACKSLASH too), ; ' ` , . /
    t[0x28] = KEY_ENTER;
    t[0x29] = KEY_ESC;
    t[0x2A] = KEY_BACKSPACE;
    t[0x2B] = KEY_TAB;
    t[0x2C] = KEY_SPACE;
    t[0x2D] = KEY_MINUS;
    t[0x2E] = KEY_EQUAL;
    t[0x2F] = KEY_LEFTBRACE;
    t[0x30] = KEY_RIGHTBRACE;
    t[0x31] = KEY_BACKSLASH;
    t[0x32] = KEY_BACKSLASH;
    t[0x33] = KEY_SEMICOLON;
    t[0x34] = KEY_APOSTROPHE;
    t[0x35] = KEY_GRAVE;
    t[0x36] = KEY_COMMA;
    t[0x37] = KEY_DOT;
    t[0x38] = KEY_SLASH;
    t[0x39] = KEY_CAPSLOCK;
    // F1–F12.
    t[0x3A] = KEY_F1;
    t[0x3B] = KEY_F2;
    t[0x3C] = KEY_F3;
    t[0x3D] = KEY_F4;
    t[0x3E] = KEY_F5;
    t[0x3F] = KEY_F6;
    t[0x40] = KEY_F7;
    t[0x41] = KEY_F8;
    t[0x42] = KEY_F9;
    t[0x43] = KEY_F10;
    t[0x44] = KEY_F11;
    t[0x45] = KEY_F12;
    // Print Screen, Scroll Lock, Pause, Insert, Home, Page Up, Delete, End, Page Down, arrows.
    t[0x46] = KEY_SYSRQ;
    t[0x47] = KEY_SCROLLLOCK;
    t[0x48] = KEY_PAUSE;
    t[0x49] = KEY_INSERT;
    t[0x4A] = KEY_HOME;
    t[0x4B] = KEY_PAGEUP;
    t[0x4C] = KEY_DELETE;
    t[0x4D] = KEY_END;
    t[0x4E] = KEY_PAGEDOWN;
    t[0x4F] = KEY_RIGHT;
    t[0x50] = KEY_LEFT;
    t[0x51] = KEY_DOWN;
    t[0x52] = KEY_UP;
    // Keypad. Num Lock toggles the desktop's shared lock state, which the keypad digits follow (module docs).
    t[0x53] = KEY_NUMLOCK;
    t[0x54] = KEY_KPSLASH;
    t[0x55] = KEY_KPASTERISK;
    t[0x56] = KEY_KPMINUS;
    t[0x57] = KEY_KPPLUS;
    t[0x58] = KEY_KPENTER;
    t[0x59] = KEY_KP1;
    t[0x5A] = KEY_KP2;
    t[0x5B] = KEY_KP3;
    t[0x5C] = KEY_KP4;
    t[0x5D] = KEY_KP5;
    t[0x5E] = KEY_KP6;
    t[0x5F] = KEY_KP7;
    t[0x60] = KEY_KP8;
    t[0x61] = KEY_KP9;
    t[0x62] = KEY_KP0;
    t[0x63] = KEY_KPDOT;
    // ISO key beside left Shift, Application (Menu), Power (a system key), Keypad =.
    t[0x64] = KEY_102ND;
    t[0x65] = KEY_COMPOSE;
    t[0x66] = KEY_POWER;
    t[0x67] = KEY_KPEQUAL;
    // F13–F24.
    t[0x68] = KEY_F13;
    t[0x69] = KEY_F14;
    t[0x6A] = KEY_F15;
    t[0x6B] = KEY_F16;
    t[0x6C] = KEY_F17;
    t[0x6D] = KEY_F18;
    t[0x6E] = KEY_F19;
    t[0x6F] = KEY_F20;
    t[0x70] = KEY_F21;
    t[0x71] = KEY_F22;
    t[0x72] = KEY_F23;
    t[0x73] = KEY_F24;
    // Execute, Help, Menu, Select, Stop, Again, Undo, Cut, Copy, Paste, Find, Mute, Volume Up, Volume Down.
    t[0x74] = KEY_OPEN;
    t[0x75] = KEY_HELP;
    t[0x76] = KEY_PROPS;
    t[0x77] = KEY_FRONT;
    t[0x78] = KEY_STOP;
    t[0x79] = KEY_AGAIN;
    t[0x7A] = KEY_UNDO;
    t[0x7B] = KEY_CUT;
    t[0x7C] = KEY_COPY;
    t[0x7D] = KEY_PASTE;
    t[0x7E] = KEY_FIND;
    t[0x7F] = KEY_MUTE;
    t[0x80] = KEY_VOLUMEUP;
    t[0x81] = KEY_VOLUMEDOWN;
    // Keypad , ; International1–6 (JIS ろ, かなカナ, ¥, 変換, 無変換, keypad JP ,); LANG1–5.
    t[0x85] = KEY_KPCOMMA;
    t[0x87] = KEY_RO;
    t[0x88] = KEY_KATAKANAHIRAGANA;
    t[0x89] = KEY_YEN;
    t[0x8A] = KEY_HENKAN;
    t[0x8B] = KEY_MUHENKAN;
    t[0x8C] = KEY_KPJPCOMMA;
    t[0x90] = KEY_HANGEUL;
    t[0x91] = KEY_HANJA;
    t[0x92] = KEY_KATAKANA;
    t[0x93] = KEY_HIRAGANA;
    t[0x94] = KEY_ZENKAKUHANKAKU;
    // Clear; keypad ( ); keypad Clear.
    t[0x9C] = KEY_DELETE;
    t[0xB6] = KEY_KPLEFTPAREN;
    t[0xB7] = KEY_KPRIGHTPAREN;
    t[0xD8] = KEY_DELETE;
    // Modifiers: left Ctrl, Shift, Alt, GUI, then the right ones.
    t[0xE0] = KEY_LEFTCTRL;
    t[0xE1] = KEY_LEFTSHIFT;
    t[0xE2] = KEY_LEFTALT;
    t[0xE3] = KEY_LEFTMETA;
    t[0xE4] = KEY_RIGHTCTRL;
    t[0xE5] = KEY_RIGHTSHIFT;
    t[0xE6] = KEY_RIGHTALT;
    t[0xE7] = KEY_RIGHTMETA;
    // Reserved usages some keyboards send for media keys; the kernel maps them.
    t[0xE8] = KEY_PLAYPAUSE;
    t[0xE9] = KEY_STOPCD;
    t[0xEA] = KEY_PREVIOUSSONG;
    t[0xEB] = KEY_NEXTSONG;
    t[0xEC] = KEY_EJECTCD;
    t[0xED] = KEY_VOLUMEUP;
    t[0xEE] = KEY_VOLUMEDOWN;
    t[0xEF] = KEY_MUTE;
    t[0xF0] = KEY_WWW;
    t[0xF1] = KEY_BACK;
    t[0xF2] = KEY_FORWARD;
    t[0xF3] = KEY_STOP;
    t[0xF4] = KEY_FIND;
    t[0xF5] = KEY_SCROLLUP;
    t[0xF6] = KEY_SCROLLDOWN;
    t[0xF7] = KEY_EDIT;
    t[0xF8] = KEY_SLEEP;
    t[0xF9] = KEY_COFFEE;
    t[0xFA] = KEY_REFRESH;
    t[0xFB] = KEY_CALC;
    t
}

/// The evdev key code for a key on HID usage page 7, or `None` if the kernel has none. Pure and
/// allocation-free. Swift: `MacKeyCode.from(hidUsage:)`.
pub fn evdev_key(usage: u16) -> Option<u16> {
    match HID_KEYBOARD.get(usize::from(usage)) {
        Some(&code) if code != 0 => Some(code),
        _ => None,
    }
}

/// The keys the router drops unless [`InputConfig::allow_system_keys`](crate::InputConfig::allow_system_keys)
/// is set: `KEY_POWER`, `KEY_SLEEP`, `KEY_COFFEE` (`KEY_SCREENLOCK`) and `KEY_EJECTCD` (see the module
/// documentation). Swift never posts them: `MacKeyCode` has no code for their usages.
pub const SYSTEM_KEYS: [u16; 4] = [KEY_POWER, KEY_SLEEP, KEY_COFFEE, KEY_EJECTCD];

/// The modifier flag a modifier key controls (Swift: `PhysicalKey.modifier`), if `(page, usage)` is one.
/// Caps Lock isn't: it is a toggle, and goes to the desktop as an ordinary key.
pub fn modifier_flag(page: u16, usage: u16) -> Option<lain_proto::ModifierFlags> {
    use lain_proto::ModifierFlags as M;
    match (page, usage) {
        (KEYBOARD_PAGE, 0xE0 | 0xE4) => Some(M::CONTROL),
        (KEYBOARD_PAGE, 0xE1 | 0xE5) => Some(M::SHIFT),
        (KEYBOARD_PAGE, 0xE2 | 0xE6) => Some(M::OPTION),
        (KEYBOARD_PAGE, 0xE3 | 0xE7) => Some(M::COMMAND),
        (CONSUMER_PAGE, 0x29D) | (APPLE_VENDOR_TOP_CASE_PAGE, 0x03) => Some(M::FUNCTION),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `hid_keyboard[]` from Linux `drivers/hid/hid-input.c` (master, fetched 2026-10-31), number for number,
    /// with `unk` (`KEY_UNKNOWN`) written as 0 because lain sends neither.
    const KERNEL: [u16; 256] = [
        0, 0, 0, 0, 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, //
        50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44, 2, 3, //
        4, 5, 6, 7, 8, 9, 10, 11, 28, 1, 14, 15, 57, 12, 13, 26, //
        27, 43, 43, 39, 40, 41, 51, 52, 53, 58, 59, 60, 61, 62, 63, 64, //
        65, 66, 67, 68, 87, 88, 99, 70, 119, 110, 102, 104, 111, 107, 109, 106, //
        105, 108, 103, 69, 98, 55, 74, 78, 96, 79, 80, 81, 75, 76, 77, 71, //
        72, 73, 82, 83, 86, 127, 116, 117, 183, 184, 185, 186, 187, 188, 189, 190, //
        191, 192, 193, 194, 134, 138, 130, 132, 128, 129, 131, 137, 133, 135, 136, 113, //
        115, 114, 0, 0, 0, 121, 0, 89, 93, 124, 92, 94, 95, 0, 0, 0, //
        122, 123, 90, 91, 85, 0, 0, 0, 0, 0, 0, 0, 111, 0, 0, 0, //
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0, 0, 179, 180, 0, 0, 0, 0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0, 0, 0, 0, 111, 0, 0, 0, 0, 0, 0, 0, //
        29, 42, 56, 125, 97, 54, 100, 126, 164, 166, 165, 163, 161, 115, 114, 113, //
        150, 158, 159, 128, 136, 177, 178, 176, 142, 152, 173, 140, 0, 0, 0, 0, //
    ];

    #[test]
    fn the_whole_page_matches_the_kernel_table() {
        for usage in 0..=0xFFFFu16 {
            let want = KERNEL.get(usize::from(usage)).copied().filter(|&c| c != 0);
            assert_eq!(evdev_key(usage), want, "usage {usage:#04x}");
        }
    }

    /// Every page-7 usage Swift's `MacKeyCode` knows has a Linux key.
    #[test]
    fn every_usage_mac_key_code_knows_is_mapped() {
        let mac: Vec<u16> = (0x04..=0x67)
            .filter(|&u| u != 0x66)
            .chain(0x68..=0x6F)
            .chain([0x75, 0x7F, 0x80, 0x81, 0x85, 0x87, 0x89, 0x90, 0x91])
            .chain(0xE0..=0xE7)
            .collect();
        for usage in mac {
            assert!(evdev_key(usage).is_some(), "usage {usage:#04x}");
        }
    }

    #[test]
    fn named_spot_checks() {
        let cases = [
            (0x04, KEY_A),
            (0x1D, KEY_Z),
            (0x27, KEY_0),
            (0x28, KEY_ENTER),
            (0x2A, KEY_BACKSPACE),
            (0x35, KEY_GRAVE),
            (0x39, KEY_CAPSLOCK),
            (0x4C, KEY_DELETE),
            (0x64, KEY_102ND),
            (0x65, KEY_COMPOSE),
            (0x67, KEY_KPEQUAL),
            (0x85, KEY_KPCOMMA),
            (0x87, KEY_RO),
            (0x89, KEY_YEN),
            (0x90, KEY_HANGEUL),
            (0x91, KEY_HANJA),
            (0xE3, KEY_LEFTMETA),
            (0xE6, KEY_RIGHTALT),
        ];
        for (usage, code) in cases {
            assert_eq!(evdev_key(usage), Some(code), "usage {usage:#04x}");
        }
        for usage in [0x00, 0x01, 0x03, 0x82, 0x86, 0x8D, 0x95, 0xA5, 0xFC, 0xFF, 0x100, 0xFFFF] {
            assert_eq!(evdev_key(usage), None, "usage {usage:#04x}");
        }
    }

    /// Every evdev constant has the value `linux/input-event-codes.h` gives its name. Skipped (with a note) on
    /// a machine without kernel headers.
    #[test]
    fn evdev_constants_match_the_system_header() {
        let Ok(header) = std::fs::read_to_string("/usr/include/linux/input-event-codes.h") else {
            eprintln!("skipped: /usr/include/linux/input-event-codes.h is not installed");
            return;
        };
        let defined = |name: &str| -> Option<u16> {
            header.lines().find_map(|line| {
                let mut words = line.split_whitespace();
                (words.next() == Some("#define") && words.next() == Some(name)).then(|| words.next()).flatten().map(
                    |v| match v.strip_prefix("0x") {
                        Some(hex) => u16::from_str_radix(hex, 16).unwrap(),
                        None => v.parse().unwrap(),
                    },
                )
            })
        };
        for &(name, value) in crate::evdev::ALL {
            assert_eq!(defined(name), Some(value), "{name}");
        }
    }

    #[test]
    fn modifier_keys() {
        use lain_proto::ModifierFlags as M;
        assert_eq!(modifier_flag(KEYBOARD_PAGE, 0xE0), Some(M::CONTROL));
        assert_eq!(modifier_flag(KEYBOARD_PAGE, 0xE5), Some(M::SHIFT));
        assert_eq!(modifier_flag(KEYBOARD_PAGE, 0xE6), Some(M::OPTION));
        assert_eq!(modifier_flag(KEYBOARD_PAGE, 0xE7), Some(M::COMMAND));
        assert_eq!(modifier_flag(CONSUMER_PAGE, 0x29D), Some(M::FUNCTION));
        assert_eq!(modifier_flag(APPLE_VENDOR_TOP_CASE_PAGE, 0x03), Some(M::FUNCTION));
        assert_eq!(modifier_flag(KEYBOARD_PAGE, 0x39), None, "Caps Lock is a toggle, not a held modifier");
        assert_eq!(modifier_flag(CONSUMER_PAGE, 0xE0), None);
    }
}
