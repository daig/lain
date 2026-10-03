@testable import LainProtocol

/// One representative value of every message type: the module's canonical samples, which the schema
/// digests and the golden bytes are made from (`ProtocolSamples`).
enum Samples {
    static let hostId = ProtocolSamples.hostId
    static let all: [Message] = ProtocolSamples.all
}
