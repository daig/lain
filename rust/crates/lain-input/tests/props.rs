//! Property tests over random input sequences: wave 2's state review wrote them against the first router
//! (they found four of its defects); the lead ported them to the fixed router and its intended behaviour.
//!
//! Over random configurations and up to 30 random messages, map changes, release-alls and waits (on a synthetic
//! clock, with `handle_at` and `poll`), after every step:
//! - the desktop never sees a double press or an orphan release;
//! - its modifier keys are the client's flags under the map, Command holding a command shortcut's modifier
//!   while one is active (a reference model below);
//! - its regular keys, buttons and open scroll sequence are the router's own;
//! - a stop only closes an open sequence, in the phased source;
//! - the client's momentum reaches the desktop only in client mode, and never after a stop;
//! - in client mode no stop comes within GTK's 150 ms velocity window of a delta, except right before a wheel
//!   notch and at release-all (documented on `Momentum::Client`);
//! - a button change with a finite position moves there first;
//! - no wheel event from a client scroll lands inside an open finger sequence (a zoom step may: review S4);
//! - system keys reach the desktop only when allowed;
//!
//! and a final `release_all` leaves nothing held.

use std::collections::BTreeSet;

use lain_input::evdev::*;
use lain_input::keymap::SYSTEM_KEYS;
use lain_input::{
    CommandShortcut, InputConfig, InputRouter, LinuxModifier, ModifierMap, Momentum, ScrollConfig, ZoomAction,
};
use lain_platform::{InputAction, PointF, ScrollSource};
use lain_proto::{
    Gesture, GestureKind, GesturePhase, KeyEvent, KeyboardType, Message, ModifierFlags as M, MomentumPhase,
    MouseButton, PointerButton, PointerMove, ReleaseAll, ReleaseReason, Scroll,
};
use proptest::prelude::*;

#[derive(Debug, Clone)]
enum Op {
    Msg(Message),
    SetMap(ModifierMap),
    ReleaseAll,
    /// Time passes (milliseconds) and the owner polls, as lain-host's 60 Hz sampler does.
    Wait(u64),
}

const MOD_KEYS: [u16; 5] = [KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_LEFTALT, KEY_LEFTMETA, KEY_RIGHTALT];
const KEYBOARD_PAGE: u16 = 7;
/// GTK 4's scroll velocity window (`SCROLL_CAPTURE_THRESHOLD_MS`).
const VELOCITY_WINDOW_NS: u64 = 150_000_000;

fn lm() -> impl Strategy<Value = Option<LinuxModifier>> {
    prop_oneof![
        Just(None),
        Just(Some(LinuxModifier::Shift)),
        Just(Some(LinuxModifier::Control)),
        Just(Some(LinuxModifier::Alt)),
        Just(Some(LinuxModifier::Super)),
        Just(Some(LinuxModifier::AltGr)),
    ]
}

fn map() -> impl Strategy<Value = ModifierMap> {
    (lm(), lm(), lm(), lm(), lm()).prop_map(|(shift, control, option, command, function)| ModifierMap {
        shift,
        control,
        option,
        command,
        function,
    })
}

fn flags() -> impl Strategy<Value = M> {
    (0u32..64).prop_map(M)
}

fn gphase() -> impl Strategy<Value = GesturePhase> {
    prop_oneof![
        Just(GesturePhase::None),
        Just(GesturePhase::MayBegin),
        Just(GesturePhase::Began),
        Just(GesturePhase::Changed),
        Just(GesturePhase::Ended),
        Just(GesturePhase::Cancelled),
    ]
}

fn mphase() -> impl Strategy<Value = MomentumPhase> {
    prop_oneof![
        Just(MomentumPhase::None),
        Just(MomentumPhase::Began),
        Just(MomentumPhase::Changed),
        Just(MomentumPhase::Ended),
    ]
}

fn delta() -> impl Strategy<Value = f32> {
    prop_oneof![Just(0.0f32), Just(3.0), Just(-7.5), Just(f32::NAN)]
}

fn key_msg() -> impl Strategy<Value = Message> {
    let usage = prop_oneof![
        Just((KEYBOARD_PAGE, 0x04u16)), // a
        Just((KEYBOARD_PAGE, 0x05)),    // b
        Just((KEYBOARD_PAGE, 0x2B)),    // Tab (a command shortcut)
        Just((KEYBOARD_PAGE, 0x2E)),    // = (CtrlKeys' zoom in)
        Just((KEYBOARD_PAGE, 0x2D)),    // - (CtrlKeys' zoom out)
        Just((KEYBOARD_PAGE, 0x35)),    // ` (a command shortcut, ISO-swapped)
        Just((KEYBOARD_PAGE, 0x64)),    // non-US \ (ISO-swapped)
        Just((KEYBOARD_PAGE, 0x39)),    // Caps Lock
        Just((KEYBOARD_PAGE, 0x01)),    // no Linux code
        Just((KEYBOARD_PAGE, 0x66)),    // Power (a system key)
        Just((KEYBOARD_PAGE, 0xF8)),    // Sleep (a system key)
        Just((KEYBOARD_PAGE, 0xE0)),
        Just((KEYBOARD_PAGE, 0xE1)),
        Just((KEYBOARD_PAGE, 0xE2)),
        Just((KEYBOARD_PAGE, 0xE3)),
        Just((KEYBOARD_PAGE, 0xE4)),
        Just((KEYBOARD_PAGE, 0xE6)),
        Just((KEYBOARD_PAGE, 0xE7)),
        Just((0x0C, 0x29D)), // Globe
        Just((0xFF, 0x03)),  // Apple fn
        Just((0x0C, 0xE9)),  // another page
    ];
    (usage, any::<bool>(), prop::bool::weighted(0.15), flags()).prop_map(
        |((usage_page, usage), is_down, is_repeat, modifiers)| {
            Message::KeyEvent(KeyEvent { usage_page, usage, is_down, is_repeat, modifiers })
        },
    )
}

fn msg() -> impl Strategy<Value = Message> {
    let button = (0u8..3, any::<bool>(), 0u8..3, flags()).prop_map(|(b, is_down, p, modifiers)| {
        let button = [MouseButton::Left, MouseButton::Right, MouseButton::Other][b as usize];
        let (x, y) = [(1.0, 1.0), (5.0, 2.0), (f64::NAN, 0.0)][p as usize];
        Message::PointerButton(PointerButton { button, is_down, click_count: 1, x, y, modifiers })
    });
    let mv = (0u8..3).prop_map(|p| {
        let (x, y) = [(1.0, 1.0), (5.0, 2.0), (f64::INFINITY, 0.0)][p as usize];
        Message::PointerMove(PointerMove { x, y, dx: 1.0, dy: 1.0, buttons: 0 })
    });
    let scroll = (delta(), delta(), gphase(), mphase())
        .prop_map(|(dx, dy, phase, momentum_phase)| Message::Scroll(Scroll { dx, dy, phase, momentum_phase }));
    let gesture = (any::<bool>(), gphase(), prop_oneof![Just(0.0f32), Just(0.3), Just(-0.3), Just(1.5), Just(-0.9)])
        .prop_map(|(rot, phase, value)| {
            Message::Gesture(Gesture {
                kind: if rot { GestureKind::Rotate } else { GestureKind::Magnify },
                phase,
                value,
            })
        });
    prop_oneof![
        4 => key_msg(),
        2 => button,
        1 => mv,
        4 => scroll,
        2 => gesture,
        1 => Just(Message::ReleaseAll(ReleaseAll { reason: ReleaseReason::Disconnect })),
    ]
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        12 => msg().prop_map(Op::Msg),
        1 => map().prop_map(Op::SetMap),
        1 => Just(Op::ReleaseAll),
        2 => prop_oneof![Just(16u64), Just(100), Just(250)].prop_map(Op::Wait),
    ]
}

fn config() -> impl Strategy<Value = (InputConfig, KeyboardType)> {
    (
        map(),
        any::<bool>(),
        prop_oneof![Just(ScrollSource::Finger), Just(ScrollSource::Continuous), Just(ScrollSource::Wheel)],
        any::<bool>(),
        any::<bool>(),
        any::<bool>(),
        any::<bool>(),
        any::<bool>(),
    )
        .prop_map(|(modifiers, client, phased_source, keys, swap, iso, shortcuts, system)| {
            (
                InputConfig {
                    modifiers,
                    scroll: ScrollConfig {
                        momentum: if client { Momentum::Client } else { Momentum::Desktop },
                        phased_source,
                        ..ScrollConfig::default()
                    },
                    zoom: if keys { ZoomAction::CtrlKeys } else { ZoomAction::CtrlWheel },
                    swap_iso_keys: swap,
                    command_shortcuts: if shortcuts { CommandShortcut::DEFAULTS } else { &[] },
                    allow_system_keys: system,
                    // The system key (Right Option) is covered by tests/router.rs; this model predates it.
                    system_key: false,
                    ..InputConfig::default()
                },
                if iso { KeyboardType::Iso } else { KeyboardType::Ansi },
            )
        })
}

/// What the desktop holds, built only from the actions it was sent.
#[derive(Default, Debug)]
struct Desktop {
    keys: BTreeSet<u16>,
    buttons: BTreeSet<u16>,
    open: bool,
    /// When the open sequence last carried a delta (synthetic ns).
    last_delta_ns: Option<u64>,
}

impl Desktop {
    fn apply(&mut self, phased: ScrollSource, now_ns: u64, actions: &[InputAction]) -> Result<(), String> {
        for a in actions {
            match *a {
                InputAction::Key { code, down } => {
                    let ok = if down { self.keys.insert(code) } else { self.keys.remove(&code) };
                    if !ok {
                        return Err(format!("key {a:?} in {actions:?} (held {:?})", self.keys));
                    }
                }
                InputAction::Button { code, down } => {
                    let ok = if down { self.buttons.insert(code) } else { self.buttons.remove(&code) };
                    if !ok {
                        return Err(format!("button {a:?} in {actions:?}"));
                    }
                }
                InputAction::Scroll { dx, dy, source } => {
                    if !(dx.is_finite() && dy.is_finite()) {
                        return Err(format!("non-finite scroll {a:?}"));
                    }
                    if source == phased && source != ScrollSource::Wheel {
                        self.open = true;
                        if dx != 0.0 || dy != 0.0 {
                            self.last_delta_ns = Some(now_ns);
                        }
                    }
                }
                InputAction::ScrollStop { source } => {
                    if source != phased {
                        return Err(format!("stop with source {source:?}, phased {phased:?}"));
                    }
                    if phased != ScrollSource::Wheel && !self.open {
                        return Err(format!("stop with nothing open: {actions:?}"));
                    }
                    self.open = false;
                }
                InputAction::MoveTo(p) => {
                    if !(p.x.is_finite() && p.y.is_finite()) {
                        return Err("non-finite move".into());
                    }
                }
            }
        }
        Ok(())
    }
}

/// The router's command-shortcut rule, modelled from the client's messages alone: a keyboard-page key pressed
/// with Command held that is a shortcut makes Command hold the shortcut's modifier, until flags without
/// Command arrive (a key or a button) or everything is released.
#[derive(Default, Debug)]
struct ShortcutModel {
    hold: Option<LinuxModifier>,
}

impl ShortcutModel {
    fn on(&mut self, cfg: &InputConfig, op: &Op) {
        match op {
            Op::Msg(Message::KeyEvent(e)) if !e.is_repeat => {
                if e.is_down
                    && e.usage_page == KEYBOARD_PAGE
                    && e.modifiers.contains(M::COMMAND)
                    && let Some(s) = cfg.command_shortcuts.iter().find(|s| s.usage == e.usage)
                {
                    self.hold = Some(s.hold);
                }
                if !e.modifiers.contains(M::COMMAND) {
                    self.hold = None;
                }
            }
            Op::Msg(Message::PointerButton(b)) if !b.modifiers.contains(M::COMMAND) => self.hold = None,
            Op::Msg(Message::ReleaseAll(_)) | Op::ReleaseAll => self.hold = None,
            _ => {}
        }
    }

    fn map(&self, mut map: ModifierMap) -> ModifierMap {
        if let Some(hold) = self.hold {
            map.command = Some(hold);
        }
        map
    }
}

fn run(cfg: InputConfig, kt: KeyboardType, ops: &[Op]) -> Result<(), TestCaseError> {
    let mut r = InputRouter::new(cfg);
    r.set_keyboard_type(kt);
    let mut cfg = cfg;
    let phased = cfg.scroll.phased_source;
    let client_momentum = cfg.scroll.momentum == Momentum::Client;
    let mut d = Desktop::default();
    let mut model = ShortcutModel::default();
    let mut out = Vec::new();
    let mut flung = false;
    let mut now: u64 = 1_000_000_000;
    for (i, op) in ops.iter().enumerate() {
        out.clear();
        now += 1_000_000; // every step takes a millisecond
        match op {
            Op::Msg(m) => {
                r.handle_at(m, now, &mut out);
            }
            Op::SetMap(m) => {
                cfg.modifiers = *m;
                r.set_modifier_map(*m, &mut out);
            }
            Op::ReleaseAll => r.release_all(&mut out),
            Op::Wait(ms) => {
                now += ms * 1_000_000;
                r.poll(now, &mut out);
            }
        }
        model.on(&cfg, op);
        let ctx = || format!("step {i}: {op:?}\nactions {out:?}\nops {ops:?}");

        // Client mode: no stop inside GTK's velocity window, except before a wheel notch and at release-all.
        let releases = matches!(op, Op::ReleaseAll | Op::Msg(Message::ReleaseAll(_)));
        let wheel_notch = matches!(op, Op::Msg(Message::Scroll(s))
            if s.phase == GesturePhase::None && s.momentum_phase == MomentumPhase::None);
        if client_momentum && phased != ScrollSource::Wheel && !releases && !wheel_notch {
            let mut last = d.last_delta_ns;
            for a in &out {
                match *a {
                    InputAction::Scroll { dx, dy, source } if source == phased && (dx != 0.0 || dy != 0.0) => {
                        last = Some(now);
                    }
                    InputAction::ScrollStop { .. } => {
                        if let Some(last) = last {
                            let gap = now - last;
                            prop_assert!(
                                gap >= VELOCITY_WINDOW_NS,
                                "a stop {} ms after a delta {}",
                                gap / 1_000_000,
                                ctx()
                            );
                        }
                    }
                    _ => {}
                }
            }
        }
        // A button change with a finite position moves there first.
        if let Op::Msg(Message::PointerButton(b)) = op
            && b.x.is_finite()
            && b.y.is_finite()
            && let Some(at) = out.iter().position(|a| matches!(a, InputAction::Button { .. }))
        {
            prop_assert!(
                at > 0 && out[at - 1] == InputAction::MoveTo(PointF::new(b.x, b.y)),
                "click without a move {}",
                ctx()
            );
        }
        // No client wheel scroll inside an open finger sequence: the router ends the sequence first.
        if wheel_notch && d.open {
            let first_wheel =
                out.iter().position(|a| matches!(a, InputAction::Scroll { source: ScrollSource::Wheel, .. }));
            let stop = out.iter().position(|a| matches!(a, InputAction::ScrollStop { .. }));
            if let Some(w) = first_wheel {
                prop_assert!(stop.is_some_and(|s| s < w), "a wheel notch inside an open sequence {}", ctx());
            }
        }
        // System keys only when allowed.
        if !cfg.allow_system_keys {
            prop_assert!(
                !out.iter().any(|a| matches!(a, InputAction::Key { code, .. } if SYSTEM_KEYS.contains(code))),
                "a system key {}",
                ctx()
            );
        }

        d.apply(phased, now, &out).map_err(|e| TestCaseError::fail(format!("{e}\n{}", ctx())))?;

        // Modifiers: what the desktop holds is the client's flags under the map (and an active shortcut).
        let want: BTreeSet<u16> = model.map(cfg.modifiers).apply(r.modifiers()).iter().map(|m| m.key()).collect();
        let have: BTreeSet<u16> = d.keys.iter().copied().filter(|k| MOD_KEYS.contains(k)).collect();
        prop_assert_eq!(&have, &want, "modifiers {}", ctx());
        let held: BTreeSet<u16> = r.held_modifiers().iter().map(|m| m.key()).collect();
        prop_assert_eq!(&held, &want, "router held {}", ctx());
        if let Op::Msg(Message::KeyEvent(e)) = op
            && !e.is_repeat
        {
            prop_assert_eq!(r.modifiers(), e.modifiers, "{}", ctx());
        }
        if let Op::Msg(Message::PointerButton(b)) = op {
            prop_assert_eq!(r.modifiers(), b.modifiers, "{}", ctx());
        }
        // Regular keys and buttons.
        let regular: BTreeSet<u16> = d.keys.iter().copied().filter(|k| !MOD_KEYS.contains(k)).collect();
        let router_regular: BTreeSet<u16> = r.held_keys().iter().copied().collect();
        prop_assert_eq!(&regular, &router_regular, "regular {}", ctx());
        prop_assert_eq!(d.buttons.len() as u32, r.held_buttons().count_ones(), "buttons {}", ctx());
        // The open sequence.
        if phased != ScrollSource::Wheel {
            prop_assert_eq!(d.open, r.scroll_open(), "scroll open {}", ctx());
        }
        // The client's momentum: only in client mode, never after a stop. The actions are walked in order: one
        // message may end a sequence (a held-back stop come due) and then start a new one, which momentum then
        // continues (an `Ended` with a delta after the stop: proptest's case of 2026-11-01).
        let scroll = if let Op::Msg(Message::Scroll(s)) = op { Some(s) } else { None };
        let is_momentum =
            scroll.is_some_and(|s| s.phase == GesturePhase::None && s.momentum_phase != MomentumPhase::None);
        let is_phase = scroll
            .is_some_and(|s| matches!(s.phase, GesturePhase::Began | GesturePhase::Changed | GesturePhase::Ended));
        for a in &out {
            match a {
                InputAction::ScrollStop { .. } => flung = true,
                InputAction::Scroll { source, .. } if is_momentum && *source != ScrollSource::Wheel => {
                    prop_assert!(client_momentum, "momentum in desktop mode {}", ctx());
                    prop_assert!(!flung, "momentum after a stop {}", ctx());
                }
                InputAction::Scroll { source, .. }
                    if is_phase && (*source != ScrollSource::Wheel || phased == ScrollSource::Wheel) =>
                {
                    flung = false;
                }
                _ => {}
            }
        }
    }
    out.clear();
    r.release_all(&mut out);
    d.apply(phased, now, &out).map_err(|e| TestCaseError::fail(format!("final release: {e}\nops {ops:?}")))?;
    prop_assert!(d.keys.is_empty() && d.buttons.is_empty() && !d.open, "not idle {:?} ops {:?}", d, ops);
    prop_assert!(!r.is_holding());
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 4000, max_shrink_iters: 20000, .. ProptestConfig::default() })]

    #[test]
    fn invariants_hold_over_random_sequences((cfg, kt) in config(), ops in prop::collection::vec(op(), 1..30)) {
        run(cfg, kt, &ops)?;
    }
}
