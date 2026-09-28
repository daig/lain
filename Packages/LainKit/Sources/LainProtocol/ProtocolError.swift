public enum ProtocolError: Error, Equatable, Sendable {
    /// Not enough bytes for the header or the declared field.
    case truncated
    case badMagic(UInt16)
    /// The peer speaks another major version; end the session with `Error` (§7.5).
    case versionMismatch(remote: UInt8)
    case unknownType(UInt8)
    case reservedNonZero
    case payloadTooLarge(UInt32)
    case malformed(String)
}
