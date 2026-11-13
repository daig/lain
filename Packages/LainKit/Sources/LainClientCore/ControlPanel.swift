import Foundation
import LainInput
import LainProtocol
import LainTransport

/// The iPad's own settings, changed from the panel and kept in its defaults.
public struct ClientPreferences: Sendable, Equatable {
    /// Reverses the trackpad's scroll direction (off: as the host's natural scrolling).
    public var reverseScroll = false
    /// Whether fingers on the stream drive the pointer (`direct`) or do nothing (`off`). The trackpad areas
    /// the iPad shows without a hardware keyboard work either way; `trackpad` for the whole screen is no
    /// longer offered (a saved one loads as `direct`).
    public var touchMode = TouchMode.direct
    /// How the iPad reaches a host over Wi-Fi.
    public var wifiPath = WiFiPath.automatic
    /// How video and audio ask the radio for airtime (D34).
    public var radioPriority = NetworkStreamOptions.RadioPriority.standard
    /// The pixels per point this device asks the host's display to be, in hundredths (v7), from what the host
    /// offers (`HostList.displayScales`). Until the owner picks one, the device screen's own
    /// (`nativeDisplayScale`): things on the computer's display are the size they are on the device (an
    /// iPad's 2× desktop, as always; 3× on an iPhone); more room is a setting away.
    public var displayScale: UInt16 = ClientPreferences.defaultDisplayScale
    /// The device screen's own pixels per point, in hundredths: the default scale. Not kept: the device says.
    public var nativeDisplayScale: UInt16 = ClientPreferences.defaultDisplayScale

    /// 2×: an iPad's own, and the desktop lain has always made.
    public static let defaultDisplayScale: UInt16 = 200

    public init() {}

    static let scrollKey = "lain.reverseScroll"
    static let pathKey = "lain.wifiPath", priorityKey = "lain.radioPriority", touchKey = "lain.touchMode"
    static let scaleKey = "lain.displayScale"

    /// `nativeScale`: the device screen's pixels per point, in hundredths (`nativeDisplayScale`), the scale
    /// until one is picked.
    public static func load(from defaults: UserDefaults = .standard, nativeScale: UInt16 = defaultDisplayScale) -> ClientPreferences {
        var p = ClientPreferences()
        p.nativeDisplayScale = nativeScale
        p.displayScale = nativeScale
        p.reverseScroll = defaults.bool(forKey: scrollKey)
        if let raw = defaults.string(forKey: touchKey), let mode = TouchMode(rawValue: raw) { p.touchMode = mode == .off ? .off : .direct }
        if let raw = defaults.string(forKey: pathKey), let path = WiFiPath(rawValue: raw) { p.wifiPath = path }
        if let raw = defaults.string(forKey: priorityKey), let priority = NetworkStreamOptions.RadioPriority(rawValue: raw) {
            p.radioPriority = priority
        }
        let scale = defaults.integer(forKey: scaleKey)
        if (50...400).contains(scale) { p.displayScale = UInt16(scale) }
        return p
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(reverseScroll, forKey: Self.scrollKey)
        defaults.set(touchMode.rawValue, forKey: Self.touchKey)
        defaults.set(wifiPath.rawValue, forKey: Self.pathKey)
        defaults.set(radioPriority.rawValue, forKey: Self.priorityKey)
        defaults.set(Int(displayScale), forKey: Self.scaleKey)
    }
}

/// The panel opened by holding Right Option, lain's system key, alone (`ClientInputPipeline.overlayHoldNs`).
/// It stays open until Esc or a Right Option tap; meanwhile the keyboard and trackpad drive it and nothing
/// reaches the host. Four parts: the stream (this iPad's numbers and the host's, v5 `HostStats`), the hosts
/// (switching over Wi-Fi; not while the cable is in, which always wins), the iPad's options, and a cheat
/// sheet of lain's shortcuts. Host-neutral: a Mac or a Linux host. Pure: the stream view renders `lines` and
/// feeds keys and clicks back.
public struct ControlPanel: Sendable, Equatable {
    /// How often the panel asks the host for `HostStats` while it shows.
    public static let hostStatsIntervalMs: UInt32 = 250

    /// Something the owner can act on.
    public enum Row: Sendable, Equatable {
        /// A saved host; nil: automatic (the cable first, then the last connected).
        case host(String?)
        case scrollDirection
        case touchMode
        case wifiPath
        case radioPriority
        /// v7: the display's scale, from those the host offers.
        case displayScale
    }

    public enum Action: Sendable, Equatable {
        case none
        case close
        case selectHost(String?)
        case setPreferences(ClientPreferences)
    }

    /// One line of the panel. `row`: the index into `rows` it acts on, if any.
    public struct Line: Sendable, Equatable {
        public enum Style: Sendable, Equatable { case title, heading, text, dim }
        public var text: String
        public var style: Style
        public var row: Int?
        public var isSelected: Bool
    }

    /// Index into `rows(hosts:)`.
    public private(set) var selection = 0

    public init() {}

    /// What the owner can act on now: the hosts (unless the cable is in), then the iPad's options.
    public static func rows(hosts: ClientSession.HostList) -> [Row] {
        var rows: [Row] = []
        if !hosts.onCable, !hosts.hosts.isEmpty {
            rows.append(.host(nil))
            rows += hosts.hosts.map { .host($0.id) }
        }
        rows += [.scrollDirection, .touchMode, .wifiPath, .radioPriority]
        if !hosts.displayScales.isEmpty { rows.append(.displayScale) }
        return rows
    }

    // MARK: Input

    static let up: UInt16 = 0x52, down: UInt16 = 0x51, left: UInt16 = 0x50, right: UInt16 = 0x4F
    static let enter: UInt16 = 0x28, keypadEnter: UInt16 = 0x58, escape: UInt16 = 0x29, space: UInt16 = 0x2C

    /// A key-down while the panel is open.
    public mutating func key(_ key: PhysicalKey, hosts: ClientSession.HostList, preferences: ClientPreferences) -> Action {
        let rows = Self.rows(hosts: hosts)
        selection = min(selection, rows.count - 1)
        guard key.page == PhysicalKey.keyboardPage else { return .none }
        switch key.usage {
        case Self.escape:
            return .close
        case Self.up:
            selection = max(selection - 1, 0)
        case Self.down:
            selection = min(selection + 1, rows.count - 1)
        case Self.left, Self.right:
            return change(rows[selection], by: key.usage == Self.left ? -1 : 1, hosts: hosts, preferences: preferences)
        case Self.enter, Self.keypadEnter, Self.space:
            return activate(rows[selection], hosts: hosts, preferences: preferences)
        default:
            break
        }
        return .none
    }

    /// A click on the line acting on `row`: selects it and acts as Return would.
    public mutating func click(row: Int, hosts: ClientSession.HostList, preferences: ClientPreferences) -> Action {
        let rows = Self.rows(hosts: hosts)
        guard rows.indices.contains(row) else { return .none }
        selection = row
        return activate(rows[row], hosts: hosts, preferences: preferences)
    }

    private func activate(_ row: Row, hosts: ClientSession.HostList, preferences: ClientPreferences) -> Action {
        switch row {
        case .host(let id): .selectHost(id)
        case .scrollDirection, .touchMode, .wifiPath, .radioPriority, .displayScale:
            change(row, by: 1, hosts: hosts, preferences: preferences)
        }
    }

    private func change(_ row: Row, by step: Int, hosts: ClientSession.HostList, preferences: ClientPreferences) -> Action {
        var p = preferences
        switch row {
        case .host: return .none
        case .scrollDirection: p.reverseScroll.toggle()
        case .touchMode: p.touchMode = p.touchMode == .off ? .direct : .off
        case .wifiPath: p.wifiPath = Self.cycle(p.wifiPath, by: step)
        case .radioPriority: p.radioPriority = Self.cycle(p.radioPriority, by: step)
        case .displayScale: p.displayScale = Self.nextScale(after: p.displayScale, in: hosts.displayScales, by: step)
        }
        return p == preferences ? .none : .setPreferences(p)
    }

    // MARK: Content

    /// The panel's lines, top to bottom.
    public func lines(info: ClientSession.ConnectionInfo?, video: VideoStats, host: HostStats?,
                      hosts: ClientSession.HostList, preferences: ClientPreferences,
                      sound: ClientAudioPlayer.Delay? = nil) -> [Line] {
        let rows = Self.rows(hosts: hosts)
        let selected = min(selection, rows.count - 1)
        var out: [Line] = []
        func add(_ text: String, _ style: Line.Style = .text, row: Int? = nil) {
            out.append(Line(text: text, style: style, row: row, isSelected: row != nil && row == selected))
        }

        if let info {
            let name = info.hostName.isEmpty ? "host" : info.hostName
            add("\(name) · \(ClientStatus.describe(info.transport)) · protocol v\(info.protocolVersion)", .title)
        } else {
            add("not connected", .title)
        }

        add("STREAM", .heading)
        add(Self.streamLine(video))
        add(Self.pad(ClientStatus.device, to: 7) + Self.iPadLine(video))
        add("Host   " + Self.hostLine(info: info, host: host), host == nil ? .dim : .text)
        if let sound { add("Sound  " + Self.soundLine(sound)) }

        add("HOSTS", .heading)
        if hosts.hosts.isEmpty {
            add("none saved yet: connect a host with the cable once", .dim)
        } else if hosts.onCable {
            add("the cable is in, and it always wins: unplug it to switch", .dim)
            for h in hosts.hosts { add(Self.hostRow(h.id, hosts: hosts), .dim) }
        } else {
            for (i, row) in rows.enumerated() {
                guard case .host(let id) = row else { continue }
                add(Self.hostRow(id, hosts: hosts), row: i)
            }
        }

        add("OPTIONS", .heading)
        for (i, row) in rows.enumerated() {
            switch row {
            case .scrollDirection:
                add(Self.pad("Scroll direction") + "‹ " + (preferences.reverseScroll ? "Reversed" : "Natural") + " ›", row: i)
            case .touchMode:
                add(Self.pad("Touch screen") + "‹ " + Self.title(preferences.touchMode) + " ›", row: i)
            case .wifiPath:
                add(Self.pad("Wi-Fi path") + "‹ " + Self.title(preferences.wifiPath) + " ›", row: i)
            case .radioPriority:
                add(Self.pad("Radio priority") + "‹ " + Self.title(preferences.radioPriority) + " ›", row: i)
            case .displayScale:
                add(Self.pad("Display scale") + "‹ " + Self.scaleValue(preferences.displayScale, hosts: hosts, info: info) + " ›", row: i)
            case .host:
                break
            }
        }

        add("SHORTCUTS", .heading)
        for (keys, action) in Self.shortcuts { add(Self.pad(keys) + action) }
        add("in this panel: ↑ ↓ select · ← → change · return or click: choose · esc or right ⌥: close", .dim)
        return out
    }

    // MARK: Content for a touch sheet

    /// The panel's content for a window too narrow for its lines (a phone, a Split View half): the same rows,
    /// as a list to tap. The shortcuts are left out: they are a keyboard's.
    public struct Sheet: Sendable, Equatable {
        public struct Item: Sendable, Equatable {
            /// The index into `rows` a tap acts on (`click(row:)`); nil: nothing to do.
            public var row: Int?
            public var title: String
            public var value: String
            public var isChecked = false
            /// An option picked from a list (the display scale): the list's entries, and the current one. A tap
            /// opens the list; `choose(row:index:)` applies an entry. Empty: a tap acts on the row.
            public var choices: [String] = []
            public var chosen: Int?
        }
        public var title = ""
        /// The stream's numbers, a line each.
        public var status: [String] = []
        public var hosts: [Item] = []
        /// Why the hosts can't be switched, or that there are none.
        public var hostsNote: String?
        public var options: [Item] = []
        public init() {}
    }

    public func sheet(info: ClientSession.ConnectionInfo?, video: VideoStats, host: HostStats?,
                      hosts: ClientSession.HostList, preferences: ClientPreferences,
                      sound: ClientAudioPlayer.Delay? = nil) -> Sheet {
        var out = Sheet()
        if let info {
            out.title = "\(info.hostName.isEmpty ? "host" : info.hostName) · \(ClientStatus.describe(info.transport))"
        } else {
            out.title = "Not connected"
        }
        out.status = [Self.streamLine(video), ClientStatus.device + ": " + Self.iPadLine(video), "Host: " + Self.hostLine(info: info, host: host)]
        if let sound { out.status.append("Sound: " + Self.soundLine(sound)) }

        func hostItem(_ id: String?, row: Int?) -> Sheet.Item {
            guard let id else { return Sheet.Item(row: row, title: "Automatic", value: "cable first, then the last used", isChecked: hosts.selected == nil) }
            let h = hosts.hosts.first { $0.id == id }
            return Sheet.Item(row: row, title: h?.name ?? id, value: h.map { $0.isCurrent ? "connected" : ($0.isSeen ? "in reach" : "") } ?? "",
                              isChecked: hosts.selected == id)
        }
        let rows = Self.rows(hosts: hosts)
        if hosts.hosts.isEmpty {
            out.hostsNote = "None saved yet: connect a host with the cable once."
        } else if hosts.onCable {
            out.hostsNote = "The cable is in, and it always wins: unplug it to switch."
            out.hosts = hosts.hosts.map { hostItem($0.id, row: nil) }
        }
        for (i, row) in rows.enumerated() {
            switch row {
            case .host(let id): out.hosts.append(hostItem(id, row: i))
            case .scrollDirection: out.options.append(.init(row: i, title: "Scroll direction", value: preferences.reverseScroll ? "Reversed" : "Natural"))
            case .touchMode: out.options.append(.init(row: i, title: "Touch screen", value: Self.title(preferences.touchMode)))
            case .wifiPath: out.options.append(.init(row: i, title: "Wi-Fi path", value: Self.title(preferences.wifiPath)))
            case .radioPriority: out.options.append(.init(row: i, title: "Radio priority", value: Self.title(preferences.radioPriority)))
            case .displayScale:
                var item = Sheet.Item(row: i, title: "Display scale", value: Self.scaleValue(preferences.displayScale, hosts: hosts, info: info))
                item.choices = hosts.displayScales.map { Self.scaleChoiceTitle($0, native: preferences.nativeDisplayScale) }
                item.chosen = hosts.displayScales.firstIndex(of: preferences.displayScale)
                out.options.append(item)
            }
        }
        return out
    }

    /// Picks entry `index` of a row's list (`Sheet.Item.choices`): the display scale.
    public func choose(row: Int, index: Int, hosts: ClientSession.HostList, preferences: ClientPreferences) -> Action {
        let rows = Self.rows(hosts: hosts)
        guard rows.indices.contains(row), rows[row] == .displayScale, hosts.displayScales.indices.contains(index) else { return .none }
        var p = preferences
        p.displayScale = hosts.displayScales[index]
        return p == preferences ? .none : .setPreferences(p)
    }

    /// "3× · this screen's size", "2× · more room": a scale in the list, against the device screen's own.
    static func scaleChoiceTitle(_ scale: UInt16, native: UInt16) -> String {
        scaleText(scale) + (scale == native ? " · this screen's size" : scale < native ? " · more room" : " · larger")
    }

    /// The scale after `current` among `offered` (hundredths, ascending), `step` along, wrapping: from the
    /// offered scale nearest `current` when it isn't one of them.
    static func nextScale(after current: UInt16, in offered: [UInt16], by step: Int) -> UInt16 {
        guard !offered.isEmpty else { return current }
        let at = offered.firstIndex(of: current)
            ?? offered.indices.min { abs(Int(offered[$0]) - Int(current)) < abs(Int(offered[$1]) - Int(current)) }!
        let moved = offered.firstIndex(of: current) == nil ? at : at + step
        return offered[((moved % offered.count) + offered.count) % offered.count]
    }

    /// "2×" (hundredths in), with the desktop's size in points where the connection says it, and what the host
    /// applied when that differs from the choice.
    static func scaleValue(_ scale: UInt16, hosts: ClientSession.HostList, info: ClientSession.ConnectionInfo?) -> String {
        var text = scaleText(scale)
        if hosts.displayScale != 0, hosts.displayScale != scale {
            text += " (host: \(scaleText(hosts.displayScale)))"
        } else if let info, info.displayPointWidth > 0 {
            text += " · \(info.displayPointWidth)×\(info.displayPointHeight) pt"
        }
        return text
    }

    static func scaleText(_ hundredths: UInt16) -> String {
        let whole = hundredths / 100, fraction = hundredths % 100
        if fraction == 0 { return "\(whole)×" }
        return fraction % 10 == 0 ? "\(whole).\(fraction / 10)×" : "\(whole).\(String(format: "%02d", fraction))×"
    }

    /// The cheat sheet. Where a host's systems differ: the Mac's, then Linux's (GNOME).
    public static let shortcuts: [(String, String)] = [
        ("right ⌥ tap", "Mission Control · Overview"),
        ("right ⌥ + key", "⌘ + key: ⌘ Tab, ⌘ Space, ⌘ Q…"),
        ("right ⌥ + ↑ / ↓", "Mission Control / App Exposé · Overview / app grid"),
        ("right ⌥ + ← / →", "previous / next Space · workspace"),
        ("right ⌥ hold", "this panel"),
        ("left ⌥", "Option"),
        ("⌃⌥⌘ L", "stats HUD"),
        ("touch the screen", "press where you touch · two fingers: scroll, or tap to right-click"),
        ("trackpad areas", "move · tap: click · hold still, then move: drag (no keyboard attached)"),
    ]

    /// "62 ms behind (arrives 18, worst 31 · buffer 38 of 40 · output 6) · gaps 0 · dropped 0 ms"
    static func soundLine(_ d: ClientAudioPlayer.Delay) -> String {
        func ms(_ v: Double) -> String { String(Int(v.rounded())) }
        return "\(ms(d.totalMs)) ms behind (arrives \(ms(d.arrivalMs)), worst \(ms(d.worstArrivalMs)) · buffer \(ms(d.bufferedMs)) of \(ms(d.targetMs))"
            + " · output \(ms(d.outputMs))) · gaps \(d.underruns) · dropped \(ms(d.droppedMs)) ms"
    }

    static func cycle<T: CaseIterable & Equatable>(_ value: T, by step: Int) -> T {
        let all = Array(T.allCases)
        let i = all.firstIndex(of: value) ?? 0
        return all[((i + step) % all.count + all.count) % all.count]
    }

    static func title(_ mode: TouchMode) -> String {
        switch mode {
        case .direct, .trackpad: "On"
        case .off: "Off"
        }
    }

    static func title(_ path: WiFiPath) -> String {
        switch path {
        case .automatic: "Automatic"
        case .direct: "Direct (peer to peer)"
        case .network: "Through the network"
        }
    }

    static func title(_ priority: NetworkStreamOptions.RadioPriority) -> String {
        switch priority {
        case .standard: "Standard"
        case .interactiveVideo: "Interactive video"
        }
    }

    static func pad(_ s: String, to width: Int = 20) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    static func hostRow(_ id: String?, hosts: ClientSession.HostList) -> String {
        let mark = hosts.selected == id ? "◉ " : "○ "
        guard let id else { return mark + pad("Automatic", to: 18) + "cable first, then the last used" }
        guard let h = hosts.hosts.first(where: { $0.id == id }) else { return mark + id }
        return mark + pad(h.name, to: 18) + (h.isCurrent ? "connected" : (h.isSeen ? "in reach" : ""))
    }

    static func streamLine(_ v: VideoStats) -> String {
        guard v.width > 0 else { return "no video" }
        let mode = v.chroma == .yuv444 ? "4:4:4 10-bit" : "4:2:0"
        return "\(v.width)×\(v.height) · \(mode) · " + String(format: "%.0f fps · %.1f Mb/s", v.presentedFps, v.bitrateMbps)
    }

    static func iPadLine(_ v: VideoStats) -> String {
        "decode \(ms(v.decodeP50Ms))/\(ms(v.decodeP95Ms)) ms · present \(ms(v.receiveToPresentP50Ms))/\(ms(v.receiveToPresentP95Ms)) ms"
            + " · dropped \(v.framesDropped + v.framesSkipped) · errors \(v.decodeErrors)"
    }

    static func hostLine(info: ClientSession.ConnectionInfo?, host: HostStats?) -> String {
        guard let info else { return "–" }
        guard ProtocolFeature.hostStats.isSupported(at: info.protocolVersion) else {
            return "no numbers: this host's lain is older (protocol v\(info.protocolVersion))"
        }
        guard let h = host else { return "waiting for numbers…" }
        return "encode \(us(h.encodeP50Us))/\(us(h.encodeP95Us)) ms · ack RTT \(us(h.ackRttP50Us)) ms"
            + " · in flight \(h.inFlight) (peak \(h.peakInFlight)) · held back \(h.droppedBeforeEncode)"
    }

    static func ms(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
    static func us(_ v: UInt32) -> String { v == HostStats.none ? "–" : String(format: "%.1f", Double(v) / 1000) }
}
