import LainInput
import LainProtocol

/// The overlay shown while Right Option, lain's system key, is held alone (`ClientInputPipeline.overlayHoldNs`):
/// the link, this iPad's video numbers, the Mac's (v5 `HostStats`, which only the Mac knows), and the
/// settings in effect. Pure: the stream view refreshes it at 4 Hz while it shows.
public enum ClientOverlay {
    /// How often the overlay asks the Mac for `HostStats` while it shows.
    public static let hostStatsIntervalMs: UInt32 = 250

    public struct Section: Sendable, Equatable {
        public var title: String
        public var lines: [String]
        public init(_ title: String, _ lines: [String]) { self.title = title; self.lines = lines }
    }

    /// - Parameters:
    ///   - info: the current link (nil: none).
    ///   - video: this iPad's video numbers.
    ///   - host: the Mac's latest stats (nil: none yet, or a Mac without them).
    ///   - remaps: the remap table in effect.
    public static func sections(info: ClientSession.ConnectionInfo?, video: VideoStats, host: HostStats?,
                                remaps: RemapTable = .default) -> [Section] {
        var out: [Section] = []
        if let info {
            var lines = [ClientStatus.describe(info.transport) + (info.hostName.isEmpty ? "" : " · \(info.hostName)")
                + " · protocol v\(info.protocolVersion)"]
            if let note = ClientStatus.olderMacNote(info) { lines.append(note) }
            out.append(Section("Link", lines))
        } else {
            out.append(Section("Link", ["no link"]))
        }
        out.append(Section("iPad", video.hudText.split(separator: "\n").map(String.init)))
        out.append(Section("Mac", macLines(info: info, host: host)))
        out.append(Section("Settings", settingsLines(info: info, remaps: remaps)))
        return out
    }

    public static func text(_ sections: [Section]) -> String {
        sections.map { s in ([s.title.uppercased()] + s.lines.map { "  " + $0 }).joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    static func macLines(info: ClientSession.ConnectionInfo?, host: HostStats?) -> [String] {
        guard let info else { return ["–"] }
        guard ProtocolFeature.hostStats.isSupported(at: info.protocolVersion) else {
            return ["update lain on the Mac for its video stats"]
        }
        guard let h = host else { return ["waiting for the Mac…"] }
        return [
            "encode \(ms(h.encodeP50Us))/\(ms(h.encodeP95Us)) ms · ack RTT \(ms(h.ackRttP50Us))/\(ms(h.ackRttP95Us)) ms"
                + String(format: " · %.1f Mbps", Double(h.bitsPerSecond) / 1e6),
            "in flight \(h.inFlight) (peak \(h.peakInFlight)) · dropped before encode \(h.droppedBeforeEncode)"
                + " · encode failures \(h.encodeFailures)",
            "captured \(h.captured) · encoded \(h.encoded) · sent \(h.sent) · keyframes \(h.keyframes)"
                + " · refinements \(h.refinements)",
        ]
    }

    static func settingsLines(info: ClientSession.ConnectionInfo?, remaps: RemapTable) -> [String] {
        var lines = [
            "Right Option: lain's system key · hold: this overlay · tap: Mission Control",
            "  + a key: Command · ↑/↓: Mission Control / App Exposé · ←/→: previous / next Space",
            "Left Option: Option",
        ]
        let enabled = remaps.entries.filter(\.isEnabled).map(\.name)
        if !enabled.isEmpty { lines.append("Remapped here (Right Option → Command): " + enabled.joined(separator: ", ")) }
        lines.append("HUD: Ctrl-Opt-Cmd-L")
        if let source = info?.macInputSource, !source.isEmpty { lines.append("Mac input source: \(source)") }
        return lines
    }

    static func ms(_ us: UInt32) -> String {
        us == HostStats.none ? "–" : String(format: "%.1f", Double(us) / 1000)
    }
}
