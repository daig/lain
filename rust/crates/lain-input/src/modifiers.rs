//! Which desktop modifier each of the client's Mac modifiers holds, and the set of modifier keys held.
//!
//! No single Swift counterpart. On the Mac the client's modifier keys are posted as themselves and every
//! event carries `CGEventFlags` (`InputInjector.cgFlags`); Linux events carry no flags, so the modifier keys
//! the desktop sees held are what decides, and `lain-input` presses and releases them explicitly.

use crate::evdev::{KEY_LEFTALT, KEY_LEFTCTRL, KEY_LEFTMETA, KEY_LEFTSHIFT, KEY_RIGHTALT};
use lain_proto::ModifierFlags;

/// A desktop modifier, held with one evdev key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LinuxModifier {
    /// `KEY_LEFTSHIFT`.
    Shift,
    /// `KEY_LEFTCTRL`.
    Control,
    /// `KEY_LEFTALT`.
    Alt,
    /// `KEY_LEFTMETA` (GNOME's Super).
    Super,
    /// `KEY_RIGHTALT`, which most European XKB layouts make AltGr (level 3).
    AltGr,
}

impl LinuxModifier {
    /// Every modifier, in the order they are pressed (the order of Swift's `PhysicalKey.keys(for:)`:
    /// control, option, shift, command, then the rest). Releases go in reverse.
    pub const ALL: [LinuxModifier; 5] =
        [LinuxModifier::Control, LinuxModifier::Alt, LinuxModifier::Shift, LinuxModifier::Super, LinuxModifier::AltGr];

    /// The evdev key that holds this modifier.
    pub const fn key(self) -> u16 {
        match self {
            LinuxModifier::Shift => KEY_LEFTSHIFT,
            LinuxModifier::Control => KEY_LEFTCTRL,
            LinuxModifier::Alt => KEY_LEFTALT,
            LinuxModifier::Super => KEY_LEFTMETA,
            LinuxModifier::AltGr => KEY_RIGHTALT,
        }
    }

    const fn bit(self) -> u8 {
        1 << self as u8
    }
}

/// Which desktop modifier each client modifier holds (`None`: nothing). The client's left and right
/// modifier keys both hold the one key mapped here.
///
/// Caps Lock isn't here: it is a toggle, sent to the desktop as the Caps Lock key itself (as Swift's
/// `InputInjector` posts `kVK_CapsLock`), and the client's `CAPS_LOCK` flag is ignored.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ModifierMap {
    pub shift: Option<LinuxModifier>,
    pub control: Option<LinuxModifier>,
    pub option: Option<LinuxModifier>,
    pub command: Option<LinuxModifier>,
    pub function: Option<LinuxModifier>,
}

impl Default for ModifierMap {
    /// Command → Ctrl (Linux's shortcuts are where the Mac's are, on Ctrl), Option → Alt, Control → Ctrl,
    /// Shift → Shift, Function → nothing.
    fn default() -> Self {
        Self {
            shift: Some(LinuxModifier::Shift),
            control: Some(LinuxModifier::Control),
            option: Some(LinuxModifier::Alt),
            command: Some(LinuxModifier::Control),
            function: None,
        }
    }
}

impl ModifierMap {
    /// The desktop modifiers `flags` hold under this map.
    pub fn apply(&self, flags: ModifierFlags) -> ModifierSet {
        let mut set = ModifierSet::EMPTY;
        let pairs = [
            (ModifierFlags::SHIFT, self.shift),
            (ModifierFlags::CONTROL, self.control),
            (ModifierFlags::OPTION, self.option),
            (ModifierFlags::COMMAND, self.command),
            (ModifierFlags::FUNCTION, self.function),
        ];
        for (flag, target) in pairs {
            if let (true, Some(m)) = (flags.contains(flag), target) {
                set.insert(m);
            }
        }
        set
    }
}

/// A set of [`LinuxModifier`]s.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct ModifierSet(u8);

impl ModifierSet {
    pub const EMPTY: Self = Self(0);

    pub fn contains(self, m: LinuxModifier) -> bool {
        self.0 & m.bit() != 0
    }

    pub fn insert(&mut self, m: LinuxModifier) {
        self.0 |= m.bit();
    }

    pub fn remove(&mut self, m: LinuxModifier) {
        self.0 &= !m.bit();
    }

    pub fn is_empty(self) -> bool {
        self.0 == 0
    }

    /// The members in press order ([`LinuxModifier::ALL`]).
    pub fn iter(self) -> impl DoubleEndedIterator<Item = LinuxModifier> {
        LinuxModifier::ALL.into_iter().filter(move |&m| self.contains(m))
    }
}

impl FromIterator<LinuxModifier> for ModifierSet {
    fn from_iter<I: IntoIterator<Item = LinuxModifier>>(iter: I) -> Self {
        let mut set = Self::EMPTY;
        for m in iter {
            set.insert(m);
        }
        set
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use LinuxModifier::*;

    #[test]
    fn the_default_map() {
        let map = ModifierMap::default();
        assert_eq!(map.apply(ModifierFlags::EMPTY), ModifierSet::EMPTY);
        assert_eq!(map.apply(ModifierFlags::COMMAND), [Control].into_iter().collect());
        assert_eq!(map.apply(ModifierFlags::CONTROL), [Control].into_iter().collect());
        assert_eq!(map.apply(ModifierFlags::OPTION), [Alt].into_iter().collect());
        assert_eq!(map.apply(ModifierFlags::SHIFT), [Shift].into_iter().collect());
        assert_eq!(map.apply(ModifierFlags::FUNCTION), ModifierSet::EMPTY);
        assert_eq!(map.apply(ModifierFlags::CAPS_LOCK), ModifierSet::EMPTY, "Caps Lock is a toggle");
        assert_eq!(
            map.apply(ModifierFlags::COMMAND | ModifierFlags::CONTROL | ModifierFlags::SHIFT),
            [Control, Shift].into_iter().collect()
        );
    }

    #[test]
    fn keys() {
        assert_eq!(Shift.key(), 42);
        assert_eq!(Control.key(), 29);
        assert_eq!(Alt.key(), 56);
        assert_eq!(Super.key(), 125);
        assert_eq!(AltGr.key(), 100);
    }

    #[test]
    fn iteration_is_in_press_order() {
        let set: ModifierSet = [Super, Shift, Control].into_iter().collect();
        assert_eq!(set.iter().collect::<Vec<_>>(), [Control, Shift, Super]);
        assert_eq!(set.iter().rev().collect::<Vec<_>>(), [Super, Shift, Control]);
    }
}
