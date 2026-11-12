import Foundation
import LainInput
import LainProtocol
import LainTransport

/// The iPad's own settings, changed from the panel and kept in its defaults.
public struct ClientPreferences: Sendable, Equatable {
    /// 1…5; 3 is the default curve's sensitivity.
    public var pointerSpeed = 3 {
        didSet { pointerSpeed = min(max(pointerSpeed, 1), Self.pointerSensitivities.count) }
    }
    /// 1…5; 3 scrolls as far as the fingers move.
    public var scrollSpeed = 3 {
        didSet { scrollSpeed = min(max(scrollSpeed, 1), Self.scrollScales.count) }
    }
    /// Reverses the trackpad's scroll direction (off: as the host's natural scrolling).
    public var reverseScroll = false
    /// What fingers on the screen do.
    public var touchMode = TouchMode.direct
    /// How the iPad reaches a host over Wi-Fi.
    public var wifiPath = WiFiPath.automatic
    /// How video and audio ask the radio for airtime (D34).
    public var radioPriority = NetworkStreamOptions.RadioPriority.standard

    public init() {}

    /// The curve's `sensitivity` for each speed.
    public static let pointerSensitivities = [0.45, 0.6, 0.75, 0.95, 1.2]
    /// The scroll multiplier for each speed.
    public static let scrollScales = [0.5, 0.75, 1.0, 1.4, 2.0]

    public var scrollScale: Double { Self.scrollScales[scrollSpeed - 1] }

    public var curve: AccelerationCurve {
        var c = AccelerationCurve()
        c.sensitivity = Self.pointerSensitivities[pointerSpeed - 1]
        return c
    }

    static let speedKey = "lain.pointerSpeed", scrollKey = "lain.reverseScroll", scrollSpeedKey = "lain.scrollSpeed"
    static let pathKey = "lain.wifiPath", priorityKey = "lain.radioPriority", touchKey = "lain.touchMode"

    public static func load(from defaults: UserDefaults = .standard) -> ClientPreferences {
        var p = ClientPreferences()
        if defaults.object(forKey: speedKey) != nil { p.pointerSpeed = defaults.integer(forKey: speedKey) }
        if defaults.object(forKey: scrollSpeedKey) != nil { p.scrollSpeed = defaults.integer(forKey: scrollSpeedKey) }
        p.reverseScroll = defaults.bool(forKey: scrollKey)
        if let raw = defaults.string(forKey: touchKey), let mode = TouchMode(rawValue: raw) { p.touchMode = mode }
        if let raw = defaults.string(forKey: pathKey), let path = WiFiPath(rawValue: raw) { p.wifiPath = path }
        if let raw = defaults.string(forKey: priorityKey), let priority = NetworkStreamOptions.RadioPriority(rawValue: raw) {
            p.radioPriority = priority
        }
        return p
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(pointerSpeed, forKey: Self.speedKey)
        defaults.set(scrollSpeed, forKey: Self.scrollSpeedKey)
        defaults.set(reverseScroll, forKey: Self.scrollKey)
        defaults.set(touchMode.rawValue, forKey: Self.touchKey)
        defaults.set(wifiPath.rawValue, forKey: Self.pathKey)
        defaults.set(radioPriority.rawValue, forKey: Self.priorityKey)
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
        case pointerSpeed
        case scrollSpeed
        case scrollDirection
        case touchMode
        case wifiPath
        case radioPriority
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
        return rows + [.pointerSpeed, .scrollSpeed, .scrollDirection, .touchMode, .wifiPath, .radioPriority]
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
            return change(rows[selection], by: key.usage == Self.left ? -1 : 1, preferences: preferences)
        case Self.enter, Self.keypadEnter, Self.space:
            return activate(rows[selection], preferences: preferences)
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
        return activate(rows[row], preferences: preferences)
    }

    private func activate(_ row: Row, preferences: ClientPreferences) -> Action {
        switch row {
        case .host(let id): .selectHost(id)
        case .pointerSpeed:
            // Return cycles: up to the fastest, then back to the slowest.
            change(row, by: preferences.pointerSpeed == ClientPreferences.pointerSensitivities.count
                       ? 1 - preferences.pointerSpeed : 1, preferences: preferences)
        case .scrollSpeed:
            change(row, by: preferences.scrollSpeed == ClientPreferences.scrollScales.count
                       ? 1 - preferences.scrollSpeed : 1, preferences: preferences)
        case .scrollDirection, .touchMode, .wifiPath, .radioPriority: change(row, by: 1, preferences: preferences)
        }
    }

    private func change(_ row: Row, by step: Int, preferences: ClientPreferences) -> Action {
        var p = preferences
        switch row {
        case .host: return .none
        case .pointerSpeed: p.pointerSpeed += step
        case .scrollSpeed: p.scrollSpeed += step
        case .scrollDirection: p.reverseScroll.toggle()
        case .touchMode: p.touchMode = Self.cycle(p.touchMode, by: step)
        case .wifiPath: p.wifiPath = Self.cycle(p.wifiPath, by: step)
        case .radioPriority: p.radioPriority = Self.cycle(p.radioPriority, by: step)
        }
        return p == preferences ? .none : .setPreferences(p)
    }

    // MARK: Content

    /// The panel's lines, top to bottom.
    public func lines(info: ClientSession.ConnectionInfo?, video: VideoStats, host: HostStats?,
                      hosts: ClientSession.HostList, preferences: ClientPreferences) -> [Line] {
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
        add("iPad   " + Self.iPadLine(video))
        add("Host   " + Self.hostLine(info: info, host: host), host == nil ? .dim : .text)

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
            case .pointerSpeed:
                add(Self.pad("Pointer speed") + Self.dots(preferences.pointerSpeed, of: ClientPreferences.pointerSensitivities.count),
                    row: i)
            case .scrollSpeed:
                add(Self.pad("Scroll speed") + Self.dots(preferences.scrollSpeed, of: ClientPreferences.scrollScales.count), row: i)
            case .scrollDirection:
                add(Self.pad("Scroll direction") + "‹ " + (preferences.reverseScroll ? "Reversed" : "Natural") + " ›", row: i)
            case .touchMode:
                add(Self.pad("Touch screen") + "‹ " + Self.title(preferences.touchMode) + " ›", row: i)
            case .wifiPath:
                add(Self.pad("Wi-Fi path") + "‹ " + Self.title(preferences.wifiPath) + " ›", row: i)
            case .radioPriority:
                add(Self.pad("Radio priority") + "‹ " + Self.title(preferences.radioPriority) + " ›", row: i)
            case .host:
                break
            }
        }

        add("SHORTCUTS", .heading)
        for (keys, action) in Self.shortcuts { add(Self.pad(keys) + action) }
        add("in this panel: ↑ ↓ select · ← → change · return or click: choose · esc or right ⌥: close", .dim)
        return out
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
        ("touch", "press where you touch · Trackpad: move; tap: click; hold still, then move: drag"),
        ("touch, two fingers", "drag: scroll · tap: right-click"),
    ]

    static func cycle<T: CaseIterable & Equatable>(_ value: T, by step: Int) -> T {
        let all = Array(T.allCases)
        let i = all.firstIndex(of: value) ?? 0
        return all[((i + step) % all.count + all.count) % all.count]
    }

    static func title(_ mode: TouchMode) -> String {
        switch mode {
        case .direct: "Pointer follows your finger"
        case .trackpad: "Trackpad"
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

    static func dots(_ n: Int, of all: Int) -> String {
        "‹ " + String(repeating: "●", count: n) + String(repeating: "○", count: all - n) + " ›"
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
