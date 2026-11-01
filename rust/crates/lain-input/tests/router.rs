//! `InputRouter` against the brief's acceptance list, and the ports of Swift's `HostInputRouterTests`
//! (`Tests/LainHostCoreTests/HostInputTests.swift`) and `InjectorMapping` (`InputInjectorTests.swift`).

use lain_input::evdev::*;
use lain_input::{
    CommandShortcut, InputConfig, InputRouter, LinuxModifier, ModifierMap, Momentum, Outcome, ScrollConfig, ZoomAction,
};
use lain_platform::fake::FakeInput;
use lain_platform::{InputAction, InputBackend, PointF, ScrollSource};
use lain_proto::{
    Gesture, GestureKind, GesturePhase, HostSetup, KeyEvent, KeyboardType, KeyframeReason, KeyframeRequest, Message,
    ModifierFlags as M, MomentumPhase, MouseButton, Ping, PointerButton, PointerMove, ReleaseAll, ReleaseReason,
    Scroll,
};
use std::collections::BTreeSet;

// MARK: Helpers

fn key(usage: u16, down: bool, modifiers: M) -> Message {
    page_key(0x07, usage, down, modifiers)
}

fn page_key(usage_page: u16, usage: u16, down: bool, modifiers: M) -> Message {
    Message::KeyEvent(KeyEvent { usage_page, usage, is_down: down, is_repeat: false, modifiers })
}

fn repeat(usage: u16, modifiers: M) -> Message {
    Message::KeyEvent(KeyEvent { usage_page: 0x07, usage, is_down: true, is_repeat: true, modifiers })
}

fn mv(x: f64, y: f64) -> Message {
    Message::PointerMove(PointerMove { x, y, dx: 1.0, dy: 1.0, buttons: 0 })
}

fn button(button: MouseButton, down: bool, x: f64, y: f64, modifiers: M) -> Message {
    Message::PointerButton(PointerButton { button, is_down: down, click_count: 1, x, y, modifiers })
}

fn scroll(dx: f32, dy: f32, phase: GesturePhase, momentum_phase: MomentumPhase) -> Message {
    Message::Scroll(Scroll { dx, dy, phase, momentum_phase })
}

fn phase(dy: f32, phase: GesturePhase) -> Message {
    scroll(0.0, dy, phase, MomentumPhase::None)
}

fn momentum(dy: f32, phase: MomentumPhase) -> Message {
    scroll(0.0, dy, GesturePhase::None, phase)
}

fn magnify(phase: GesturePhase, value: f32) -> Message {
    Message::Gesture(Gesture { kind: GestureKind::Magnify, phase, value })
}

fn release(reason: ReleaseReason) -> Message {
    Message::ReleaseAll(ReleaseAll { reason })
}

fn down(code: u16) -> InputAction {
    InputAction::Key { code, down: true }
}

fn up(code: u16) -> InputAction {
    InputAction::Key { code, down: false }
}

fn finger(dy: f64) -> InputAction {
    InputAction::Scroll { dx: 0.0, dy, source: ScrollSource::Finger }
}

const STOP: InputAction = InputAction::ScrollStop { source: ScrollSource::Finger };

/// A router and the actions of the last calls, on a test clock that moves only when a test moves it.
struct Rig {
    router: InputRouter,
    out: Vec<InputAction>,
    now: u64,
}

const MS: u64 = 1_000_000;
/// The default held-back stop delay of `Momentum::Client`.
const STOP_DELAY: u64 = ScrollConfig::DEFAULT_CLIENT_STOP_DELAY_NS;

impl Rig {
    fn new() -> Self {
        Self::with(InputConfig::default())
    }

    fn with(config: InputConfig) -> Self {
        Self { router: InputRouter::new(config), out: Vec::new(), now: 1_000 * MS }
    }

    fn client_momentum() -> Self {
        Self::with(InputConfig {
            scroll: ScrollConfig { momentum: Momentum::Client, ..ScrollConfig::default() },
            ..InputConfig::default()
        })
    }

    /// Handles one message; its actions are appended to `out`.
    fn send(&mut self, message: Message) -> Outcome {
        self.router.handle_at(&message, self.now, &mut self.out)
    }

    /// Moves the clock on by `ns` and polls, appending to `out`; returns whether the poll did anything.
    fn advance(&mut self, ns: u64) -> bool {
        self.now += ns;
        self.router.poll(self.now, &mut self.out)
    }

    /// Handles one message and returns only its actions.
    fn actions(&mut self, message: Message) -> Vec<InputAction> {
        self.out.clear();
        self.send(message);
        std::mem::take(&mut self.out)
    }

    fn take(&mut self) -> Vec<InputAction> {
        std::mem::take(&mut self.out)
    }

    fn release_all(&mut self) -> Vec<InputAction> {
        self.out.clear();
        self.router.release_all(&mut self.out);
        self.take()
    }
}

/// What the desktop holds, built from actions, failing on a press of something held or a release of
/// something not held.
#[derive(Default, Debug)]
struct Desktop {
    keys: BTreeSet<u16>,
    buttons: BTreeSet<u16>,
    scroll_open: bool,
}

impl Desktop {
    fn apply(&mut self, actions: &[InputAction]) {
        for a in actions {
            match *a {
                InputAction::Key { code, down } => {
                    assert!(if down { self.keys.insert(code) } else { self.keys.remove(&code) }, "{a:?} in {actions:?}")
                }
                InputAction::Button { code, down } => {
                    let ok = if down { self.buttons.insert(code) } else { self.buttons.remove(&code) };
                    assert!(ok, "{a:?} in {actions:?}");
                }
                InputAction::Scroll { source: ScrollSource::Finger, .. } => self.scroll_open = true,
                InputAction::ScrollStop { .. } => {
                    assert!(self.scroll_open, "a stop with no sequence open: {actions:?}");
                    self.scroll_open = false;
                }
                InputAction::Scroll { .. } | InputAction::MoveTo(_) => {}
            }
        }
    }

    fn is_idle(&self) -> bool {
        self.keys.is_empty() && self.buttons.is_empty() && !self.scroll_open
    }
}

// MARK: Swift's HostInputRouterTests

#[test]
fn forwards_every_input_message() {
    let mut r = Rig::new();
    assert_eq!(r.send(key(0x04, true, M::SHIFT)), Outcome::Injected { pointer: None });
    assert_eq!(r.router.modifiers(), M::SHIFT);
    assert_eq!(r.send(mv(10.5, 20.25)), Outcome::Injected { pointer: Some(PointF::new(10.5, 20.25)) });
    assert_eq!(
        r.send(button(MouseButton::Left, true, 11.0, 21.0, M::COMMAND)),
        Outcome::Injected { pointer: Some(PointF::new(11.0, 21.0)) }
    );
    assert_eq!(r.router.modifiers(), M::COMMAND);
    assert_eq!(r.send(phase(-12.5, GesturePhase::Changed)), Outcome::Injected { pointer: None });
    assert_eq!(r.send(release(ReleaseReason::FocusLost)), Outcome::Released);
    assert_eq!(r.router.modifiers(), M::EMPTY);
    // The scroll the client left open is ended before the release.
    assert_eq!(
        r.take(),
        [
            down(KEY_LEFTSHIFT),
            down(KEY_A),
            InputAction::MoveTo(PointF::new(10.5, 20.25)),
            up(KEY_LEFTSHIFT),
            down(KEY_LEFTCTRL),
            InputAction::MoveTo(PointF::new(11.0, 21.0)),
            InputAction::Button { code: BTN_LEFT, down: true },
            finger(12.5),
            STOP,
            up(KEY_A),
            up(KEY_LEFTCTRL),
            InputAction::Button { code: BTN_LEFT, down: false },
        ]
    );
    assert!(!r.router.is_holding());
}

#[test]
fn release_all_ends_an_open_scroll() {
    for mut r in [Rig::new(), Rig::client_momentum()] {
        r.send(phase(-8.0, GesturePhase::Began));
        r.send(phase(-8.0, GesturePhase::Ended));
        r.send(momentum(-30.0, MomentumPhase::Began));
        r.send(phase(-8.0, GesturePhase::Began)); // a new touch mid-fling
        assert!(r.router.scroll_open());
        // The host ending the session: the client can no longer close it.
        assert_eq!(r.release_all(), [STOP]);
        assert!(!r.router.scroll_open());
    }
}

#[test]
fn release_all_adds_nothing_when_the_client_closed_the_scroll() {
    for client in [false, true] {
        let mut r = if client { Rig::client_momentum() } else { Rig::new() };
        for m in [
            phase(-8.0, GesturePhase::Began),
            phase(0.0, GesturePhase::Cancelled),
            momentum(-30.0, MomentumPhase::Began),
            momentum(0.0, MomentumPhase::Ended),
        ] {
            r.send(m);
        }
        if client {
            // The client's end is held back; release-all can't wait for it.
            r.out.clear();
            assert_eq!(r.send(release(ReleaseReason::FocusLost)), Outcome::Released);
            assert_eq!(r.take(), [STOP]);
            continue;
        }
        r.out.clear();
        assert_eq!(r.send(release(ReleaseReason::FocusLost)), Outcome::Released);
        assert_eq!(r.take(), []);
    }
}

#[test]
fn non_input_messages_are_left_to_the_caller() {
    let mut r = Rig::new();
    let messages = [
        Message::Ping(Ping { id: 1, sent_at_ns: 2 }),
        Message::HostSetup(HostSetup { items: vec![], video_problem: String::new(), has_other_display: false }),
        Message::KeyframeRequest(KeyframeRequest { reason: KeyframeReason::Startup, last_good_frame_id: 0 }),
    ];
    for m in messages {
        assert_eq!(r.send(m), Outcome::NotInput);
    }
    assert_eq!(r.take(), []);
}

#[test]
fn pinch_out_presses_ctrl_and_zooms_in() {
    let mut r = Rig::new();
    assert_eq!(r.send(magnify(GesturePhase::Began, 0.0)), Outcome::Ignored);
    assert_eq!(r.send(magnify(GesturePhase::Changed, 0.2)), Outcome::Ignored);
    assert_eq!(r.send(magnify(GesturePhase::Changed, 0.1)), Outcome::Injected { pointer: None });
    let wheel_up = InputAction::Scroll { dx: 0.0, dy: -10.0, source: ScrollSource::Wheel };
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), wheel_up, up(KEY_LEFTCTRL)]);
}

#[test]
fn pinch_with_keys_presses_ctrl_equals() {
    let mut r = Rig::with(InputConfig { zoom: ZoomAction::CtrlKeys, ..InputConfig::default() });
    r.send(magnify(GesturePhase::Changed, 0.3));
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), down(KEY_EQUAL), up(KEY_EQUAL), up(KEY_LEFTCTRL)]);
    r.send(magnify(GesturePhase::Changed, -0.3)); // 1.0: back to the anchor below 1.25
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), down(KEY_MINUS), up(KEY_MINUS), up(KEY_LEFTCTRL)]);
}

#[test]
fn pinch_in_zooms_out_and_keeps_held_modifiers() {
    let mut r = Rig::new();
    r.send(key(0xE1, true, M::SHIFT));
    r.out.clear();
    r.send(magnify(GesturePhase::Changed, -0.25));
    let wheel_down = InputAction::Scroll { dx: 0.0, dy: 10.0, source: ScrollSource::Wheel };
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), wheel_down, up(KEY_LEFTCTRL)]);
    assert_eq!(r.release_all(), [up(KEY_LEFTSHIFT)], "Shift stayed held throughout");
}

#[test]
fn pinch_with_ctrl_already_held_does_not_touch_ctrl() {
    let mut r = Rig::new();
    r.send(key(0xE3, true, M::COMMAND)); // Command → Ctrl
    r.out.clear();
    r.send(magnify(GesturePhase::Changed, 0.3));
    assert_eq!(r.take(), [InputAction::Scroll { dx: 0.0, dy: -10.0, source: ScrollSource::Wheel }]);
}

#[test]
fn one_pinch_event_crossing_several_factors_holds_ctrl_once() {
    let mut r = Rig::with(InputConfig { zoom: ZoomAction::CtrlKeys, ..InputConfig::default() });
    r.send(magnify(GesturePhase::Changed, 1.0)); // 2.0: three steps
    let mut want = vec![down(KEY_LEFTCTRL)];
    for _ in 0..3 {
        want.extend([down(KEY_EQUAL), up(KEY_EQUAL)]);
    }
    want.push(up(KEY_LEFTCTRL));
    assert_eq!(r.take(), want);
}

/// A zoom key the client holds is released before a Ctrl-keys step, never pressed twice; the client's own
/// release later is an orphan. (Review S3.)
#[test]
fn ctrl_keys_zoom_while_equal_is_held_presses_it_once() {
    let mut r = Rig::with(InputConfig { zoom: ZoomAction::CtrlKeys, ..InputConfig::default() });
    r.send(key(0x2E, true, M::EMPTY));
    r.send(magnify(GesturePhase::Changed, 0.3));
    assert_eq!(r.send(key(0x2E, false, M::EMPTY)), Outcome::Ignored);
    assert_eq!(
        r.take(),
        [down(KEY_EQUAL), up(KEY_EQUAL), down(KEY_LEFTCTRL), down(KEY_EQUAL), up(KEY_EQUAL), up(KEY_LEFTCTRL)]
    );
    assert!(!r.router.is_holding());
}

/// The client recognizes pan and pinch together: a zoom step goes out inside the open finger sequence, which
/// stays open (no stop, so no fling mid-gesture), unlike a client wheel scroll. (Review S4.)
#[test]
fn a_pinch_during_an_open_pan_leaves_the_sequence_open() {
    let mut r = Rig::new();
    r.send(phase(3.0, GesturePhase::Began));
    r.send(magnify(GesturePhase::Changed, 0.3));
    r.send(phase(3.0, GesturePhase::Changed));
    assert!(r.router.scroll_open());
    r.send(phase(0.0, GesturePhase::Ended));
    let wheel_up = InputAction::Scroll { dx: 0.0, dy: -10.0, source: ScrollSource::Wheel };
    assert_eq!(r.take(), [finger(-3.0), down(KEY_LEFTCTRL), wheel_up, up(KEY_LEFTCTRL), finger(-3.0), STOP]);
}

#[test]
fn pinch_accumulator_resets_at_gesture_end() {
    let mut r = Rig::new();
    r.send(magnify(GesturePhase::Changed, 0.2));
    r.send(magnify(GesturePhase::Ended, 0.0));
    assert_eq!(r.router.pinch().scale(), 1.0);
    r.send(magnify(GesturePhase::Began, 0.0));
    r.send(magnify(GesturePhase::Changed, 0.2));
    assert_eq!(r.take(), [], "two separate 1.2× pinches never add up to a step");
    r.send(magnify(GesturePhase::Cancelled, 0.0));
    assert_eq!(r.router.pinch().scale(), 1.0);
}

#[test]
fn release_all_resets_pinch() {
    let mut r = Rig::new();
    r.send(magnify(GesturePhase::Changed, 0.2));
    assert_eq!(r.send(release(ReleaseReason::PointerLockLost)), Outcome::Released);
    assert_eq!(r.router.pinch().scale(), 1.0);
    assert_eq!(r.take(), []);
}

#[test]
fn rotate_is_ignored() {
    let mut r = Rig::new();
    let rotate = || Message::Gesture(Gesture { kind: GestureKind::Rotate, phase: GesturePhase::Changed, value: 1.5 });
    assert_eq!(r.send(rotate()), Outcome::Ignored);
    assert_eq!(r.send(rotate()), Outcome::Ignored);
    assert_eq!(r.take(), []);
}

#[test]
fn the_pinch_threshold_is_configurable() {
    let mut r = Rig::with(InputConfig { pinch_threshold: 1.1, ..InputConfig::default() });
    assert_eq!(r.send(magnify(GesturePhase::Changed, 0.12)), Outcome::Injected { pointer: None });
}

// MARK: Swift's InjectorMapping

#[test]
fn buttons_map_to_btn_codes() {
    assert_eq!(InputRouter::button_code(MouseButton::Left), BTN_LEFT);
    assert_eq!(InputRouter::button_code(MouseButton::Right), BTN_RIGHT);
    assert_eq!(InputRouter::button_code(MouseButton::Other), BTN_MIDDLE);
    let mut r = Rig::new();
    r.send(mv(5.0, 5.0));
    r.out.clear();
    for b in MouseButton::ALL {
        r.send(button(*b, true, 5.0, 5.0, M::EMPTY));
        r.send(button(*b, false, 5.0, 5.0, M::EMPTY));
    }
    let at = InputAction::MoveTo(PointF::new(5.0, 5.0));
    let mut want = Vec::new();
    for code in [BTN_LEFT, BTN_RIGHT, BTN_MIDDLE] {
        want.extend([at, InputAction::Button { code, down: true }, at, InputAction::Button { code, down: false }]);
    }
    assert_eq!(r.take(), want);
}

/// Swift's `movesWithAButtonHeldAreDrags`: Linux has no drag event types; a move with the button held is the
/// drag.
#[test]
fn a_move_with_a_button_held_is_a_drag() {
    let mut r = Rig::new();
    r.send(button(MouseButton::Left, true, 1.0, 2.0, M::EMPTY));
    r.send(mv(3.0, 4.0));
    r.send(button(MouseButton::Left, false, 3.0, 4.0, M::EMPTY));
    assert_eq!(
        r.take(),
        [
            InputAction::MoveTo(PointF::new(1.0, 2.0)),
            InputAction::Button { code: BTN_LEFT, down: true },
            InputAction::MoveTo(PointF::new(3.0, 4.0)),
            InputAction::MoveTo(PointF::new(3.0, 4.0)),
            InputAction::Button { code: BTN_LEFT, down: false },
        ]
    );
}

// MARK: Keys

#[test]
fn keys_press_and_release_their_evdev_code() {
    let mut r = Rig::new();
    assert_eq!(r.actions(key(0x04, true, M::EMPTY)), [down(KEY_A)]);
    assert_eq!(r.actions(key(0x04, false, M::EMPTY)), [up(KEY_A)]);
    assert_eq!(r.actions(key(0x64, true, M::EMPTY)), [down(KEY_102ND)]);
    assert_eq!(r.actions(key(0x87, true, M::EMPTY)), [down(KEY_RO)]);
    assert_eq!(r.actions(key(0x89, true, M::EMPTY)), [down(KEY_YEN)]);
    assert_eq!(r.actions(key(0x90, true, M::EMPTY)), [down(KEY_HANGEUL)]);
    assert_eq!(r.router.held_keys(), [KEY_102ND, KEY_RO, KEY_YEN, KEY_HANGEUL]);
}

#[test]
fn every_kernel_key_goes_through_the_router() {
    let mut r = Rig::new();
    for usage in 0..=0xFFu16 {
        let Some(code) = lain_input::keymap::evdev_key(usage) else {
            assert_eq!(r.send(key(usage, true, M::EMPTY)), Outcome::Ignored, "usage {usage:#04x}");
            continue;
        };
        if (0xE0..=0xE7).contains(&usage) {
            continue; // modifiers: below
        }
        if lain_input::keymap::SYSTEM_KEYS.contains(&code) {
            assert_eq!(r.send(key(usage, true, M::EMPTY)), Outcome::Ignored, "usage {usage:#04x}");
            continue; // dropped by default: below
        }
        let held_before = r.router.held_keys().contains(&code);
        let got = r.actions(key(usage, true, M::EMPTY));
        // 0x31/0x32 and the media duplicates share a code: the second is a duplicate press.
        assert_eq!(got, if held_before { vec![] } else { vec![down(code)] }, "usage {usage:#04x}");
    }
    let mut desktop = Desktop::default();
    let mut all = r.router.held_keys().iter().map(|&c| down(c)).collect::<Vec<_>>();
    all.extend(r.release_all());
    desktop.apply(&all);
    assert!(desktop.is_idle());
}

/// Power, Sleep, Coffee (GNOME's screen lock) and Eject would suspend, lock or power off the host; Swift has
/// no code for them, so by default they are dropped. (Review K1/P6.)
#[test]
fn power_sleep_lock_and_eject_are_dropped_by_default() {
    let usages = [(0x66, KEY_POWER), (0xF8, KEY_SLEEP), (0xF9, KEY_COFFEE), (0xEC, KEY_EJECTCD)];
    let mut r = Rig::new();
    for (usage, _) in usages {
        assert_eq!(r.send(key(usage, true, M::EMPTY)), Outcome::Ignored, "{usage:#04x}");
        assert_eq!(r.send(key(usage, false, M::EMPTY)), Outcome::Ignored, "{usage:#04x}");
    }
    assert_eq!(r.take(), []);

    let mut r = Rig::with(InputConfig { allow_system_keys: true, ..InputConfig::default() });
    for (usage, code) in usages {
        assert_eq!(r.actions(key(usage, true, M::EMPTY)), [down(code)], "{usage:#04x}");
        assert_eq!(r.actions(key(usage, false, M::EMPTY)), [up(code)], "{usage:#04x}");
    }
}

#[test]
fn repeats_are_dropped() {
    let mut r = Rig::new();
    r.send(key(0x04, true, M::EMPTY));
    r.out.clear();
    assert_eq!(r.send(repeat(0x04, M::EMPTY)), Outcome::Ignored);
    assert_eq!(r.send(repeat(0x05, M::EMPTY)), Outcome::Ignored, "a repeat of a key not held");
    assert_eq!(r.take(), []);
}

#[test]
fn duplicate_presses_and_orphan_releases_are_dropped() {
    let mut r = Rig::new();
    r.send(key(0x04, true, M::EMPTY));
    assert_eq!(r.send(key(0x04, true, M::EMPTY)), Outcome::Ignored);
    r.send(key(0x04, false, M::EMPTY));
    assert_eq!(r.send(key(0x04, false, M::EMPTY)), Outcome::Ignored);
    assert_eq!(r.send(key(0x05, false, M::EMPTY)), Outcome::Ignored);
    assert_eq!(r.take(), [down(KEY_A), up(KEY_A)]);
}

#[test]
fn unknown_keys_are_ignored() {
    let mut r = Rig::new();
    for usage in [0x00, 0x01, 0x82, 0xA5, 0xFF, 0x100, 0xFFFF] {
        assert_eq!(r.send(key(usage, true, M::EMPTY)), Outcome::Ignored, "usage {usage:#x}");
        assert_eq!(r.send(key(usage, true, M::EMPTY)), Outcome::Ignored, "again, logged once");
    }
    assert_eq!(r.send(page_key(0x0C, 0xE9, true, M::EMPTY)), Outcome::Ignored, "consumer volume");
    assert_eq!(r.send(page_key(0x01, 0x81, true, M::EMPTY)), Outcome::Ignored);
    assert_eq!(r.take(), []);
}

#[test]
fn an_unknown_key_still_carries_its_modifiers() {
    let mut r = Rig::new();
    assert_eq!(r.send(key(0xA5, true, M::COMMAND)), Outcome::Injected { pointer: None });
    assert_eq!(r.take(), [down(KEY_LEFTCTRL)]);
}

/// Caps Lock is a toggle: its key goes to the desktop (whose lock state follows it), the flag never holds
/// anything.
#[test]
fn caps_lock_is_the_key_and_the_flag_is_ignored() {
    let mut r = Rig::new();
    r.send(key(0x39, true, M::CAPS_LOCK));
    r.send(key(0x39, false, M::CAPS_LOCK));
    r.send(key(0x04, true, M::CAPS_LOCK));
    r.send(key(0x04, false, M::CAPS_LOCK));
    r.send(key(0x39, true, M::EMPTY));
    r.send(key(0x39, false, M::EMPTY));
    assert_eq!(
        r.take(),
        [down(KEY_CAPSLOCK), up(KEY_CAPSLOCK), down(KEY_A), up(KEY_A), down(KEY_CAPSLOCK), up(KEY_CAPSLOCK)]
    );
}

#[test]
fn iso_keys_swap_only_when_configured_and_the_keyboard_is_iso() {
    let mut plain = Rig::new();
    plain.router.set_keyboard_type(KeyboardType::Iso);
    assert_eq!(plain.actions(key(0x64, true, M::EMPTY)), [down(KEY_102ND)]);
    assert_eq!(plain.actions(key(0x35, true, M::EMPTY)), [down(KEY_GRAVE)]);

    let config = InputConfig { swap_iso_keys: true, ..InputConfig::default() };
    let mut ansi = Rig::with(config);
    ansi.router.set_keyboard_type(KeyboardType::Ansi);
    assert_eq!(ansi.actions(key(0x64, true, M::EMPTY)), [down(KEY_102ND)]);

    let mut iso = Rig::with(config);
    iso.router.set_keyboard_type(KeyboardType::Iso);
    assert_eq!(iso.actions(key(0x64, true, M::EMPTY)), [down(KEY_GRAVE)]);
    assert_eq!(iso.actions(key(0x35, true, M::EMPTY)), [down(KEY_102ND)]);
    assert_eq!(iso.actions(key(0x64, false, M::EMPTY)), [up(KEY_GRAVE)]);
}

// MARK: Modifiers

#[test]
fn command_c_is_ctrl_c() {
    let mut r = Rig::new();
    for m in [key(0xE3, true, M::COMMAND), key(0x06, true, M::COMMAND), key(0x06, false, M::COMMAND)] {
        r.send(m);
    }
    assert_eq!(r.send(key(0xE3, false, M::EMPTY)), Outcome::Injected { pointer: None });
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), down(KEY_C), up(KEY_C), up(KEY_LEFTCTRL)]);
}

#[test]
fn right_hand_modifiers_hold_the_same_key() {
    let mut r = Rig::with(InputConfig { system_key: false, ..InputConfig::default() });
    r.send(key(0xE7, true, M::COMMAND));
    r.send(key(0xE6, true, M::COMMAND | M::OPTION));
    r.send(key(0xE5, true, M::COMMAND | M::OPTION | M::SHIFT));
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), down(KEY_LEFTALT), down(KEY_LEFTSHIFT)]);
}

#[test]
fn two_mac_modifiers_on_one_linux_modifier_hold_it_until_both_are_up() {
    let mut r = Rig::new();
    r.send(key(0xE3, true, M::COMMAND));
    assert_eq!(r.send(key(0xE0, true, M::COMMAND | M::CONTROL)), Outcome::Ignored);
    assert_eq!(r.send(key(0xE3, false, M::CONTROL)), Outcome::Ignored);
    assert_eq!(r.send(key(0xE0, false, M::EMPTY)), Outcome::Injected { pointer: None });
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), up(KEY_LEFTCTRL)]);
}

#[test]
fn function_holds_nothing_by_default_and_can_be_mapped() {
    let mut r = Rig::new();
    assert_eq!(r.send(page_key(0x0C, 0x29D, true, M::FUNCTION)), Outcome::Ignored);
    assert_eq!(r.send(page_key(0x0C, 0x29D, false, M::EMPTY)), Outcome::Ignored);
    assert_eq!(r.take(), []);

    let map = ModifierMap { function: Some(LinuxModifier::Super), ..ModifierMap::default() };
    let mut r = Rig::with(InputConfig { modifiers: map, ..InputConfig::default() });
    r.send(page_key(0xFF, 0x03, true, M::FUNCTION));
    r.send(page_key(0xFF, 0x03, false, M::EMPTY));
    assert_eq!(r.take(), [down(KEY_LEFTMETA), up(KEY_LEFTMETA)]);
}

/// The client's hold remap (Swift: `KeyboardProcessor`, Opt-H → Cmd-H): it releases Option and presses
/// Command itself, as key events; the router follows the flags.
#[test]
fn the_clients_hold_remap() {
    let mut r = Rig::new();
    let messages = [
        key(0xE2, true, M::OPTION),
        key(0xE2, false, M::EMPTY),  // the remap releases the source…
        key(0xE3, true, M::COMMAND), // …presses the target…
        key(0x14, true, M::COMMAND), // …then the key
        key(0x14, false, M::COMMAND),
        key(0xE3, false, M::EMPTY), // Option lifted: the target is released
    ];
    for m in messages {
        r.send(m);
    }
    assert_eq!(
        r.take(),
        [down(KEY_LEFTALT), up(KEY_LEFTALT), down(KEY_LEFTCTRL), down(KEY_Q), up(KEY_Q), up(KEY_LEFTCTRL)]
    );
}

/// The client's Opt-Tab is its way to the Mac's Cmd-Tab, the app switcher: on GNOME that is Alt+Tab, held
/// until the user lifts Option (the client's Command), across repeated Tabs and Shift-Tabs. (Review P1.)
#[test]
fn the_clients_opt_tab_is_the_desktops_app_switcher() {
    let mut r = Rig::new();
    let messages = [
        key(0xE2, true, M::OPTION),
        key(0xE2, false, M::EMPTY),
        key(0xE3, true, M::COMMAND),
        key(0x2B, true, M::COMMAND), // Ctrl becomes Alt before Tab
        key(0x2B, false, M::COMMAND),
        key(0xE1, true, M::COMMAND | M::SHIFT),
        key(0x2B, true, M::COMMAND | M::SHIFT), // backwards
        key(0x2B, false, M::COMMAND | M::SHIFT),
        key(0xE1, false, M::COMMAND),
        key(0x2B, true, M::COMMAND),
        key(0x2B, false, M::COMMAND),
        key(0xE3, false, M::EMPTY), // Option lifted: the switcher commits
    ];
    for m in messages {
        r.send(m);
    }
    assert_eq!(
        r.take(),
        [
            down(KEY_LEFTALT),
            up(KEY_LEFTALT),
            down(KEY_LEFTCTRL),
            up(KEY_LEFTCTRL),
            down(KEY_LEFTALT),
            down(KEY_TAB),
            up(KEY_TAB),
            down(KEY_LEFTSHIFT),
            down(KEY_TAB),
            up(KEY_TAB),
            up(KEY_LEFTSHIFT),
            down(KEY_TAB),
            up(KEY_TAB),
            up(KEY_LEFTALT),
        ]
    );
    assert!(!r.router.is_holding());
    // Command alone is Ctrl again once released, and Cmd-` holds Alt too.
    assert_eq!(r.actions(key(0xE3, true, M::COMMAND)), [down(KEY_LEFTCTRL)]);
    assert_eq!(r.actions(key(0x35, true, M::COMMAND)), [up(KEY_LEFTCTRL), down(KEY_LEFTALT), down(KEY_GRAVE)]);
    assert_eq!(r.release_all(), [up(KEY_GRAVE), up(KEY_LEFTALT)]);
    assert_eq!(r.actions(key(0xE3, true, M::COMMAND)), [down(KEY_LEFTCTRL)], "release-all ends the shortcut");
}

#[test]
fn command_shortcuts_are_configurable() {
    let mut r = Rig::with(InputConfig { command_shortcuts: &[], ..InputConfig::default() });
    r.send(key(0xE3, true, M::COMMAND));
    r.send(key(0x2B, true, M::COMMAND));
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), down(KEY_TAB)]);

    const H: &[CommandShortcut] = &[CommandShortcut { usage: 0x0B, hold: LinuxModifier::Super }];
    let mut r = Rig::with(InputConfig { command_shortcuts: H, ..InputConfig::default() });
    r.send(key(0xE3, true, M::COMMAND));
    r.send(key(0x0B, true, M::COMMAND));
    r.send(key(0x0B, false, M::COMMAND));
    r.send(key(0xE3, false, M::EMPTY));
    assert_eq!(
        r.take(),
        [down(KEY_LEFTCTRL), up(KEY_LEFTCTRL), down(KEY_LEFTMETA), down(KEY_H), up(KEY_H), up(KEY_LEFTMETA)]
    );
}

/// Modifier flags that change with no modifier key event: a button carrying them.
#[test]
fn a_button_brings_the_modifiers_it_carries() {
    let mut r = Rig::new();
    r.send(mv(1.0, 1.0));
    r.out.clear();
    r.send(button(MouseButton::Left, true, 1.0, 1.0, M::SHIFT | M::COMMAND));
    r.send(button(MouseButton::Left, false, 1.0, 1.0, M::EMPTY));
    assert_eq!(
        r.take(),
        [
            down(KEY_LEFTCTRL),
            down(KEY_LEFTSHIFT),
            InputAction::MoveTo(PointF::new(1.0, 1.0)),
            InputAction::Button { code: BTN_LEFT, down: true },
            up(KEY_LEFTSHIFT),
            up(KEY_LEFTCTRL),
            InputAction::MoveTo(PointF::new(1.0, 1.0)),
            InputAction::Button { code: BTN_LEFT, down: false },
        ]
    );
}

/// A remap at run time, with modifiers held and no key event: the held keys follow the new map.
#[test]
fn changing_the_map_moves_held_modifiers() {
    let mut r = Rig::new();
    r.send(key(0xE3, true, M::COMMAND));
    r.send(key(0xE2, true, M::COMMAND | M::OPTION));
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), down(KEY_LEFTALT)]);

    let swapped =
        ModifierMap { command: Some(LinuxModifier::Super), option: Some(LinuxModifier::Alt), ..ModifierMap::default() };
    r.router.set_modifier_map(swapped, &mut r.out);
    assert_eq!(r.take(), [up(KEY_LEFTCTRL), down(KEY_LEFTMETA)]);
    assert_eq!(r.router.config().modifiers, swapped);

    let nothing = ModifierMap { command: None, option: None, ..ModifierMap::default() };
    r.router.set_modifier_map(nothing, &mut r.out);
    assert_eq!(
        r.take(),
        [up(KEY_LEFTMETA), up(KEY_LEFTALT)],
        "releases in the fixed order (reverse of LinuxModifier::ALL)"
    );
    r.router.set_modifier_map(nothing, &mut r.out);
    assert_eq!(r.take(), [], "no change, nothing to do");

    r.router.set_modifier_map(ModifierMap::default(), &mut r.out);
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), down(KEY_LEFTALT)]);
    assert_eq!(r.release_all(), [up(KEY_LEFTALT), up(KEY_LEFTCTRL)]);
    r.router.set_modifier_map(swapped, &mut r.out);
    assert_eq!(r.take(), [], "nothing held after a release");
}

// MARK: Pointer

/// Every button change carries its position, even where the client's last move was: the desktop's pointer
/// may have been moved by something else since (the local mouse, an app's warp). Swift posts every click at
/// its position. (Review P2.)
#[test]
fn a_button_always_moves_to_its_position_first() {
    let mut r = Rig::new();
    r.send(mv(10.0, 10.0));
    r.out.clear();
    r.send(button(MouseButton::Right, true, 10.0, 10.0, M::EMPTY));
    r.send(button(MouseButton::Right, false, -1512.0, 300.5, M::EMPTY)); // after a warp, on another monitor
    assert_eq!(
        r.take(),
        [
            InputAction::MoveTo(PointF::new(10.0, 10.0)),
            InputAction::Button { code: BTN_RIGHT, down: true },
            InputAction::MoveTo(PointF::new(-1512.0, 300.5)),
            InputAction::Button { code: BTN_RIGHT, down: false },
        ]
    );
    // A duplicate press changes nothing, so it moves nothing either.
    r.send(button(MouseButton::Left, true, 1.0, 1.0, M::EMPTY));
    r.out.clear();
    assert_eq!(r.send(button(MouseButton::Left, true, 2.0, 2.0, M::EMPTY)), Outcome::Ignored);
    assert_eq!(r.take(), []);
}

#[test]
fn duplicate_button_presses_are_dropped() {
    let mut r = Rig::new();
    r.send(button(MouseButton::Left, true, 0.0, 0.0, M::EMPTY));
    r.out.clear();
    assert_eq!(r.send(button(MouseButton::Left, true, 0.0, 0.0, M::EMPTY)), Outcome::Ignored);
    assert_eq!(r.send(button(MouseButton::Right, false, 0.0, 0.0, M::EMPTY)), Outcome::Ignored);
    assert_eq!(r.take(), []);
}

#[test]
fn non_finite_positions_are_not_sent() {
    let mut r = Rig::new();
    assert_eq!(r.send(mv(f64::NAN, 1.0)), Outcome::Ignored);
    assert_eq!(r.send(mv(1.0, f64::INFINITY)), Outcome::Ignored);
    assert_eq!(r.send(button(MouseButton::Left, true, f64::NAN, 0.0, M::EMPTY)), Outcome::Injected { pointer: None });
    assert_eq!(r.take(), [InputAction::Button { code: BTN_LEFT, down: true }]);
}

// MARK: Scroll

#[test]
fn scroll_deltas_are_negated_into_wayland_convention() {
    let mut r = Rig::new();
    // Fingers moving down and right (content follows): towards the top and left of the document.
    assert_eq!(
        r.actions(scroll(3.0, 12.5, GesturePhase::Began, MomentumPhase::None)),
        [InputAction::Scroll { dx: -3.0, dy: -12.5, source: ScrollSource::Finger }]
    );
}

#[test]
fn desktop_momentum_phases_then_a_stop_and_no_client_momentum() {
    let mut r = Rig::new();
    assert_eq!(r.send(phase(0.0, GesturePhase::MayBegin)), Outcome::Ignored);
    r.send(phase(-8.0, GesturePhase::Began));
    r.send(phase(-4.0, GesturePhase::Changed));
    assert_eq!(r.send(phase(0.0, GesturePhase::Ended)), Outcome::Injected { pointer: None });
    for m in [momentum(-30.0, MomentumPhase::Began), momentum(-20.0, MomentumPhase::Changed)] {
        assert_eq!(r.send(m), Outcome::Ignored);
    }
    assert_eq!(r.send(momentum(0.0, MomentumPhase::Ended)), Outcome::Ignored);
    assert_eq!(r.take(), [finger(8.0), finger(4.0), STOP]);
    assert!(!r.router.scroll_open());
}

#[test]
fn a_phase_that_never_moved_sends_nothing() {
    for mut r in [Rig::new(), Rig::client_momentum()] {
        assert_eq!(r.send(phase(0.0, GesturePhase::Began)), Outcome::Ignored);
        assert_eq!(r.send(phase(0.0, GesturePhase::Ended)), Outcome::Ignored);
        assert_eq!(r.send(phase(0.0, GesturePhase::Cancelled)), Outcome::Ignored);
        assert_eq!(r.take(), []);
    }
}

#[test]
fn a_cancelled_phase_stops() {
    let mut r = Rig::new();
    r.send(phase(5.0, GesturePhase::Began));
    r.send(phase(0.0, GesturePhase::Cancelled));
    assert_eq!(r.take(), [finger(-5.0), STOP]);

    // With the client's momentum, after the velocity window, so the toolkit doesn't fling (nor does the Mac).
    let mut r = Rig::client_momentum();
    r.send(phase(5.0, GesturePhase::Began));
    r.send(phase(0.0, GesturePhase::Cancelled));
    assert!(!r.advance(STOP_DELAY - 1));
    assert!(r.advance(1));
    assert_eq!(r.take(), [finger(-5.0), STOP]);
}

#[test]
fn an_end_with_a_delta_scrolls_then_stops() {
    let mut r = Rig::new();
    r.send(phase(5.0, GesturePhase::Began));
    r.send(phase(2.0, GesturePhase::Ended));
    assert_eq!(r.take(), [finger(-5.0), finger(-2.0), STOP]);
}

#[test]
fn a_wheel_is_a_wheel_and_ends_an_open_sequence() {
    let mut r = Rig::new();
    let wheel = InputAction::Scroll { dx: 0.0, dy: 10.0, source: ScrollSource::Wheel };
    assert_eq!(r.actions(scroll(0.0, -10.0, GesturePhase::None, MomentumPhase::None)), [wheel]);
    assert!(!r.router.scroll_open(), "a wheel opens nothing");
    r.send(phase(5.0, GesturePhase::Began));
    r.send(scroll(0.0, -10.0, GesturePhase::None, MomentumPhase::None));
    assert_eq!(r.take(), [finger(-5.0), STOP, wheel]);
    assert_eq!(r.send(scroll(0.0, 0.0, GesturePhase::None, MomentumPhase::None)), Outcome::Ignored);
}

#[test]
fn the_phased_source_is_configurable() {
    let config = InputConfig {
        scroll: ScrollConfig { phased_source: ScrollSource::Continuous, ..ScrollConfig::default() },
        ..InputConfig::default()
    };
    let mut r = Rig::with(config);
    r.send(phase(5.0, GesturePhase::Began));
    r.send(phase(0.0, GesturePhase::Ended));
    assert_eq!(
        r.take(),
        [
            InputAction::Scroll { dx: 0.0, dy: -5.0, source: ScrollSource::Continuous },
            InputAction::ScrollStop { source: ScrollSource::Continuous },
        ]
    );
}

#[test]
fn non_finite_scroll_deltas_are_zero() {
    let mut r = Rig::new();
    assert_eq!(r.send(scroll(f32::NAN, f32::INFINITY, GesturePhase::Began, MomentumPhase::None)), Outcome::Ignored);
    assert_eq!(r.actions(scroll(f32::NAN, 2.0, GesturePhase::Changed, MomentumPhase::None)), [finger(-2.0)]);
}

#[test]
fn client_momentum_continues_the_sequence_and_stops_after_the_velocity_window() {
    let mut r = Rig::client_momentum();
    r.send(phase(8.0, GesturePhase::Began));
    assert_eq!(r.send(phase(0.0, GesturePhase::Ended)), Outcome::Ignored, "the stop waits for the momentum");
    assert!(r.router.scroll_open());
    r.now += 8 * MS;
    assert_eq!(r.send(momentum(30.0, MomentumPhase::Began)), Outcome::Injected { pointer: None });
    r.send(mv(1.0, 1.0)); // the pointer moving doesn't end the momentum
    r.now += 8 * MS;
    r.send(momentum(0.5, MomentumPhase::Changed));
    r.now += 8 * MS;
    assert_eq!(r.send(momentum(0.0, MomentumPhase::Ended)), Outcome::Ignored, "the stop is held back");
    assert_eq!(r.router.next_deadline(), Some(r.now - 8 * MS + STOP_DELAY), "from the last delta");
    assert!(!r.advance(STOP_DELAY - 8 * MS - 1));
    assert!(r.advance(1));
    assert_eq!(r.router.next_deadline(), None);
    assert_eq!(r.take(), [finger(-8.0), finger(-30.0), InputAction::MoveTo(PointF::new(1.0, 1.0)), finger(-0.5), STOP]);
}

/// The client starts no momentum after a slow lift (under 150 pt/s): the stop still goes out, at the
/// deadline, without a fling (the Mac has none either). (Review S2/P4.)
#[test]
fn a_slow_lift_with_client_momentum_stops_at_the_deadline() {
    let mut r = Rig::client_momentum();
    r.send(phase(1.0, GesturePhase::Began));
    r.send(phase(1.0, GesturePhase::Changed));
    r.send(phase(0.0, GesturePhase::Ended));
    assert_eq!(r.take(), [finger(-1.0), finger(-1.0)]);
    assert!(r.advance(STOP_DELAY));
    assert_eq!(r.take(), [STOP]);
    assert!(!r.router.scroll_open());
    // Without a poll, the first message after the deadline sends it before its own actions.
    r.send(phase(1.0, GesturePhase::Began));
    r.send(phase(0.0, GesturePhase::Ended));
    r.now += STOP_DELAY;
    assert_eq!(r.send(key(0x04, true, M::EMPTY)), Outcome::Injected { pointer: None });
    assert_eq!(r.take(), [finger(-1.0), STOP, down(KEY_A)]);
    // Momentum after the stop is dropped: the sequence is over.
    assert_eq!(r.send(momentum(30.0, MomentumPhase::Began)), Outcome::Ignored);
}

/// Other input while the stop is held back goes out inside the open sequence, and momentum may still follow
/// it.
#[test]
fn other_input_does_not_end_a_held_back_stop() {
    let mut r = Rig::client_momentum();
    r.send(phase(8.0, GesturePhase::Began));
    r.send(phase(0.0, GesturePhase::Ended));
    r.send(key(0x04, true, M::EMPTY));
    r.now += 8 * MS;
    assert_eq!(r.send(momentum(30.0, MomentumPhase::Began)), Outcome::Injected { pointer: None });
    assert_eq!(r.take(), [finger(-8.0), down(KEY_A), finger(-30.0)]);
    assert!(r.router.scroll_open());
}

/// The client cuts its momentum short when a touch begins, and the new touch follows at once: it continues
/// the sequence, with no stop after the momentum's fast deltas, so nothing flings. (Review S1.)
#[test]
fn a_new_touch_during_client_momentum_continues_without_a_stop() {
    let mut r = Rig::client_momentum();
    r.send(phase(8.0, GesturePhase::Began));
    r.send(phase(0.0, GesturePhase::Ended));
    r.send(phase(4.0, GesturePhase::Began)); // touched again before any momentum
    r.send(phase(0.0, GesturePhase::Ended));
    r.send(momentum(30.0, MomentumPhase::Began));
    r.send(momentum(29.0, MomentumPhase::Changed));
    r.send(momentum(0.0, MomentumPhase::Ended)); // the client ends momentum when a touch begins
    r.send(phase(2.0, GesturePhase::Began));
    assert_eq!(r.take(), [finger(-8.0), finger(-4.0), finger(-30.0), finger(-29.0), finger(-2.0)]);
}

/// A click cuts the client's momentum short ("a click stops a fling, as on the Mac"): the click goes out
/// inside the open sequence, and the stop only after the velocity window, so the toolkit doesn't fling from
/// the momentum's fast deltas. (Review P3.)
#[test]
fn a_click_during_client_momentum_stops_without_a_fling() {
    let mut r = Rig::client_momentum();
    r.send(phase(40.0, GesturePhase::Began));
    r.send(phase(0.0, GesturePhase::Ended));
    r.now += 8 * MS;
    r.send(momentum(60.0, MomentumPhase::Began));
    r.now += MS;
    r.send(momentum(0.0, MomentumPhase::Ended));
    r.send(button(MouseButton::Left, true, 1.0, 1.0, M::EMPTY));
    assert_eq!(
        r.take(),
        [
            finger(-40.0),
            finger(-60.0),
            InputAction::MoveTo(PointF::new(1.0, 1.0)),
            InputAction::Button { code: BTN_LEFT, down: true }
        ]
    );
    let last_delta = r.now - MS;
    assert_eq!(r.router.next_deadline(), Some(last_delta + STOP_DELAY));
    assert!(r.advance(STOP_DELAY));
    assert_eq!(r.take(), [STOP]);
}

/// With the client's momentum, a wheel notch and release-all still stop at once (documented: the toolkit may
/// fling from recent fast deltas there).
#[test]
fn a_wheel_and_release_all_stop_a_held_back_sequence_at_once() {
    let wheel = InputAction::Scroll { dx: 0.0, dy: 10.0, source: ScrollSource::Wheel };
    let mut r = Rig::client_momentum();
    r.send(phase(8.0, GesturePhase::Began));
    r.send(phase(0.0, GesturePhase::Ended));
    r.send(scroll(0.0, -10.0, GesturePhase::None, MomentumPhase::None));
    assert_eq!(r.take(), [finger(-8.0), STOP, wheel]);

    r.send(phase(8.0, GesturePhase::Began));
    r.send(phase(0.0, GesturePhase::Ended));
    r.out.clear();
    assert_eq!(r.release_all(), [STOP]);
    assert_eq!(r.router.next_deadline(), None);
    assert!(!r.advance(STOP_DELAY));
}

#[test]
fn the_default_mode_has_no_deadline() {
    let mut r = Rig::new();
    r.send(phase(8.0, GesturePhase::Began));
    assert_eq!(r.router.next_deadline(), None);
    r.send(phase(0.0, GesturePhase::Ended));
    assert_eq!(r.router.next_deadline(), None);
    assert!(!r.advance(10 * STOP_DELAY));
    assert_eq!(r.take(), [finger(-8.0), STOP]);
}

/// Every sequence of up to five scroll-related steps (8 ms apart, or a 250 ms wait with a poll), in both
/// modes:
/// - stops always close an open sequence, and the router's view of it is the desktop's;
/// - by default, the client's momentum never reaches the desktop;
/// - with `Momentum::Client`, momentum never follows a stop (where the toolkit may fling) without a new phase
///   in between, and no stop goes out within GTK's 150 ms velocity window after a delta (so the toolkit never
///   flings), except right before a wheel notch and at release-all, which are documented.
///
/// Release-all then leaves nothing open.
#[test]
fn only_one_kinetic_continuation_ever() {
    #[derive(Debug, Clone)]
    enum Step {
        Send(Message),
        Wait,
    }
    let alphabet = [
        Step::Send(phase(3.0, GesturePhase::Began)),
        Step::Send(phase(2.0, GesturePhase::Changed)),
        Step::Send(phase(0.0, GesturePhase::Ended)),
        Step::Send(phase(0.0, GesturePhase::Cancelled)),
        Step::Send(momentum(9.0, MomentumPhase::Began)),
        Step::Send(momentum(5.0, MomentumPhase::Changed)),
        Step::Send(momentum(0.0, MomentumPhase::Ended)),
        Step::Send(scroll(0.0, 4.0, GesturePhase::None, MomentumPhase::None)),
        Step::Send(mv(1.0, 1.0)),
        Step::Send(button(MouseButton::Left, true, 1.0, 1.0, M::EMPTY)),
        Step::Wait,
    ];
    let n = alphabet.len();
    for mode in [Momentum::Desktop, Momentum::Client] {
        for len in 1..=5u32 {
            for mut index in 0..n.pow(len) {
                let config = InputConfig {
                    scroll: ScrollConfig { momentum: mode, ..ScrollConfig::default() },
                    ..Default::default()
                };
                let mut r = Rig::with(config);
                let mut desktop = Desktop::default();
                let mut flung = false; // a stop was sent and no phase scroll since
                let mut last_delta: Option<u64> = None;
                let mut seq = Vec::new();
                for _ in 0..len {
                    let step = alphabet[index % n].clone();
                    index /= n;
                    seq.push(step.clone());
                    r.out.clear();
                    let (is_momentum, is_phase, is_wheel) = match &step {
                        Step::Send(m) => {
                            r.now += 8 * MS;
                            r.send(m.clone());
                            match m {
                                Message::Scroll(s) => (
                                    s.momentum_phase != MomentumPhase::None,
                                    matches!(s.phase, GesturePhase::Began | GesturePhase::Changed),
                                    s.phase == GesturePhase::None && s.momentum_phase == MomentumPhase::None,
                                ),
                                _ => (false, false, false),
                            }
                        }
                        Step::Wait => {
                            r.advance(250 * MS);
                            (false, false, false)
                        }
                    };
                    let actions = r.take();
                    desktop.apply(&actions);
                    for a in &actions {
                        match a {
                            InputAction::Scroll { source: ScrollSource::Finger, .. } => {
                                if is_momentum {
                                    assert_eq!(mode, Momentum::Client, "momentum by default: {seq:?}");
                                    assert!(!flung, "momentum after a fling: {seq:?}");
                                }
                                if is_phase {
                                    flung = false;
                                }
                                last_delta = Some(r.now);
                            }
                            InputAction::ScrollStop { .. } => {
                                flung = true;
                                if mode == Momentum::Client && !is_wheel {
                                    let since = r.now - last_delta.unwrap();
                                    assert!(since > 150 * MS, "a stop {since} ns after a delta: {seq:?}");
                                }
                            }
                            _ => {}
                        }
                    }
                    assert_eq!(r.router.scroll_open(), desktop.scroll_open, "{seq:?}");
                }
                desktop.apply(&r.release_all());
                assert!(desktop.is_idle() && !r.router.is_holding(), "{seq:?}");
            }
        }
    }
}

// MARK: Release-all

/// Every sequence of up to four key, modifier and button messages (with ups that may be orphans and flags
/// that may disagree with the keys): the desktop never sees a double press or an orphan release, and
/// release-all leaves nothing held.
#[test]
fn release_all_after_any_sequence_leaves_nothing_held() {
    let alphabet = [
        key(0x04, true, M::EMPTY),
        key(0x04, false, M::EMPTY),
        key(0x05, true, M::COMMAND),
        key(0xE3, true, M::COMMAND),
        key(0xE3, false, M::EMPTY),
        key(0xE1, true, M::SHIFT | M::OPTION),
        repeat(0x05, M::CONTROL),
        button(MouseButton::Left, true, 1.0, 1.0, M::CONTROL),
        button(MouseButton::Left, false, 1.0, 1.0, M::EMPTY),
        button(MouseButton::Other, true, 2.0, 2.0, M::EMPTY),
        phase(2.0, GesturePhase::Changed),
        magnify(GesturePhase::Changed, 0.3),
        release(ReleaseReason::Disconnect),
        key(0x2E, true, M::EMPTY), // =, the zoom-in key
    ];
    let n = alphabet.len();
    for (len, zoom) in (1..=4u32).flat_map(|len| [(len, ZoomAction::CtrlWheel), (len, ZoomAction::CtrlKeys)]) {
        for mut index in 0..n.pow(len) {
            let mut r = Rig::with(InputConfig { zoom, ..InputConfig::default() });
            let mut desktop = Desktop::default();
            let mut seq = Vec::new();
            for _ in 0..len {
                let m = alphabet[index % n].clone();
                index /= n;
                seq.push(m.clone());
                desktop.apply(&r.actions(m));
            }
            desktop.apply(&r.release_all());
            assert!(desktop.is_idle(), "{seq:?}: {desktop:?}");
            assert!(!r.router.is_holding(), "{seq:?}");
            assert_eq!(r.release_all(), [], "a second release has nothing to do: {seq:?}");
        }
    }
}

#[test]
fn release_all_order_regular_keys_newest_first_then_modifiers_then_buttons() {
    let mut r = Rig::new();
    for m in [
        key(0xE3, true, M::COMMAND),
        key(0xE1, true, M::COMMAND | M::SHIFT),
        key(0x04, true, M::COMMAND | M::SHIFT),
        key(0x05, true, M::COMMAND | M::SHIFT),
        button(MouseButton::Right, true, 0.0, 0.0, M::COMMAND | M::SHIFT),
        button(MouseButton::Left, true, 0.0, 0.0, M::COMMAND | M::SHIFT),
    ] {
        r.send(m);
    }
    assert_eq!(
        r.release_all(),
        [
            up(KEY_B),
            up(KEY_A),
            up(KEY_LEFTSHIFT),
            up(KEY_LEFTCTRL),
            InputAction::Button { code: BTN_LEFT, down: false },
            InputAction::Button { code: BTN_RIGHT, down: false },
        ]
    );
    // Later ups of keys that were down are orphans.
    assert_eq!(r.send(key(0x04, false, M::EMPTY)), Outcome::Ignored);
}

// MARK: The backend

/// The way a session uses the router: one buffer, cleared per message, applied when not empty.
#[test]
fn a_session_drives_a_backend() {
    let backend = FakeInput::default();
    let mut router = InputRouter::default();
    let mut out = Vec::with_capacity(64);
    for m in [key(0xE3, true, M::COMMAND), key(0x19, true, M::COMMAND), mv(4.0, 2.0)] {
        out.clear();
        router.handle(&m, &mut out);
        if !out.is_empty() {
            backend.apply(&out);
        }
    }
    out.clear();
    router.release_all(&mut out); // the link ended
    backend.apply(&out);
    assert_eq!(
        backend.actions(),
        [down(KEY_LEFTCTRL), down(KEY_V), InputAction::MoveTo(PointF::new(4.0, 2.0)), up(KEY_V), up(KEY_LEFTCTRL)]
    );
}

/// Modifiers are released in a fixed order (AltGr, Super, Shift, Alt, Ctrl), whatever order they were pressed
/// in: the router keeps a set, not a press order (Swift releases in reverse press order). (Review S5/P5.)
#[test]
fn modifiers_release_in_a_fixed_order() {
    let mut r = Rig::new();
    r.send(key(0xE1, true, M::SHIFT));
    r.send(key(0xE3, true, M::SHIFT | M::COMMAND));
    assert_eq!(r.take(), [down(KEY_LEFTSHIFT), down(KEY_LEFTCTRL)]);
    assert_eq!(r.release_all(), [up(KEY_LEFTSHIFT), up(KEY_LEFTCTRL)]);
}

// MARK: The system key (Right Option)

const RIGHT_OPTION: u16 = 0xE6;

/// Right Option + arrows: the three-finger swipes, as GNOME's shortcuts, each chord alone (no Alt, no stray
/// Super), and the arrow's release sends nothing.
#[test]
fn the_system_key_with_arrows_is_the_three_finger_swipes() {
    let mut r = Rig::new();
    let cases: [(u16, Vec<InputAction>); 4] = [
        (0x52, vec![down(KEY_LEFTMETA), up(KEY_LEFTMETA)]),
        (0x51, vec![down(KEY_LEFTMETA), down(KEY_A), up(KEY_A), up(KEY_LEFTMETA)]),
        (
            0x50,
            vec![
                down(KEY_LEFTCTRL),
                down(KEY_LEFTALT),
                down(KEY_LEFT),
                up(KEY_LEFT),
                up(KEY_LEFTALT),
                up(KEY_LEFTCTRL),
            ],
        ),
        (
            0x4F,
            vec![
                down(KEY_LEFTCTRL),
                down(KEY_LEFTALT),
                down(KEY_RIGHT),
                up(KEY_RIGHT),
                up(KEY_LEFTALT),
                up(KEY_LEFTCTRL),
            ],
        ),
    ];
    for (arrow, want) in cases {
        r.send(key(RIGHT_OPTION, true, M::OPTION));
        r.send(key(arrow, true, M::OPTION));
        r.send(key(arrow, false, M::OPTION));
        r.send(key(RIGHT_OPTION, false, M::EMPTY));
        assert_eq!(r.take(), want, "arrow {arrow:#x}");
    }
}

/// A Right Option tap alone opens the overview; held with a key, it is Command (Ctrl here); Left Option stays
/// Alt, and its arrows are plain arrows.
#[test]
fn the_system_key_taps_and_holds_as_command() {
    let mut r = Rig::new();
    r.send(key(RIGHT_OPTION, true, M::OPTION));
    r.send(key(RIGHT_OPTION, false, M::EMPTY));
    assert_eq!(r.take(), [down(KEY_LEFTMETA), up(KEY_LEFTMETA)]);

    r.send(key(RIGHT_OPTION, true, M::OPTION));
    r.send(key(0x05, true, M::OPTION)); // B
    r.send(key(0x05, false, M::OPTION));
    r.send(key(RIGHT_OPTION, false, M::EMPTY));
    assert_eq!(r.take(), [down(KEY_LEFTCTRL), down(KEY_B), up(KEY_B), up(KEY_LEFTCTRL)], "Cmd+B, no tap");

    r.send(key(0xE2, true, M::OPTION));
    r.send(key(0x50, true, M::OPTION));
    r.send(key(0x50, false, M::OPTION));
    r.send(key(0xE2, false, M::EMPTY));
    assert_eq!(r.take(), [down(KEY_LEFTALT), down(KEY_LEFT), up(KEY_LEFT), up(KEY_LEFTALT)]);
}

/// The client's remapped Spotlight and Hide (Opt-Space, Opt-H arrive as Cmd-Space, Cmd-H): the overview and
/// Super+H.
#[test]
fn spotlight_and_hide_become_the_overview_and_super_h() {
    let mut r = Rig::new();
    for (usage, want) in [
        (0x2C, vec![down(KEY_LEFTCTRL), up(KEY_LEFTCTRL), down(KEY_LEFTMETA), up(KEY_LEFTMETA)]),
        (
            0x0B,
            vec![down(KEY_LEFTCTRL), up(KEY_LEFTCTRL), down(KEY_LEFTMETA), down(KEY_H), up(KEY_H), up(KEY_LEFTMETA)],
        ),
    ] {
        r.send(key(0xE3, true, M::COMMAND));
        r.send(key(usage, true, M::COMMAND));
        r.send(key(usage, false, M::COMMAND));
        r.send(key(0xE3, false, M::EMPTY));
        assert_eq!(r.take(), want, "usage {usage:#x}");
    }
}
