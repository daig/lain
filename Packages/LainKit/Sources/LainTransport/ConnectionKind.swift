/// The three connections of a session (§7.1). Transport/Connection API arrives in M1 (step 5).
public enum ConnectionKind: UInt8, Sendable, CaseIterable {
    case realtime = 0
    case video = 1
    case audio = 2
}
