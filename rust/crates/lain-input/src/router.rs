//! The client's input messages → desktop input actions. Swift: `HostInputRouter` (policy) together with
//! `InputInjector` (what it tracks as held), since here the backend only performs [`InputAction`]s.

use crate::evdev::{BTN_LEFT, BTN_MIDDLE, BTN_RIGHT, KEY_EQUAL, KEY_MINUS};
use crate::keymap::{self, KEYBOARD_PAGE};
use crate::modifiers::{LinuxModifier, ModifierMap, ModifierSet};
use crate::pinch::PinchZoomMapper;
use crate::scroll::{ScrollConfig, ScrollPolicy};
use lain_platform::{InputAction, PointF, ScrollSource};
use lain_proto::{
    Gesture, GestureKind, GesturePhase, KeyEvent, KeyboardType, Message, ModifierFlags, MouseButton, PointerButton,
    PointerMove,
};

/// One wheel detent in Mutter's axis units (spike B: 10 per detent).
pub const WHEEL_DETENT: f64 = 10.0;

/// What a pinch step does on the desktop. Swift sends Cmd = and Cmd − (`HostInputRouter.zoomInUsage`,
/// `zoomOutUsage`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ZoomAction {
    /// Ctrl held over one wheel detent per step, up to zoom in. The default: it is independent of the
    /// desktop's keyboard layout (Ctrl = is Ctrl ´ on a German layout, where `KEY_EQUAL` types a dead key);
    /// browsers, GNOME's document and image viewers and most editors zoom on it; and they zoom around the
    /// pointer, as a pinch does.
    #[default]
    CtrlWheel,
    /// Ctrl = to zoom in and Ctrl − to zoom out (`KEY_EQUAL`, `KEY_MINUS`): Swift's shortcut, with Ctrl for
    /// Command.
    CtrlKeys,
}

/// How the router maps the client's input.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InputConfig {
    pub modifiers: ModifierMap,
    pub scroll: ScrollConfig,
    pub zoom: ZoomAction,
    /// The pinch factor per zoom step (Swift: `PinchZoomMapper.threshold`); above 1.
    pub pinch_threshold: f64,
    /// Swap `KEY_GRAVE` and `KEY_102ND` when the client's keyboard is ISO (`Hello.keyboardType`), as Linux's
    /// `hid-apple` driver does for Apple ISO keyboards (`iso_layout`). Off by default: whether the iPad reports
    /// an Apple ISO keyboard's usages already corrected is unconfirmed (Swift leaves it to macOS, by setting
    /// the event source's keyboard type).
    pub swap_iso_keys: bool,
}

impl Default for InputConfig {
    fn default() -> Self {
        Self {
            modifiers: ModifierMap::default(),
            scroll: ScrollConfig::default(),
            zoom: ZoomAction::default(),
            pinch_threshold: PinchZoomMapper::DEFAULT_THRESHOLD,
            swap_iso_keys: false,
        }
    }
}

/// What a message did, so the session can track the commanded pointer and user activity. Swift:
/// `HostInputRouter.Outcome`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Outcome {
    /// Not an input message (control, cursor, video…); the caller handles it.
    NotInput,
    /// An input message with no effect on the desktop: a key repeat, an unknown key, a modifier mapped to
    /// nothing, a duplicate press or orphan release, the client's momentum when it is dropped, a rotate, a
    /// pinch below the next step. (Swift reports most of these as `injected`, because its sink decides later.)
    Ignored,
    /// Input was injected. `pointer` is the commanded position (global points) for pointer events.
    Injected { pointer: Option<PointF> },
    /// `ReleaseAll`: everything held was released.
    Released,
}

/// The regular (non-modifier) keys held on the desktop, in press order. Fixed capacity: the table has fewer
/// distinct codes than this, and a code is held at most once, so it can't fill.
#[derive(Debug, Clone)]
struct HeldKeys {
    codes: [u16; 256],
    len: usize,
}

impl HeldKeys {
    const fn new() -> Self {
        Self { codes: [0; 256], len: 0 }
    }

    fn as_slice(&self) -> &[u16] {
        &self.codes[..self.len]
    }

    fn contains(&self, code: u16) -> bool {
        self.as_slice().contains(&code)
    }

    /// Adds `code` unless it is held (or, impossibly, the set is full). Returns whether it was added.
    fn insert(&mut self, code: u16) -> bool {
        if self.contains(code) || self.len == self.codes.len() {
            return false;
        }
        self.codes[self.len] = code;
        self.len += 1;
        true
    }

    /// Removes `code`, keeping the order. Returns whether it was held.
    fn remove(&mut self, code: u16) -> bool {
        let Some(i) = self.as_slice().iter().position(|&c| c == code) else { return false };
        self.codes.copy_within(i + 1..self.len, i);
        self.len -= 1;
        true
    }
}

/// Turns the client's decoded input messages into [`InputAction`]s (§5.5). Swift: `HostInputRouter`, with the
/// held-state tracking of `InputInjector`.
///
/// Pure and synchronous, for the realtime connection's reader (invariant 3: never queued, never awaits).
/// [`handle`](Self::handle) appends to the caller's buffer and allocates nothing once that buffer has capacity
/// (a few dozen actions; a pinch crossing many zoom factors at once needs more).
///
/// Intended differences from Swift, all because Linux input events carry no modifier flags or positions:
/// - Modifier keys are never sent as themselves. The desktop's modifier keys follow each key or button
///   event's `ModifierFlags` through the [`ModifierMap`], pressed and released explicitly (left-hand keys, as
///   the client synthesizes them); a change of map does the same.
/// - Key repeats are dropped: the desktop repeats held keys itself. (Swift posts repeats of held keys.)
/// - A button press or release first moves the pointer to the event's position if the last commanded
///   position differs (a `CGEvent` click carries its position). Click counts are left to the desktop, which
///   counts with the same double-click interval the client was given.
/// - Scrolls follow [`ScrollConfig`] (see [`crate::scroll`]); pinches follow [`ZoomAction`], with Ctrl held
///   once around all the steps of one gesture event (Swift presses Command for each step).
#[derive(Debug, Clone)]
pub struct InputRouter {
    config: InputConfig,
    pinch: PinchZoomMapper,
    scroll: ScrollPolicy,
    keyboard_type: KeyboardType,
    /// The client's modifier state as of its last key or button event (Swift: `HostInputRouter.modifiers`).
    modifiers: ModifierFlags,
    held_modifiers: ModifierSet,
    held_keys: HeldKeys,
    /// Bit n: the [`MouseButton`] with raw value n is held.
    held_buttons: u8,
    last_pointer: Option<PointF>,
    logged_rotate: bool,
    /// Page-7 usages already logged as unknown.
    logged_usages: [u64; 4],
    logged_other_page: bool,
}

impl Default for InputRouter {
    fn default() -> Self {
        Self::new(InputConfig::default())
    }
}

impl InputRouter {
    /// # Panics
    /// If `config.pinch_threshold` isn't above 1.
    pub fn new(config: InputConfig) -> Self {
        Self {
            config,
            pinch: PinchZoomMapper::new(config.pinch_threshold),
            scroll: ScrollPolicy::new(config.scroll),
            keyboard_type: KeyboardType::Unknown,
            modifiers: ModifierFlags::EMPTY,
            held_modifiers: ModifierSet::EMPTY,
            held_keys: HeldKeys::new(),
            held_buttons: 0,
            last_pointer: None,
            logged_rotate: false,
            logged_usages: [0; 4],
            logged_other_page: false,
        }
    }

    pub fn config(&self) -> &InputConfig {
        &self.config
    }

    /// The client's modifier state as of its last key or button event.
    pub fn modifiers(&self) -> ModifierFlags {
        self.modifiers
    }

    /// The desktop modifiers held for the client.
    pub fn held_modifiers(&self) -> ModifierSet {
        self.held_modifiers
    }

    /// The regular keys held on the desktop, in press order (evdev codes).
    pub fn held_keys(&self) -> &[u16] {
        self.held_keys.as_slice()
    }

    /// The buttons held (bit n: [`MouseButton`] raw value n).
    pub fn held_buttons(&self) -> u8 {
        self.held_buttons
    }

    /// Whether a scroll sequence is open on the desktop (Swift: `scrollPhaseOpen || momentumOpen`).
    pub fn scroll_open(&self) -> bool {
        self.scroll.is_open()
    }

    /// Whether anything is held or open, which [`release_all`](Self::release_all) would end.
    pub fn is_holding(&self) -> bool {
        !self.held_keys.as_slice().is_empty()
            || !self.held_modifiers.is_empty()
            || self.held_buttons != 0
            || self.scroll.is_open()
    }

    pub fn pinch(&self) -> &PinchZoomMapper {
        &self.pinch
    }

    /// The client's physical keyboard, from `Hello` (Swift: `InputSink.setKeyboardType`). Set it at session
    /// start, before any key: a key held across a change would be released under the other code. It matters
    /// only with [`InputConfig::swap_iso_keys`].
    pub fn set_keyboard_type(&mut self, keyboard_type: KeyboardType) {
        self.keyboard_type = keyboard_type;
    }

    /// Changes the modifier map at run time, appending the presses and releases that make the held modifier
    /// keys match the client's current modifiers under the new map.
    pub fn set_modifier_map(&mut self, map: ModifierMap, out: &mut Vec<InputAction>) {
        self.config.modifiers = map;
        self.sync_modifiers(self.modifiers, out);
    }

    /// Handles one message, appending what the desktop must do to `out` (which the caller clears and passes to
    /// `InputBackend::apply`). Swift: `HostInputRouter.handle`.
    pub fn handle(&mut self, message: &Message, out: &mut Vec<InputAction>) -> Outcome {
        match message {
            Message::KeyEvent(e) => {
                self.scroll.before_other_input(out);
                let start = out.len();
                self.key(e, out);
                Self::outcome(out, start, None)
            }
            Message::PointerMove(m) => {
                self.scroll.before_other_input(out);
                self.pointer_move(m, out)
            }
            Message::PointerButton(b) => {
                self.scroll.before_other_input(out);
                let start = out.len();
                let pointer = self.button(b, out);
                Self::outcome(out, start, pointer)
            }
            Message::Scroll(s) => {
                if self.scroll.scroll(s, out) {
                    Outcome::Injected { pointer: None }
                } else {
                    Outcome::Ignored
                }
            }
            Message::Gesture(g) => {
                self.scroll.before_other_input(out);
                let start = out.len();
                self.gesture(g, out);
                Self::outcome(out, start, None)
            }
            Message::ReleaseAll(_) => {
                self.release_all(out);
                Outcome::Released
            }
            _ => Outcome::NotInput,
        }
    }

    /// Invariant 4, host side: ends an open scroll sequence (the client can't once the link is gone), then
    /// releases every held key (regular keys first, newest first, then modifiers) and button, and forgets the
    /// pinch and the client's modifiers. For `ReleaseAll` and for a link that ends. Swift:
    /// `HostInputRouter.releaseAll` and `InputInjector.releaseAll`.
    pub fn release_all(&mut self, out: &mut Vec<InputAction>) {
        self.scroll.end(out);
        for &code in self.held_keys.as_slice().iter().rev() {
            out.push(InputAction::Key { code, down: false });
        }
        self.held_keys = HeldKeys::new();
        for m in self.held_modifiers.iter().rev() {
            out.push(InputAction::Key { code: m.key(), down: false });
        }
        self.held_modifiers = ModifierSet::EMPTY;
        for button in MouseButton::ALL {
            if self.held_buttons & Self::button_bit(*button) != 0 {
                out.push(InputAction::Button { code: Self::button_code(*button), down: false });
            }
        }
        self.held_buttons = 0;
        self.pinch.reset();
        self.modifiers = ModifierFlags::EMPTY;
    }

    fn outcome(out: &[InputAction], start: usize, pointer: Option<PointF>) -> Outcome {
        if out.len() > start { Outcome::Injected { pointer } } else { Outcome::Ignored }
    }

    // MARK: Keys

    fn key(&mut self, e: &KeyEvent, out: &mut Vec<InputAction>) {
        if e.is_repeat {
            return;
        }
        self.sync_modifiers(e.modifiers, out);
        if keymap::modifier_flag(e.usage_page, e.usage).is_some() {
            return; // a modifier key's effect is the modifier state it carries
        }
        let Some(code) = self.code(e.usage_page, e.usage) else { return };
        let changed = if e.is_down { self.held_keys.insert(code) } else { self.held_keys.remove(code) };
        if changed {
            out.push(InputAction::Key { code, down: e.is_down });
        }
    }

    /// The evdev code for a client key, or `None` (logged once per usage) if Linux has none.
    fn code(&mut self, page: u16, usage: u16) -> Option<u16> {
        if page != KEYBOARD_PAGE {
            if !self.logged_other_page {
                self.logged_other_page = true;
                tracing::info!(page, usage, "ignoring keys outside the HID keyboard page (logged once)");
            }
            return None;
        }
        let usage = match (self.config.swap_iso_keys && self.keyboard_type == KeyboardType::Iso, usage) {
            (true, 0x35) => 0x64,
            (true, 0x64) => 0x35,
            (_, usage) => usage,
        };
        let code = keymap::evdev_key(usage);
        if code.is_none() && usage < 256 {
            let (word, bit) = (usize::from(usage / 64), 1u64 << (usage % 64));
            if self.logged_usages[word] & bit == 0 {
                self.logged_usages[word] |= bit;
                tracing::info!(usage, "ignoring a key with no Linux key code (logged once per usage)");
            }
        }
        code
    }

    /// Presses and releases desktop modifier keys until those held are what `flags` hold under the map:
    /// releases first (newest first), then presses.
    fn sync_modifiers(&mut self, flags: ModifierFlags, out: &mut Vec<InputAction>) {
        self.modifiers = flags;
        let want = self.config.modifiers.apply(flags);
        for m in self.held_modifiers.iter().rev() {
            if !want.contains(m) {
                out.push(InputAction::Key { code: m.key(), down: false });
            }
        }
        for m in want.iter() {
            if !self.held_modifiers.contains(m) {
                out.push(InputAction::Key { code: m.key(), down: true });
            }
        }
        self.held_modifiers = want;
    }

    // MARK: Pointer

    fn pointer_move(&mut self, m: &PointerMove, out: &mut Vec<InputAction>) -> Outcome {
        let Some(p) = finite_point(m.x, m.y) else { return Outcome::Ignored };
        out.push(InputAction::MoveTo(p));
        self.last_pointer = Some(p);
        Outcome::Injected { pointer: Some(p) }
    }

    /// Returns the commanded position.
    fn button(&mut self, b: &PointerButton, out: &mut Vec<InputAction>) -> Option<PointF> {
        self.sync_modifiers(b.modifiers, out);
        let p = finite_point(b.x, b.y);
        if let Some(p) = p
            && self.last_pointer != Some(p)
        {
            out.push(InputAction::MoveTo(p));
            self.last_pointer = Some(p);
        }
        let bit = Self::button_bit(b.button);
        let held = self.held_buttons & bit != 0;
        if b.is_down != held {
            self.held_buttons ^= bit;
            out.push(InputAction::Button { code: Self::button_code(b.button), down: b.is_down });
        }
        p
    }

    fn button_bit(button: MouseButton) -> u8 {
        1 << button.raw()
    }

    /// Swift: `InputInjector.buttonType` (other → the centre button).
    pub const fn button_code(button: MouseButton) -> u16 {
        match button {
            MouseButton::Left => BTN_LEFT,
            MouseButton::Right => BTN_RIGHT,
            MouseButton::Other => BTN_MIDDLE,
        }
    }

    // MARK: Gestures

    fn gesture(&mut self, g: &Gesture, out: &mut Vec<InputAction>) {
        match g.kind {
            GestureKind::Rotate => {
                if !self.logged_rotate {
                    self.logged_rotate = true;
                    tracing::info!("rotate gestures are ignored (logged once)");
                }
            }
            GestureKind::Magnify => {
                let steps = self.pinch.add(f64::from(g.value));
                if matches!(g.phase, GesturePhase::Ended | GesturePhase::Cancelled) {
                    self.pinch.reset();
                }
                if steps != 0 {
                    self.zoom(steps, out);
                }
            }
        }
    }

    /// `steps` zoom steps (positive: in), with Ctrl pressed around them unless the client already holds it,
    /// so the desktop ends at the client's own modifiers. Swift: `HostInputRouter.pressWithCommand`.
    fn zoom(&mut self, steps: i32, out: &mut Vec<InputAction>) {
        let ctrl = LinuxModifier::Control.key();
        let press_ctrl = !self.held_modifiers.contains(LinuxModifier::Control);
        if press_ctrl {
            out.push(InputAction::Key { code: ctrl, down: true });
        }
        for _ in 0..steps.unsigned_abs() {
            match self.config.zoom {
                ZoomAction::CtrlWheel => {
                    let dy = if steps > 0 { -WHEEL_DETENT } else { WHEEL_DETENT };
                    out.push(InputAction::Scroll { dx: 0.0, dy, source: ScrollSource::Wheel });
                }
                ZoomAction::CtrlKeys => {
                    let code = if steps > 0 { KEY_EQUAL } else { KEY_MINUS };
                    out.push(InputAction::Key { code, down: true });
                    out.push(InputAction::Key { code, down: false });
                }
            }
        }
        if press_ctrl {
            out.push(InputAction::Key { code: ctrl, down: false });
        }
    }
}

fn finite_point(x: f64, y: f64) -> Option<PointF> {
    (x.is_finite() && y.is_finite()).then_some(PointF::new(x, y))
}
