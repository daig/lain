//! The evdev codes lain sends (`linux/input-event-codes.h`), under their header names.
//!
//! The `KEY_*` set is exactly the codes the kernel's HID keyboard table produces ([`crate::keymap`]), each
//! under the first name the header gives its value (so `KEY_HANGEUL`, not the alias `KEY_HANGUEL`). A test
//! checks every value against the installed header.
//!
//! No Swift counterpart: the Mac host posts Carbon virtual keycodes (`MacKeyCode`).

pub const KEY_ESC: u16 = 1;
pub const KEY_1: u16 = 2;
pub const KEY_2: u16 = 3;
pub const KEY_3: u16 = 4;
pub const KEY_4: u16 = 5;
pub const KEY_5: u16 = 6;
pub const KEY_6: u16 = 7;
pub const KEY_7: u16 = 8;
pub const KEY_8: u16 = 9;
pub const KEY_9: u16 = 10;
pub const KEY_0: u16 = 11;
pub const KEY_MINUS: u16 = 12;
pub const KEY_EQUAL: u16 = 13;
pub const KEY_BACKSPACE: u16 = 14;
pub const KEY_TAB: u16 = 15;
pub const KEY_Q: u16 = 16;
pub const KEY_W: u16 = 17;
pub const KEY_E: u16 = 18;
pub const KEY_R: u16 = 19;
pub const KEY_T: u16 = 20;
pub const KEY_Y: u16 = 21;
pub const KEY_U: u16 = 22;
pub const KEY_I: u16 = 23;
pub const KEY_O: u16 = 24;
pub const KEY_P: u16 = 25;
pub const KEY_LEFTBRACE: u16 = 26;
pub const KEY_RIGHTBRACE: u16 = 27;
pub const KEY_ENTER: u16 = 28;
pub const KEY_LEFTCTRL: u16 = 29;
pub const KEY_A: u16 = 30;
pub const KEY_S: u16 = 31;
pub const KEY_D: u16 = 32;
pub const KEY_F: u16 = 33;
pub const KEY_G: u16 = 34;
pub const KEY_H: u16 = 35;
pub const KEY_J: u16 = 36;
pub const KEY_K: u16 = 37;
pub const KEY_L: u16 = 38;
pub const KEY_SEMICOLON: u16 = 39;
pub const KEY_APOSTROPHE: u16 = 40;
pub const KEY_GRAVE: u16 = 41;
pub const KEY_LEFTSHIFT: u16 = 42;
pub const KEY_BACKSLASH: u16 = 43;
pub const KEY_Z: u16 = 44;
pub const KEY_X: u16 = 45;
pub const KEY_C: u16 = 46;
pub const KEY_V: u16 = 47;
pub const KEY_B: u16 = 48;
pub const KEY_N: u16 = 49;
pub const KEY_M: u16 = 50;
pub const KEY_COMMA: u16 = 51;
pub const KEY_DOT: u16 = 52;
pub const KEY_SLASH: u16 = 53;
pub const KEY_RIGHTSHIFT: u16 = 54;
pub const KEY_KPASTERISK: u16 = 55;
pub const KEY_LEFTALT: u16 = 56;
pub const KEY_SPACE: u16 = 57;
pub const KEY_CAPSLOCK: u16 = 58;
pub const KEY_F1: u16 = 59;
pub const KEY_F2: u16 = 60;
pub const KEY_F3: u16 = 61;
pub const KEY_F4: u16 = 62;
pub const KEY_F5: u16 = 63;
pub const KEY_F6: u16 = 64;
pub const KEY_F7: u16 = 65;
pub const KEY_F8: u16 = 66;
pub const KEY_F9: u16 = 67;
pub const KEY_F10: u16 = 68;
pub const KEY_NUMLOCK: u16 = 69;
pub const KEY_SCROLLLOCK: u16 = 70;
pub const KEY_KP7: u16 = 71;
pub const KEY_KP8: u16 = 72;
pub const KEY_KP9: u16 = 73;
pub const KEY_KPMINUS: u16 = 74;
pub const KEY_KP4: u16 = 75;
pub const KEY_KP5: u16 = 76;
pub const KEY_KP6: u16 = 77;
pub const KEY_KPPLUS: u16 = 78;
pub const KEY_KP1: u16 = 79;
pub const KEY_KP2: u16 = 80;
pub const KEY_KP3: u16 = 81;
pub const KEY_KP0: u16 = 82;
pub const KEY_KPDOT: u16 = 83;
pub const KEY_ZENKAKUHANKAKU: u16 = 85;
pub const KEY_102ND: u16 = 86;
pub const KEY_F11: u16 = 87;
pub const KEY_F12: u16 = 88;
pub const KEY_RO: u16 = 89;
pub const KEY_KATAKANA: u16 = 90;
pub const KEY_HIRAGANA: u16 = 91;
pub const KEY_HENKAN: u16 = 92;
pub const KEY_KATAKANAHIRAGANA: u16 = 93;
pub const KEY_MUHENKAN: u16 = 94;
pub const KEY_KPJPCOMMA: u16 = 95;
pub const KEY_KPENTER: u16 = 96;
pub const KEY_RIGHTCTRL: u16 = 97;
pub const KEY_KPSLASH: u16 = 98;
pub const KEY_SYSRQ: u16 = 99;
pub const KEY_RIGHTALT: u16 = 100;
pub const KEY_HOME: u16 = 102;
pub const KEY_UP: u16 = 103;
pub const KEY_PAGEUP: u16 = 104;
pub const KEY_LEFT: u16 = 105;
pub const KEY_RIGHT: u16 = 106;
pub const KEY_END: u16 = 107;
pub const KEY_DOWN: u16 = 108;
pub const KEY_PAGEDOWN: u16 = 109;
pub const KEY_INSERT: u16 = 110;
pub const KEY_DELETE: u16 = 111;
pub const KEY_MUTE: u16 = 113;
pub const KEY_VOLUMEDOWN: u16 = 114;
pub const KEY_VOLUMEUP: u16 = 115;
pub const KEY_POWER: u16 = 116;
pub const KEY_KPEQUAL: u16 = 117;
pub const KEY_PAUSE: u16 = 119;
pub const KEY_KPCOMMA: u16 = 121;
pub const KEY_HANGEUL: u16 = 122;
pub const KEY_HANJA: u16 = 123;
pub const KEY_YEN: u16 = 124;
pub const KEY_LEFTMETA: u16 = 125;
pub const KEY_RIGHTMETA: u16 = 126;
pub const KEY_COMPOSE: u16 = 127;
pub const KEY_STOP: u16 = 128;
pub const KEY_AGAIN: u16 = 129;
pub const KEY_PROPS: u16 = 130;
pub const KEY_UNDO: u16 = 131;
pub const KEY_FRONT: u16 = 132;
pub const KEY_COPY: u16 = 133;
pub const KEY_OPEN: u16 = 134;
pub const KEY_PASTE: u16 = 135;
pub const KEY_FIND: u16 = 136;
pub const KEY_CUT: u16 = 137;
pub const KEY_HELP: u16 = 138;
pub const KEY_CALC: u16 = 140;
pub const KEY_SLEEP: u16 = 142;
pub const KEY_WWW: u16 = 150;
pub const KEY_COFFEE: u16 = 152;
pub const KEY_BACK: u16 = 158;
pub const KEY_FORWARD: u16 = 159;
pub const KEY_EJECTCD: u16 = 161;
pub const KEY_NEXTSONG: u16 = 163;
pub const KEY_PLAYPAUSE: u16 = 164;
pub const KEY_PREVIOUSSONG: u16 = 165;
pub const KEY_STOPCD: u16 = 166;
pub const KEY_REFRESH: u16 = 173;
pub const KEY_EDIT: u16 = 176;
pub const KEY_SCROLLUP: u16 = 177;
pub const KEY_SCROLLDOWN: u16 = 178;
pub const KEY_KPLEFTPAREN: u16 = 179;
pub const KEY_KPRIGHTPAREN: u16 = 180;
pub const KEY_F13: u16 = 183;
pub const KEY_F14: u16 = 184;
pub const KEY_F15: u16 = 185;
pub const KEY_F16: u16 = 186;
pub const KEY_F17: u16 = 187;
pub const KEY_F18: u16 = 188;
pub const KEY_F19: u16 = 189;
pub const KEY_F20: u16 = 190;
pub const KEY_F21: u16 = 191;
pub const KEY_F22: u16 = 192;
pub const KEY_F23: u16 = 193;
pub const KEY_F24: u16 = 194;

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;

/// Every constant in this module with its name, for the test against the system header.
#[cfg(test)]
pub(crate) const ALL: &[(&str, u16)] = &[
    ("KEY_ESC", KEY_ESC),
    ("KEY_1", KEY_1),
    ("KEY_2", KEY_2),
    ("KEY_3", KEY_3),
    ("KEY_4", KEY_4),
    ("KEY_5", KEY_5),
    ("KEY_6", KEY_6),
    ("KEY_7", KEY_7),
    ("KEY_8", KEY_8),
    ("KEY_9", KEY_9),
    ("KEY_0", KEY_0),
    ("KEY_MINUS", KEY_MINUS),
    ("KEY_EQUAL", KEY_EQUAL),
    ("KEY_BACKSPACE", KEY_BACKSPACE),
    ("KEY_TAB", KEY_TAB),
    ("KEY_Q", KEY_Q),
    ("KEY_W", KEY_W),
    ("KEY_E", KEY_E),
    ("KEY_R", KEY_R),
    ("KEY_T", KEY_T),
    ("KEY_Y", KEY_Y),
    ("KEY_U", KEY_U),
    ("KEY_I", KEY_I),
    ("KEY_O", KEY_O),
    ("KEY_P", KEY_P),
    ("KEY_LEFTBRACE", KEY_LEFTBRACE),
    ("KEY_RIGHTBRACE", KEY_RIGHTBRACE),
    ("KEY_ENTER", KEY_ENTER),
    ("KEY_LEFTCTRL", KEY_LEFTCTRL),
    ("KEY_A", KEY_A),
    ("KEY_S", KEY_S),
    ("KEY_D", KEY_D),
    ("KEY_F", KEY_F),
    ("KEY_G", KEY_G),
    ("KEY_H", KEY_H),
    ("KEY_J", KEY_J),
    ("KEY_K", KEY_K),
    ("KEY_L", KEY_L),
    ("KEY_SEMICOLON", KEY_SEMICOLON),
    ("KEY_APOSTROPHE", KEY_APOSTROPHE),
    ("KEY_GRAVE", KEY_GRAVE),
    ("KEY_LEFTSHIFT", KEY_LEFTSHIFT),
    ("KEY_BACKSLASH", KEY_BACKSLASH),
    ("KEY_Z", KEY_Z),
    ("KEY_X", KEY_X),
    ("KEY_C", KEY_C),
    ("KEY_V", KEY_V),
    ("KEY_B", KEY_B),
    ("KEY_N", KEY_N),
    ("KEY_M", KEY_M),
    ("KEY_COMMA", KEY_COMMA),
    ("KEY_DOT", KEY_DOT),
    ("KEY_SLASH", KEY_SLASH),
    ("KEY_RIGHTSHIFT", KEY_RIGHTSHIFT),
    ("KEY_KPASTERISK", KEY_KPASTERISK),
    ("KEY_LEFTALT", KEY_LEFTALT),
    ("KEY_SPACE", KEY_SPACE),
    ("KEY_CAPSLOCK", KEY_CAPSLOCK),
    ("KEY_F1", KEY_F1),
    ("KEY_F2", KEY_F2),
    ("KEY_F3", KEY_F3),
    ("KEY_F4", KEY_F4),
    ("KEY_F5", KEY_F5),
    ("KEY_F6", KEY_F6),
    ("KEY_F7", KEY_F7),
    ("KEY_F8", KEY_F8),
    ("KEY_F9", KEY_F9),
    ("KEY_F10", KEY_F10),
    ("KEY_NUMLOCK", KEY_NUMLOCK),
    ("KEY_SCROLLLOCK", KEY_SCROLLLOCK),
    ("KEY_KP7", KEY_KP7),
    ("KEY_KP8", KEY_KP8),
    ("KEY_KP9", KEY_KP9),
    ("KEY_KPMINUS", KEY_KPMINUS),
    ("KEY_KP4", KEY_KP4),
    ("KEY_KP5", KEY_KP5),
    ("KEY_KP6", KEY_KP6),
    ("KEY_KPPLUS", KEY_KPPLUS),
    ("KEY_KP1", KEY_KP1),
    ("KEY_KP2", KEY_KP2),
    ("KEY_KP3", KEY_KP3),
    ("KEY_KP0", KEY_KP0),
    ("KEY_KPDOT", KEY_KPDOT),
    ("KEY_ZENKAKUHANKAKU", KEY_ZENKAKUHANKAKU),
    ("KEY_102ND", KEY_102ND),
    ("KEY_F11", KEY_F11),
    ("KEY_F12", KEY_F12),
    ("KEY_RO", KEY_RO),
    ("KEY_KATAKANA", KEY_KATAKANA),
    ("KEY_HIRAGANA", KEY_HIRAGANA),
    ("KEY_HENKAN", KEY_HENKAN),
    ("KEY_KATAKANAHIRAGANA", KEY_KATAKANAHIRAGANA),
    ("KEY_MUHENKAN", KEY_MUHENKAN),
    ("KEY_KPJPCOMMA", KEY_KPJPCOMMA),
    ("KEY_KPENTER", KEY_KPENTER),
    ("KEY_RIGHTCTRL", KEY_RIGHTCTRL),
    ("KEY_KPSLASH", KEY_KPSLASH),
    ("KEY_SYSRQ", KEY_SYSRQ),
    ("KEY_RIGHTALT", KEY_RIGHTALT),
    ("KEY_HOME", KEY_HOME),
    ("KEY_UP", KEY_UP),
    ("KEY_PAGEUP", KEY_PAGEUP),
    ("KEY_LEFT", KEY_LEFT),
    ("KEY_RIGHT", KEY_RIGHT),
    ("KEY_END", KEY_END),
    ("KEY_DOWN", KEY_DOWN),
    ("KEY_PAGEDOWN", KEY_PAGEDOWN),
    ("KEY_INSERT", KEY_INSERT),
    ("KEY_DELETE", KEY_DELETE),
    ("KEY_MUTE", KEY_MUTE),
    ("KEY_VOLUMEDOWN", KEY_VOLUMEDOWN),
    ("KEY_VOLUMEUP", KEY_VOLUMEUP),
    ("KEY_POWER", KEY_POWER),
    ("KEY_KPEQUAL", KEY_KPEQUAL),
    ("KEY_PAUSE", KEY_PAUSE),
    ("KEY_KPCOMMA", KEY_KPCOMMA),
    ("KEY_HANGEUL", KEY_HANGEUL),
    ("KEY_HANJA", KEY_HANJA),
    ("KEY_YEN", KEY_YEN),
    ("KEY_LEFTMETA", KEY_LEFTMETA),
    ("KEY_RIGHTMETA", KEY_RIGHTMETA),
    ("KEY_COMPOSE", KEY_COMPOSE),
    ("KEY_STOP", KEY_STOP),
    ("KEY_AGAIN", KEY_AGAIN),
    ("KEY_PROPS", KEY_PROPS),
    ("KEY_UNDO", KEY_UNDO),
    ("KEY_FRONT", KEY_FRONT),
    ("KEY_COPY", KEY_COPY),
    ("KEY_OPEN", KEY_OPEN),
    ("KEY_PASTE", KEY_PASTE),
    ("KEY_FIND", KEY_FIND),
    ("KEY_CUT", KEY_CUT),
    ("KEY_HELP", KEY_HELP),
    ("KEY_CALC", KEY_CALC),
    ("KEY_SLEEP", KEY_SLEEP),
    ("KEY_WWW", KEY_WWW),
    ("KEY_COFFEE", KEY_COFFEE),
    ("KEY_BACK", KEY_BACK),
    ("KEY_FORWARD", KEY_FORWARD),
    ("KEY_EJECTCD", KEY_EJECTCD),
    ("KEY_NEXTSONG", KEY_NEXTSONG),
    ("KEY_PLAYPAUSE", KEY_PLAYPAUSE),
    ("KEY_PREVIOUSSONG", KEY_PREVIOUSSONG),
    ("KEY_STOPCD", KEY_STOPCD),
    ("KEY_REFRESH", KEY_REFRESH),
    ("KEY_EDIT", KEY_EDIT),
    ("KEY_SCROLLUP", KEY_SCROLLUP),
    ("KEY_SCROLLDOWN", KEY_SCROLLDOWN),
    ("KEY_KPLEFTPAREN", KEY_KPLEFTPAREN),
    ("KEY_KPRIGHTPAREN", KEY_KPRIGHTPAREN),
    ("KEY_F13", KEY_F13),
    ("KEY_F14", KEY_F14),
    ("KEY_F15", KEY_F15),
    ("KEY_F16", KEY_F16),
    ("KEY_F17", KEY_F17),
    ("KEY_F18", KEY_F18),
    ("KEY_F19", KEY_F19),
    ("KEY_F20", KEY_F20),
    ("KEY_F21", KEY_F21),
    ("KEY_F22", KEY_F22),
    ("KEY_F23", KEY_F23),
    ("KEY_F24", KEY_F24),
    ("BTN_LEFT", BTN_LEFT),
    ("BTN_RIGHT", BTN_RIGHT),
    ("BTN_MIDDLE", BTN_MIDDLE),
];
