//! Declarations of the wire's enums (Swift `enum X: UInt8`) and option sets (Swift `OptionSet`).

/// A `u8`-valued enum whose raw value must be known when read (Swift: `ByteReader.enumValue`). The literal
/// after the name is the Swift type's name, used in the `Malformed` text as Swift does.
macro_rules! wire_enum {
    (
        $(#[$meta:meta])*
        $vis:vis enum $name:ident: $swift:literal {
            $($(#[$vmeta:meta])* $variant:ident = $value:literal),+ $(,)?
        }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        #[repr(u8)]
        $vis enum $name {
            $($(#[$vmeta])* $variant = $value),+
        }

        impl $name {
            /// Every case, in declaration order (Swift: `allCases`).
            pub const ALL: &'static [Self] = &[$(Self::$variant),+];

            /// The wire value (Swift: `rawValue`).
            pub const fn raw(self) -> u8 {
                self as u8
            }

            /// The case with this wire value, if there is one (Swift: `init(rawValue:)`).
            pub const fn from_raw(raw: u8) -> Option<Self> {
                match raw {
                    $($value => Some(Self::$variant),)+
                    _ => None,
                }
            }
        }

        impl $crate::io::WireEnum for $name {
            const SWIFT_NAME: &'static str = $swift;
            fn raw(self) -> u8 {
                self as u8
            }
            fn from_raw(raw: u8) -> Option<Self> {
                Self::from_raw(raw)
            }
        }
    };
}

/// A bit set carried as its raw integer; unknown bits are kept (Swift `OptionSet` with `init(rawValue:)`).
macro_rules! wire_flags {
    (
        $(#[$meta:meta])*
        $vis:vis struct $name:ident($ty:ty) {
            $($(#[$cmeta:meta])* const $flag:ident = $value:expr;)+
        }
    ) => {
        $(#[$meta])*
        #[derive(Clone, Copy, PartialEq, Eq, Hash, Default)]
        $vis struct $name(pub $ty);

        impl $name {
            /// No bits set (Swift: `[]`).
            pub const EMPTY: Self = Self(0);
            $($(#[$cmeta])* pub const $flag: Self = Self($value);)+
            const NAMED: &'static [(&'static str, Self)] = &[$((stringify!($flag), Self::$flag)),+];

            /// The raw value (Swift: `rawValue`).
            pub const fn bits(self) -> $ty {
                self.0
            }
            pub const fn contains(self, other: Self) -> bool {
                self.0 & other.0 == other.0
            }
            pub const fn intersects(self, other: Self) -> bool {
                self.0 & other.0 != 0
            }
            pub const fn is_empty(self) -> bool {
                self.0 == 0
            }
            pub const fn union(self, other: Self) -> Self {
                Self(self.0 | other.0)
            }
            pub fn insert(&mut self, other: Self) {
                self.0 |= other.0;
            }
            pub fn remove(&mut self, other: Self) {
                self.0 &= !other.0;
            }
        }

        impl std::ops::BitOr for $name {
            type Output = Self;
            fn bitor(self, rhs: Self) -> Self {
                Self(self.0 | rhs.0)
            }
        }

        impl std::ops::BitOrAssign for $name {
            fn bitor_assign(&mut self, rhs: Self) {
                self.0 |= rhs.0;
            }
        }

        impl std::ops::BitAnd for $name {
            type Output = Self;
            fn bitand(self, rhs: Self) -> Self {
                Self(self.0 & rhs.0)
            }
        }

        impl std::ops::Sub for $name {
            type Output = Self;
            fn sub(self, rhs: Self) -> Self {
                Self(self.0 & !rhs.0)
            }
        }

        impl std::fmt::Debug for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                let mut rest = self.0;
                let mut list = f.debug_set();
                for (name, flag) in Self::NAMED {
                    if self.contains(*flag) && !flag.is_empty() {
                        list.entry(&format_args!("{name}"));
                        rest &= !flag.0;
                    }
                }
                if rest != 0 {
                    list.entry(&format_args!("{rest:#x}"));
                }
                list.finish()
            }
        }
    };
}
