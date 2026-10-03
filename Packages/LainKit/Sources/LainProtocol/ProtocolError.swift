public enum ProtocolError: Error, Equatable, Sendable {
    /// Not enough bytes for the header or the declared field.
    case truncated
    case badMagic(UInt16)
    /// A header version that is neither the handshake's nor one this build implements: a legacy peer
    /// (before negotiation) or garbage.
    case versionMismatch(remote: UInt8)
    case unknownType(UInt8)
    case reservedNonZero
    case payloadTooLarge(UInt32)
    case malformed(String)
}
