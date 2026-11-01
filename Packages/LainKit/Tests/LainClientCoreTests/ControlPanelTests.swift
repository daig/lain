import Foundation
import LainInput
import LainProtocol
import Testing
@testable import LainClientCore

@Suite struct ControlPanelTests {
    static let up = PhysicalKey.key(0x52), down = PhysicalKey.key(0x51), left = PhysicalKey.key(0x50)
    static let right = PhysicalKey.key(0x4F), enter = PhysicalKey.key(0x28), esc = PhysicalKey.key(0x29)

    func hosts(onCable: Bool = false, selected: String? = nil) -> ClientSession.HostList {
        var l = ClientSession.HostList()
        l.hosts = [ClientSession.SavedHost(id: "A", name: "Mac mini", isCurrent: true, isSeen: true),
                   ClientSession.SavedHost(id: "B", name: "linux-box", isCurrent: false, isSeen: true)]
        l.onCable = onCable
        l.selected = selected
        return l
    }

    @Test func rowsAreTheHostsThenTheOptions() {
        let options: [ControlPanel.Row] = [.pointerSpeed, .scrollSpeed, .scrollDirection]
        #expect(ControlPanel.rows(hosts: hosts()) == [.host(nil), .host("A"), .host("B")] + options)
        #expect(ControlPanel.rows(hosts: hosts(onCable: true)) == options, "no switching on the cable")
        #expect(ControlPanel.rows(hosts: ClientSession.HostList()) == options)
    }

    @Test func arrowsSelectAndReturnSwitchesHosts() {
        var panel = ControlPanel()
        let h = hosts(), p = ClientPreferences()
        #expect(panel.key(Self.down, hosts: h, preferences: p) == .none)
        #expect(panel.key(Self.down, hosts: h, preferences: p) == .none)
        #expect(panel.key(Self.enter, hosts: h, preferences: p) == .selectHost("B"))
        #expect(panel.key(Self.up, hosts: h, preferences: p) == .none)
        #expect(panel.key(Self.up, hosts: h, preferences: p) == .none)
        #expect(panel.key(Self.up, hosts: h, preferences: p) == .none, "stays at the top")
        #expect(panel.key(Self.enter, hosts: h, preferences: p) == .selectHost(nil))
        #expect(panel.key(Self.esc, hosts: h, preferences: p) == .close)
    }

    @Test func leftAndRightChangeOptions() {
        var panel = ControlPanel()
        let h = hosts(onCable: true), p = ClientPreferences()
        var faster = p
        faster.pointerSpeed = 4
        #expect(panel.key(Self.right, hosts: h, preferences: p) == .setPreferences(faster))
        var top = p
        top.pointerSpeed = 5
        #expect(panel.key(Self.right, hosts: h, preferences: top) == .none, "already the fastest")
        _ = panel.key(Self.down, hosts: h, preferences: p)
        var slowerScroll = p
        slowerScroll.scrollSpeed = 2
        #expect(panel.key(Self.left, hosts: h, preferences: p) == .setPreferences(slowerScroll))
        _ = panel.key(Self.down, hosts: h, preferences: p)
        var reversed = p
        reversed.reverseScroll = true
        #expect(panel.key(Self.left, hosts: h, preferences: p) == .setPreferences(reversed))
        #expect(panel.key(Self.enter, hosts: h, preferences: p) == .setPreferences(reversed))
    }

    @Test func aClickActsOnItsRow() {
        var panel = ControlPanel()
        #expect(panel.click(row: 2, hosts: hosts(), preferences: ClientPreferences()) == .selectHost("B"))
        #expect(panel.selection == 2)
        #expect(panel.click(row: 9, hosts: hosts(), preferences: ClientPreferences()) == .none)
    }

    @Test func linesShowTheSelectionThePickAndTheCable() {
        let panel = ControlPanel()
        let lines = panel.lines(info: nil, video: VideoStats(), host: nil, hosts: hosts(selected: "A"),
                                preferences: ClientPreferences())
        let headings = lines.filter { $0.style == .heading }.map(\.text)
        #expect(headings == ["STREAM", "HOSTS", "OPTIONS", "SHORTCUTS"])
        let rows = lines.filter { $0.row != nil }
        #expect(rows.count == 6)
        #expect(rows[0].isSelected && rows[0].text.hasPrefix("○ Automatic"))
        #expect(rows[1].text.hasPrefix("◉ Mac mini") && rows[1].text.hasSuffix("connected"))
        #expect(rows[2].text.hasSuffix("in reach"))
        #expect(rows[3].text.contains("●●●○○"))
        #expect(rows[4].text.hasPrefix("Scroll speed") && rows[4].text.contains("●●●○○"))
        #expect(rows[5].text.contains("Natural"))

        let cabled = panel.lines(info: nil, video: VideoStats(), host: nil, hosts: hosts(onCable: true),
                                 preferences: ClientPreferences())
        #expect(cabled.contains { $0.text.hasPrefix("the cable is in") })
        #expect(cabled.filter { $0.row != nil }.count == 3, "the hosts are listed, not selectable")
    }

    @Test func theHostLineSaysWhyItHasNoNumbers() {
        var info = ClientSession.ConnectionInfo()
        info.protocolVersion = 4
        #expect(ControlPanel.hostLine(info: info, host: nil).hasPrefix("no numbers: this host's lain is older"))
        info.protocolVersion = 5
        #expect(ControlPanel.hostLine(info: info, host: nil) == "waiting for numbers…")
        let h = HostStats(encodeP50Us: 3_100, encodeP95Us: 5_400, ackRttP50Us: 7_900, inFlight: 1, peakInFlight: 2)
        #expect(ControlPanel.hostLine(info: info, host: h) == "encode 3.1/5.4 ms · ack RTT 7.9 ms · in flight 1 (peak 2) · held back 0")
    }

    @Test func preferencesRoundTripAndClamp() throws {
        let defaults = try #require(UserDefaults(suiteName: "lain.tests.\(UUID().uuidString)"))
        #expect(ClientPreferences.load(from: defaults) == ClientPreferences())
        var p = ClientPreferences()
        p.pointerSpeed = 9
        #expect(p.pointerSpeed == 5)
        p.scrollSpeed = 0
        #expect(p.scrollSpeed == 1 && p.scrollScale == 0.5)
        p.reverseScroll = true
        p.save(to: defaults)
        #expect(ClientPreferences.load(from: defaults) == p)
        #expect(p.curve.sensitivity == 1.2)
        #expect(ClientPreferences().curve == AccelerationCurve(), "speed 3 is today's curve")
    }
}
