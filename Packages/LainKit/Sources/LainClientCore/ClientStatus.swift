import LainProtocol
import LainTransport

/// What the client's screen shows (§6.6, §7.7).
public enum ClientStatus: Sendable, Equatable {
    /// No link; `wifi`: the session also looks for paired Macs over Wi-Fi.
    case waitingForMac(wifi: Bool)
    case searching
    /// A lain Mac this iPad has no Wi-Fi secret for: one USB session records it.
    case needsCable(hostName: String)
    /// A Mac runs another lain protocol version (nil name: the one on the cable); the older side needs
    /// an update.
    case versionMismatch(hostName: String?, remote: UInt8?)
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
        case .versionMismatch(let name, let remote): self = .versionMismatch(hostName: name, remote: remote)
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
        case .versionMismatch(_, let remote):
            "It speaks protocol " + (remote.map { "v\($0)" } ?? "unknown") + ", this iPad v\(LainProtocol.majorVersion): "
                + (remote.map { $0 < LainProtocol.majorVersion ? "update lain on the Mac" : "update lain on this iPad" }
                    ?? "update the older one")
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
        case .failed(let why):
            why
        }
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
