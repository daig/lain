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
        let options: [ControlPanel.Row] = [.scrollDirection, .touchMode, .wifiPath, .radioPriority]
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
        var reversed = p
        reversed.reverseScroll = true
        #expect(panel.key(Self.left, hosts: h, preferences: p) == .setPreferences(reversed))
        #expect(panel.key(Self.enter, hosts: h, preferences: p) == .setPreferences(reversed))
    }

    @Test func pathAndPriorityCycle() {
        var panel = ControlPanel()
        let h = hosts(onCable: true), p = ClientPreferences()
        _ = panel.key(Self.down, hosts: h, preferences: p)   // the touch-screen row
        var off = p
        off.touchMode = .off
        #expect(panel.key(Self.right, hosts: h, preferences: p) == .setPreferences(off))
        #expect(panel.key(Self.left, hosts: h, preferences: off) == .setPreferences(p), "on or off")
        _ = panel.key(Self.down, hosts: h, preferences: p)   // the Wi-Fi path row
        var direct = p
        direct.wifiPath = .direct
        #expect(panel.key(Self.right, hosts: h, preferences: p) == .setPreferences(direct))
        var network = p
        network.wifiPath = .network
        #expect(panel.key(Self.left, hosts: h, preferences: p) == .setPreferences(network), "wraps around")
        _ = panel.key(Self.down, hosts: h, preferences: p)
        var video = p
        video.radioPriority = .interactiveVideo
        #expect(panel.key(Self.enter, hosts: h, preferences: p) == .setPreferences(video))
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
        #expect(rows.count == 7)
        #expect(rows[0].isSelected && rows[0].text.hasPrefix("○ Automatic"))
        #expect(rows[1].text.hasPrefix("◉ Mac mini") && rows[1].text.hasSuffix("connected"))
        #expect(rows[2].text.hasSuffix("in reach"))
        #expect(rows[3].text.contains("Natural"))

        let cabled = panel.lines(info: nil, video: VideoStats(), host: nil, hosts: hosts(onCable: true),
                                 preferences: ClientPreferences())
        #expect(cabled.contains { $0.text.hasPrefix("the cable is in") })
        #expect(cabled.filter { $0.row != nil }.count == 4, "the hosts are listed, not selectable")
        #expect(rows[4].text.hasPrefix("Touch screen") && rows[4].text.contains("On"))
        #expect(rows[5].text.contains("Automatic") && rows[6].text.contains("Standard"))
    }

    @Test func theSheetListsTheSameRowsToTap() throws {
        var panel = ControlPanel()
        var p = ClientPreferences()
        p.reverseScroll = true
        let sheet = panel.sheet(info: nil, video: VideoStats(), host: nil, hosts: hosts(selected: "B"), preferences: p)
        #expect(sheet.title == "Not connected")
        #expect(sheet.hosts.map(\.title) == ["Automatic", "Mac mini", "linux-box"])
        #expect(sheet.hosts.map(\.isChecked) == [false, false, true])
        #expect(sheet.hosts[1].value == "connected" && sheet.hostsNote == nil)
        #expect(sheet.options.map(\.title) == ["Scroll direction", "Touch screen", "Wi-Fi path", "Radio priority"])
        #expect(sheet.options[0].value == "Reversed")
        // A tap on an item is a click on its row.
        let rows = ControlPanel.rows(hosts: hosts())
        #expect(sheet.hosts.compactMap(\.row).map { rows[$0] } == [.host(nil), .host("A"), .host("B")])
        #expect(panel.click(row: try #require(sheet.hosts[1].row), hosts: hosts(), preferences: p) == .selectHost("A"))
        #expect(rows[try #require(sheet.options[2].row)] == .wifiPath)

        // On the cable the hosts are listed but can't be picked.
        let cabled = panel.sheet(info: nil, video: VideoStats(), host: nil, hosts: hosts(onCable: true), preferences: p)
        #expect(cabled.hosts.count == 2 && cabled.hosts.allSatisfy { $0.row == nil } && cabled.hostsNote != nil)
        let none = panel.sheet(info: nil, video: VideoStats(), host: nil, hosts: ClientSession.HostList(), preferences: p)
        #expect(none.hosts.isEmpty && none.hostsNote != nil)
    }

    @Test func deviceNameFollowsTheModel() {
        #expect(ClientStatus.deviceName(model: "iPhone19,4") == "iPhone" && ClientStatus.deviceName(model: "iPad16,6") == "iPad")
        #expect(ClientStatus.homeDisplay(model: "iPhone19,4")?.pixelWidth == 2853 && ClientStatus.homeDisplay(model: "iPad16,6") == nil)
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
        p.reverseScroll = true
        p.touchMode = .off
        p.save(to: defaults)
        #expect(ClientPreferences.load(from: defaults) == p)
    }
}

/// v7: the display's scale is this device's to choose, from what the host offers.
@Suite struct DisplayScaleSettingTests {
    func offering(_ scales: [UInt16], applied: UInt16 = 200) -> ClientSession.HostList {
        var l = ClientSession.HostList()
        l.displayScales = scales
        l.displayScale = applied
        return l
    }
    let quarters: [UInt16] = [150, 175, 200, 225, 250, 275, 300]

    @Test func theRowShowsOnlyWhenTheHostOffersScales() {
        #expect(!ControlPanel.rows(hosts: ClientSession.HostList()).contains(.displayScale), "an older host, or none")
        #expect(ControlPanel.rows(hosts: offering(quarters)).last == .displayScale)
    }

    @Test func leftAndRightStepThroughTheOfferedScales() {
        var panel = ControlPanel()
        let h = offering(quarters)
        let row = ControlPanel.rows(hosts: h).firstIndex(of: .displayScale)!
        var p = ClientPreferences()
        #expect(p.displayScale == 200, "2×: an iPad's desktop, as before")
        for _ in 0..<row { _ = panel.key(ControlPanelTests.down, hosts: h, preferences: p) }
        guard case .setPreferences(let up) = panel.key(ControlPanelTests.right, hosts: h, preferences: p) else { Issue.record("no change"); return }
        #expect(up.displayScale == 225)
        p.displayScale = 300
        guard case .setPreferences(let wrapped) = panel.key(ControlPanelTests.right, hosts: h, preferences: p) else { Issue.record("no change"); return }
        #expect(wrapped.displayScale == 150)
    }

    @Test func aChoiceTheHostDoesntOfferMovesToTheNearest() {
        #expect(ControlPanel.nextScale(after: 300, in: [150, 200, 250], by: 1) == 250)
        #expect(ControlPanel.nextScale(after: 200, in: [150, 200, 250], by: -1) == 150)
        #expect(ControlPanel.nextScale(after: 200, in: [], by: 1) == 200)
    }

    @Test func theValueSaysTheScaleAndWhatTheHostMade() {
        #expect(ControlPanel.scaleText(200) == "2×" && ControlPanel.scaleText(175) == "1.75×" && ControlPanel.scaleText(150) == "1.5×")
        #expect(ControlPanel.scaleText(205) == "2.05×")
        var info = ClientSession.ConnectionInfo()
        info.displayPointWidth = 951
        info.displayPointHeight = 669
        #expect(ControlPanel.scaleValue(300, hosts: offering(quarters, applied: 300), info: info) == "3× · 951×669 pt")
        #expect(ControlPanel.scaleValue(300, hosts: offering([150, 200], applied: 200), info: info) == "3× (host: 2×)")
    }

    @Test func onATouchScreenTheScaleIsPickedFromAList() throws {
        let h = offering([150, 200, 300])
        let p = ClientPreferences()
        var three = p
        three.displayScale = 300
        let sheet = ControlPanel().sheet(info: nil, video: VideoStats(), host: nil, hosts: h, preferences: p)
        let item = try #require(sheet.options.first { $0.title == "Display scale" })
        #expect(item.choices == ["1.5× · more room", "2× · this screen's size", "3× · larger"] && item.chosen == 1)
        let row = try #require(item.row)
        #expect(ControlPanel().choose(row: row, index: 2, hosts: h, preferences: p) == .setPreferences(three))
        #expect(ControlPanel().choose(row: row, index: 1, hosts: h, preferences: ClientPreferences()) == .none, "already chosen")
        #expect(ControlPanel().choose(row: row, index: 9, hosts: h, preferences: ClientPreferences()) == .none)
        #expect(ControlPanel().choose(row: 0, index: 0, hosts: h, preferences: ClientPreferences()) == .none, "not the scale's row")
        // The other options are still tapped, not picked from a list.
        let othersAreTapped = sheet.options.filter { $0.title != "Display scale" }.allSatisfy { $0.choices.isEmpty }
        #expect(othersAreTapped)
    }

    @Test func untilOneIsPickedTheScaleIsTheScreensOwn() throws {
        let defaults = try #require(UserDefaults(suiteName: "lain.test.nativeScale"))
        defaults.removePersistentDomain(forName: "lain.test.nativeScale")
        // An iPhone Duo (3×) asks for its own scale; an iPad (2×), for the desktop it has always had.
        let duo = ClientPreferences.load(from: defaults, nativeScale: 300)
        #expect(duo.displayScale == 300 && duo.nativeDisplayScale == 300)
        #expect(ClientPreferences.load(from: defaults, nativeScale: 200).displayScale == 200)
        // The list says which is the screen's own.
        let sheet = ControlPanel().sheet(info: nil, video: VideoStats(), host: nil, hosts: offering(quarters), preferences: duo)
        let item = try #require(sheet.options.first { $0.title == "Display scale" })
        #expect(item.choices.last == "3× · this screen's size" && item.choices.first == "1.5× · more room")
        #expect(item.chosen == quarters.firstIndex(of: 300))
        // A pick is kept over the default.
        var picked = duo
        picked.displayScale = 200
        picked.save(to: defaults)
        #expect(ClientPreferences.load(from: defaults, nativeScale: 300).displayScale == 200)
        defaults.removePersistentDomain(forName: "lain.test.nativeScale")
    }

    @Test func theChoiceIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "lain.test.displayScale"))
        defaults.removePersistentDomain(forName: "lain.test.displayScale")
        var p = ClientPreferences()
        p.displayScale = 275
        p.save(to: defaults)
        #expect(ClientPreferences.load(from: defaults).displayScale == 275)
        defaults.removePersistentDomain(forName: "lain.test.displayScale")
        #expect(ClientPreferences.load(from: defaults).displayScale == 200)
    }
}
