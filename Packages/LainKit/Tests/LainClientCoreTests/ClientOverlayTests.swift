import LainProtocol
import Testing
@testable import LainClientCore

@Suite struct ClientOverlayTests {
    func info(version: UInt8) -> ClientSession.ConnectionInfo {
        var i = ClientSession.ConnectionInfo()
        i.hostName = "Mac mini"
        i.protocolVersion = version
        i.newestOffered = 5
        i.macInputSource = "com.apple.keylayout.Colemak"
        return i
    }

    func section(_ title: String, _ sections: [ClientOverlay.Section]) -> [String] {
        sections.first { $0.title == title }?.lines ?? []
    }

    @Test func aV5MacShowsItsStats() {
        let stats = HostStats(encodeP50Us: 3_100, encodeP95Us: 5_400, ackRttP50Us: 7_900, captured: 10, encoded: 9, sent: 9,
                              droppedBeforeEncode: 1, inFlight: 1, peakInFlight: 2, bitsPerSecond: 48_000_000)
        let s = ClientOverlay.sections(info: info(version: 5), video: VideoStats(), host: stats)
        #expect(s.map(\.title) == ["Link", "iPad", "Mac", "Settings"])
        let mac = section("Mac", s)
        #expect(mac[0] == "encode 3.1/5.4 ms · ack RTT 7.9/– ms · 48.0 Mbps")
        #expect(mac[1].hasPrefix("in flight 1 (peak 2) · dropped before encode 1"))
        #expect(section("Settings", s).contains("Mac input source: com.apple.keylayout.Colemak"))
        #expect(section("Settings", s).contains { $0.hasPrefix("Remapped here (Right Option → Command): App switcher") })
    }

    @Test func aV5MacBeforeItsFirstStats() {
        let s = ClientOverlay.sections(info: info(version: 5), video: VideoStats(), host: nil)
        #expect(section("Mac", s) == ["waiting for the Mac…"])
    }

    @Test func aV4MacIsAskedToUpdate() {
        let s = ClientOverlay.sections(info: info(version: 4), video: VideoStats(), host: nil)
        #expect(section("Mac", s) == ["update lain on the Mac for its video stats"])
        #expect(section("Link", s).count == 2, "the older-Mac note")
    }

    @Test func noLink() {
        let s = ClientOverlay.sections(info: nil, video: VideoStats(), host: nil)
        #expect(section("Link", s) == ["no link"])
        #expect(section("Mac", s) == ["–"])
        #expect(ClientOverlay.text(s).hasPrefix("LINK\n  no link\n\nIPAD\n"))
    }
}
