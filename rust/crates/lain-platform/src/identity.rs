//! Who this host is (Swift: `HostIdentity`).

/// The host's id goes in `Pair`, in `HelloAck` and in the Bonjour TXT `id`; its name in `HelloAck` and as
/// the Bonjour instance name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostIdentity {
    /// A canonical UUID, uppercase and hyphenated (`UUID().uuidString` in Swift), created once and kept.
    pub id: String,
    /// The computer's name, for the client's status.
    pub name: String,
}
