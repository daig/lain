import LainProtocol
import LainTransport

/// What the client's screen shows (§6.6, §7.7).
public enum ClientStatus: Sendable, Equatable {
    /// No link; `wifi`: the session also looks for paired Macs over Wi-Fi.
    case waitingForMac(wifi: Bool)
    case searching
    /// A lain Mac this iPad has no Wi-Fi secret for: one USB session records it.
    case needsCable(hostName: String)
    /// A Mac shares no lain protocol version with this iPad (nil name: the one on the cable); `gap` says
    /// which side needs an update.
    case versionMismatch(hostName: String?, gap: VersionGap)
    case localNetworkDenied
    case hostBusy(hostName: String)
    /// The Mac's Wi-Fi listener doesn't hold this iPad's key: one USB session pairs again.
    case pairingRefused(hostName: String)
    case connecting(hostName: String, interfaces: [String])
    case connected(framesReceived: Int)
    /// A session is up (`ClientSession`); input flows once `info.isConfigured`.
    case session(ClientSession.ConnectionInfo)
    case failed(String)

    public init(_ endpoint: ClientEndpoint.Status) {
        switch endpoint {
        case .listening: self = .waitingForMac(wifi: false)
        case .connected(let n): self = .connected(framesReceived: n)
        }
    }

    public init(_ session: ClientSession.Status) {
        switch session {
        case .listening(_, let wifi): self = .waitingForMac(wifi: wifi)
        case .searching: self = .searching
        case .needsCable(let name): self = .needsCable(hostName: name)
        case .versionMismatch(let name, let gap): self = .versionMismatch(hostName: name, gap: gap)
        case .localNetworkDenied: self = .localNetworkDenied
        case .hostBusy(let name): self = .hostBusy(hostName: name)
        case .pairingRefused(let name): self = .pairingRefused(hostName: name)
        case .connecting(let name, let interfaces): self = .connecting(hostName: name, interfaces: interfaces)
        case .connected(let info): self = .session(info)
        }
    }

    public var isConnected: Bool {
        switch self {
        case .connected, .session: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .waitingForMac: "Waiting for Mac"
        case .searching: "Searching over Wi-Fi…"
        case .needsCable(let name): "Found \(name)"
        case .versionMismatch(let name, _): "\(name ?? "The Mac") runs another lain"
        case .localNetworkDenied: "Local Network access is off"
        case .hostBusy(let name): "\(name) is busy"
        case .pairingRefused(let name): "\(name) doesn't recognize this iPad"
        case .connecting(let name, _): "Connecting to \(name)"
        case .connected: "Connected to Mac"
        case .session(let info): "Connected to \(info.hostName.isEmpty ? "Mac" : info.hostName)"
        case .failed: "Can't listen for the Mac"
        }
    }

    public var detail: String {
        switch self {
        case .waitingForMac(let wifi):
            wifi ? Self.connectHint : "Connect your iPad to the Mac with a USB-C cable"
        case .searching:
            Self.connectHint
        case .needsCable:
            "Connect the cable once to use it over Wi-Fi"
        case .versionMismatch(_, .peerOlder(let peer)):
            "It speaks \(peer), this iPad protocol \(VersionList.offered): update lain on the Mac"
        case .versionMismatch(_, .peerNewer(let peer)):
            "It speaks \(peer), this iPad protocol \(VersionList.offered): update lain on this iPad"
        case .versionMismatch(_, .differentBuilds(let version)):
            "It runs a different development build of protocol v\(version): update both from the same tree"
        case .localNetworkDenied:
            "Allow lain in Settings › Privacy & Security › Local Network, or connect the cable"
        case .hostBusy:
            "It has another session (a cable connection wins); trying again shortly"
        case .pairingRefused:
            "Connect the USB-C cable once to pair again"
        case .connecting(_, let interfaces):
            "over Wi-Fi" + (interfaces.isEmpty ? "" : " (\(interfaces.joined(separator: ", ")))")
        case .connected(let n):
            n == 0 ? "Link up" : "\(n) test frames received"
        case .session(let info):
            Self.describe(info.transport) + " · " + (!info.isConfigured ? "Link up, waiting for the Mac's settings"
                : "Mac display \(info.displayPointWidth)×\(info.displayPointHeight) pt · input source "
                    + (info.macInputSource.split(separator: ".").last.map(String.init) ?? info.macInputSource)
                    + (info.framesReceived > 0 ? " · \(info.framesReceived) frames" : ""))
                + (info.setup.flatMap(Self.setupHint).map { "\n" + $0 } ?? "")
                + (Self.olderMacNote(info).map { "\n" + $0 } ?? "")
        case .failed(let why):
            why
        }
    }

    /// What the Mac still needs before the session fully works (v4 `HostSetup`), and where to do it; nil
    /// when nothing is missing.
    public static func setupHint(_ setup: HostSetup) -> String? {
        let names: [HostSetup.Requirement: String] = [.screenRecording: "Screen Recording", .accessibility: "Accessibility",
                                                      .localNetwork: "Local Network", .startAtLogin: "Start at Login"]
        let missing = setup.missing.compactMap { names[$0] }
        guard !missing.isEmpty || !setup.videoProblem.isEmpty else { return nil }
        let what = missing.isEmpty ? "No video: \(setup.videoProblem)" : "Finish setup on the Mac: allow " + missing.joined(separator: ", ")
        let where_ = setup.hasOtherDisplay ? "use the Mac's own display, keyboard and mouse"
            : "this Mac has no other display: attach one (or use Screen Sharing) to finish"
        return what + " (" + where_ + ")"
    }

    /// The Mac's lain is older but compatible: what updating it adds (PROTOCOL-VERSIONING §8).
    public static func olderMacNote(_ info: ClientSession.ConnectionInfo) -> String? {
        let missing = info.olderMacMisses
        guard !missing.isEmpty else { return nil }
        return "The Mac's lain is older (protocol v\(info.protocolVersion)): update it for "
            + missing.map(\.summary).joined(separator: ", ")
    }

    /// For the connect screen and the HUD: "USB", "Wi-Fi · AWDL awdl0", "Wi-Fi · LAN en1".
    public static func describe(_ transport: LinkTransport) -> String {
        switch transport {
        case .usb:
            return "USB"
        case .network(let interface, let peerToPeer):
            let path = !peerToPeer ? "LAN" : interface?.hasPrefix("awdl") == true ? "AWDL" : "peer-to-peer"
            return "Wi-Fi · " + path + (interface.map { " " + $0 } ?? "")
        }
    }

    private static let connectHint = "Connect the USB-C cable, or keep the iPad near a paired Mac with Wi-Fi on"
}
