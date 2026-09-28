/// Explicit little-endian binary encoding for headers and payloads (§7.4: not Codable).

public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 64) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    @inline(__always) public mutating func u8(_ v: UInt8) { bytes.append(v) }
    @inline(__always) public mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    @inline(__always) public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    @inline(__always) public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    @inline(__always) public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    @inline(__always) public mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    @inline(__always) public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    @inline(__always) public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    /// Raw bytes with no length prefix (fixed-size fields).
    public mutating func raw(_ v: some Collection<UInt8>) { bytes.append(contentsOf: v) }
    /// u32 length prefix + bytes.
    public mutating func blob(_ v: [UInt8]) { u32(UInt32(v.count)); bytes.append(contentsOf: v) }
    /// u16 length prefix + UTF-8.
    public mutating func string(_ v: String) {
        let utf8 = Array(v.utf8.prefix(Int(UInt16.max)))
        u16(UInt16(utf8.count)); bytes.append(contentsOf: utf8)
    }
}

public struct ByteReader {
    private let bytes: ArraySlice<UInt8>
    private var index: Int

    public init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        index = bytes.startIndex
    }

    public init(_ bytes: [UInt8]) { self.init(bytes[...]) }

    public var remaining: Int { bytes.endIndex - index }

    private mutating func take(_ n: Int) throws(ProtocolError) -> ArraySlice<UInt8> {
        guard n >= 0, remaining >= n else { throw .truncated }
        defer { index += n }
        return bytes[index..<index + n]
    }

    private mutating func le<T: FixedWidthInteger>(_: T.Type) throws(ProtocolError) -> T {
        let s = try take(MemoryLayout<T>.size)
        var v: T = 0
        for (i, b) in s.enumerated() { v |= T(b) << (8 * i) }
        return v
    }

    public mutating func u8() throws(ProtocolError) -> UInt8 { try take(1).first! }
    public mutating func bool() throws(ProtocolError) -> Bool {
        switch try u8() {
        case 0: false
        case 1: true
        default: throw .malformed("bool")
        }
    }
    public mutating func u16() throws(ProtocolError) -> UInt16 { try le(UInt16.self) }
    public mutating func u32() throws(ProtocolError) -> UInt32 { try le(UInt32.self) }
    public mutating func u64() throws(ProtocolError) -> UInt64 { try le(UInt64.self) }
    public mutating func i64() throws(ProtocolError) -> Int64 { Int64(bitPattern: try u64()) }
    public mutating func f32() throws(ProtocolError) -> Float { Float(bitPattern: try u32()) }
    public mutating func f64() throws(ProtocolError) -> Double { Double(bitPattern: try u64()) }
    public mutating func raw(_ n: Int) throws(ProtocolError) -> [UInt8] { Array(try take(n)) }
    public mutating func blob() throws(ProtocolError) -> [UInt8] { try raw(Int(try u32())) }
    public mutating func string() throws(ProtocolError) -> String {
        let b = try take(Int(try u16()))
        guard let s = String(validating: b, as: UTF8.self) else { throw .malformed("utf8") }
        return s
    }
    /// A raw enum value that must be known.
    public mutating func enumValue<E: RawRepresentable>(_: E.Type) throws(ProtocolError) -> E where E.RawValue == UInt8 {
        let raw = try u8()
        guard let v = E(rawValue: raw) else { throw .malformed("\(E.self) \(raw)") }
        return v
    }
    /// Payloads must be consumed exactly; trailing bytes mean a malformed or mismatched message.
    public func finish() throws(ProtocolError) {
        guard remaining == 0 else { throw .malformed("\(remaining) trailing bytes") }
    }
}
