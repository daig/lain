import LainTransport
import Network
import Testing

@Suite struct WakeOnLANTests {
    @Test func parsesAndNormalizesValidMACsAndRejectsInvalidOnes() {
        #expect(WakeOnLAN.normalizeMAC("AA:BB:CC:DD:EE:FF") == "aabbccddeeff")
        #expect(WakeOnLAN.normalizeMAC("10-22-33-44-55-66") == "102233445566")
        #expect(WakeOnLAN.normalizeMAC("102233445566") == "102233445566")
        #expect(WakeOnLAN.parseMAC("10:22:33:44:55:66") == [0x10, 0x22, 0x33, 0x44, 0x55, 0x66])

        #expect(WakeOnLAN.normalizeMAC("00:00:00:00:00:00") == nil, "all-zero rejected")
        #expect(WakeOnLAN.normalizeMAC("02:00:00:00:00:00") == nil, "sandbox dummy MAC rejected")
        #expect(WakeOnLAN.normalizeMAC("01:22:33:44:55:66") == nil, "multicast bit rejected")
        #expect(WakeOnLAN.normalizeMAC("not-a-mac") == nil)
        #expect(WakeOnLAN.normalizeMAC("aabbccddeef") == nil)
    }

    @Test func magicPacketIs102BytesWithSixFFsAndSixteenCopies() {
        let mac: [UInt8] = [0x10, 0x22, 0x33, 0x44, 0x55, 0x66]
        let packet = WakeOnLAN.magicPacket(mac: mac)
        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        for i in 0..<16 {
            let start = 6 + i * 6
            #expect(Array(packet[start..<(start + 6)]) == mac)
        }
        #expect(WakeOnLAN.magicPacket(mac: [0x10, 0x22]).isEmpty)
    }

    @Test func txtRecordCarriesAndParsesWakeMACsBackwardsCompatibly() throws {
        let plain = LainTXT.dictionary(hostId: "11111111-1111-1111-1111-111111111111")
        #expect(plain[LainTXT.macsKey] == nil, "omitted when empty")

        let withMacs = LainTXT.dictionary(hostId: "11111111-1111-1111-1111-111111111111",
                                          macs: ["10:22:33:44:55:66", "00:00:00:00:00:00", "AA:BB:CC:DD:EE:FF"])
        #expect(withMacs[LainTXT.macsKey] == "102233445566,aabbccddeeff")
        #expect(LainTXT.macs(in: withMacs) == ["102233445566", "aabbccddeeff"])

        let endpoint = NWEndpoint.service(name: "MacBook", type: "_lain._tcp", domain: "local.", interface: nil)
        let host = try #require(DiscoveredHost(endpoint: endpoint, txt: withMacs, interfaceNames: ["en0"]))
        #expect(host.macs == ["102233445566", "aabbccddeeff"])
    }
}
