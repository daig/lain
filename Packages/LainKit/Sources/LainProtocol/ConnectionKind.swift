/// The three connections of a session (§7.1); carried in `ChannelHello`.
public enum ConnectionKind: UInt8, Sendable, CaseIterable {
    /// control + input + cursor
    case realtime = 0
    /// video + frame acks
    case video = 1
    case audio = 2
}
