//! The hot path allocates nothing once the caller's buffer has capacity (the brief's acceptance list).
//!
//! A counting global allocator, armed per thread so the test harness's own allocations (on other threads)
//! don't count. `unsafe` is needed only to implement `GlobalAlloc`, by delegating to the system allocator.

#![allow(unsafe_code)]

use lain_input::{InputConfig, InputRouter, ModifierMap, Momentum, ScrollConfig, ZoomAction};
use lain_proto::{
    Gesture, GestureKind, GesturePhase, KeyEvent, Message, ModifierFlags as M, MomentumPhase, MouseButton,
    PointerButton, PointerMove, ReleaseAll, ReleaseReason, Scroll,
};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};

struct Counting;

static ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);

thread_local! {
    static ARMED: Cell<bool> = const { Cell::new(false) };
}

fn note() {
    if ARMED.with(Cell::get) {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
    }
}

// SAFETY: every method forwards to `System` with the caller's arguments, so `System`'s guarantees hold.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        note();
        unsafe { System.alloc(layout) }
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        note();
        unsafe { System.alloc_zeroed(layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        note();
        unsafe { System.realloc(ptr, layout, new_size) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

/// Counts the allocations `f` makes on this thread.
fn allocations(f: impl FnOnce()) -> usize {
    let before = ALLOCATIONS.load(Ordering::Relaxed);
    ARMED.with(|a| a.set(true));
    f();
    ARMED.with(|a| a.set(false));
    ALLOCATIONS.load(Ordering::Relaxed) - before
}

fn key(usage: u16, is_down: bool, is_repeat: bool, modifiers: M) -> Message {
    Message::KeyEvent(KeyEvent { usage_page: 0x07, usage, is_down, is_repeat, modifiers })
}

fn scroll(dy: f32, phase: GesturePhase, momentum_phase: MomentumPhase) -> Message {
    Message::Scroll(Scroll { dx: 0.5, dy, phase, momentum_phase })
}

/// Every kind of message, including the ones that log once (an unknown key, a rotate) and the ones that
/// fill the held-key set.
fn session() -> Vec<Message> {
    let mut messages = vec![
        key(0xA5, true, false, M::EMPTY), // unknown: logged once
        Message::Gesture(Gesture { kind: GestureKind::Rotate, phase: GesturePhase::Changed, value: 0.3 }),
        key(0xE3, true, false, M::COMMAND),
        key(0xE1, true, false, M::COMMAND | M::SHIFT),
        key(0x04, true, false, M::COMMAND | M::SHIFT),
        key(0x04, true, true, M::COMMAND | M::SHIFT),
        key(0x04, false, false, M::COMMAND | M::SHIFT),
        key(0xE1, false, false, M::COMMAND),
        key(0xE3, false, false, M::EMPTY),
        Message::PointerMove(PointerMove { x: 100.0, y: 50.0, dx: 1.0, dy: 0.0, buttons: 0 }),
        Message::PointerButton(PointerButton {
            button: MouseButton::Left,
            is_down: true,
            click_count: 1,
            x: 101.0,
            y: 50.0,
            modifiers: M::OPTION,
        }),
        Message::PointerMove(PointerMove { x: 140.0, y: 60.0, dx: 1.0, dy: 0.0, buttons: 1 }),
        Message::PointerButton(PointerButton {
            button: MouseButton::Left,
            is_down: false,
            click_count: 1,
            x: 140.0,
            y: 60.0,
            modifiers: M::EMPTY,
        }),
        scroll(4.0, GesturePhase::Began, MomentumPhase::None),
        scroll(6.0, GesturePhase::Changed, MomentumPhase::None),
        scroll(0.0, GesturePhase::Ended, MomentumPhase::None),
        scroll(20.0, GesturePhase::None, MomentumPhase::Began),
        scroll(10.0, GesturePhase::None, MomentumPhase::Changed),
        scroll(0.0, GesturePhase::None, MomentumPhase::Ended),
        scroll(-10.0, GesturePhase::None, MomentumPhase::None),
        Message::Gesture(Gesture { kind: GestureKind::Magnify, phase: GesturePhase::Changed, value: 0.3 }),
        Message::Gesture(Gesture { kind: GestureKind::Magnify, phase: GesturePhase::Changed, value: -0.6 }),
        Message::Gesture(Gesture { kind: GestureKind::Magnify, phase: GesturePhase::Ended, value: 0.0 }),
    ];
    // Hold every key the table knows, then let release-all lift them.
    messages.extend((0..=0xFFu16).filter(|u| !(0xE0..=0xE7).contains(u)).map(|u| key(u, true, false, M::EMPTY)));
    messages.push(Message::ReleaseAll(ReleaseAll { reason: ReleaseReason::FocusLost }));
    messages
}

#[test]
fn handling_input_allocates_nothing() {
    let messages = session();
    for zoom in [ZoomAction::CtrlWheel, ZoomAction::CtrlKeys] {
        for momentum in [Momentum::Desktop, Momentum::Client] {
            let config = InputConfig {
                zoom,
                scroll: ScrollConfig { momentum, ..ScrollConfig::default() },
                ..InputConfig::default()
            };
            let mut router = InputRouter::new(config);
            let mut out = Vec::with_capacity(512);
            let count = allocations(|| {
                for _ in 0..3 {
                    for m in &messages {
                        out.clear();
                        router.handle(m, &mut out);
                    }
                    out.clear();
                    router.set_modifier_map(ModifierMap { command: None, ..ModifierMap::default() }, &mut out);
                    out.clear();
                    router.set_modifier_map(ModifierMap::default(), &mut out);
                    out.clear();
                    router.release_all(&mut out);
                }
            });
            assert_eq!(count, 0, "{zoom:?}, {momentum:?}");
        }
    }
}

/// The counter works: a fresh vector does allocate.
#[test]
fn the_counter_counts() {
    assert!(allocations(|| drop(std::hint::black_box(Vec::<u8>::with_capacity(8)))) > 0);
}
