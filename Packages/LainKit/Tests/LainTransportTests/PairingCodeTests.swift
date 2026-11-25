import Foundation
import LainTransport
import Testing

struct PairingCodeTests {
    /// Golden vector shared with Rust (`rust/crates/lain-link/src/pairing_code.rs`).
    @Test func goldenVectorMatchesExactWireEncoding() throws {
        let hostId = "01234567-89AB-CDEF-0123-456789ABCDEF"
        let secret = Array(UInt8(1)...UInt8(32))
        let code = try PairingCode(hostId: hostId, secret: secret, hostName: "Studio")
        let encoded = code.encode()
        #expect(encoded.hasPrefix("lain1:"))
        let decoded = try PairingCode.decode(encoded)
        #expect(decoded == code)
        // Exact deterministic base64url bytes: version(01) + uuid(0123456789abcdef0123456789abcdef)
        // + secret(01..20) + len(06) + "Studio"(53747564696f)
        #expect(encoded == "lain1:AQEjRWeJq83vASNFZ4mrze8BAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIAZTdHVkaW8")
    }

    @Test func roundTripEmptyNameAndUnicodeTruncation() throws {
        let hostId = UUID().uuidString
        let secret = (0..<32).map { UInt8($0 &+ 0xA0) }
        let empty = try PairingCode(hostId: hostId, secret: secret)
        #expect(try PairingCode.decode(empty.encode()) == empty)

        let longName = String(repeating: "é", count: 50) // 100 UTF-8 bytes
        let truncated = try PairingCode(hostId: hostId, secret: secret, hostName: longName)
        #expect(truncated.hostName.utf8.count <= PairingCode.maxHostNameBytes)
        #expect(try PairingCode.decode(truncated.encode()) == truncated)
    }

    @Test func decodeIgnoresWhitespaceAndRejectsMalformed() throws {
        let code = try PairingCode(hostId: "01234567-89AB-CDEF-0123-456789ABCDEF",
                                   secret: Array(UInt8(1)...UInt8(32)), hostName: "Mac mini")
        let encoded = code.encode()
        let wrapped = "  \n" + encoded.prefix(20) + "\n  " + encoded.dropFirst(20) + " \t"
        #expect(try PairingCode.decode(String(wrapped)) == code)

        #expect(throws: PairingCode.Error.invalidFormat) { _ = try PairingCode.decode("not-a-code") }
        #expect(throws: PairingCode.Error.invalidFormat) { _ = try PairingCode.decode("lain1:") }
        #expect(throws: PairingCode.Error.invalidFormat) { _ = try PairingCode.decode("lain1:!!!") }
        #expect(throws: PairingCode.Error.invalidSecret) {
            _ = try PairingCode(hostId: "01234567-89AB-CDEF-0123-456789ABCDEF", secret: [UInt8](repeating: 0, count: 32))
        }
        #expect(throws: PairingCode.Error.invalidHostId) {
            _ = try PairingCode(hostId: "not-a-uuid", secret: Array(UInt8(1)...UInt8(32)))
        }
    }
}
