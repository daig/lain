import LainProtocol

/// What the client's screen shows (§6.6).
public enum ClientStatus: Sendable, Equatable {
    case waitingForMac
    case connected(framesReceived: Int)
    /// A session is up (`ClientSession`); input flows once `info.isConfigured`.
    case session(ClientSession.ConnectionInfo)
    case failed(String)

    public init(_ endpoint: ClientEndpoint.Status) {
        switch endpoint {
        case .listening: self = .waitingForMac
        case .connected(let n): self = .connected(framesReceived: n)
        }
    }

    public init(_ session: ClientSession.Status) {
        switch session {
        case .listening: self = .waitingForMac
        case .connected(let info): self = .session(info)
        }
    }

    public var isConnected: Bool {
        switch self {
        case .connected, .session: true
        case .waitingForMac, .failed: false
        }
    }

    public var title: String {
        switch self {
        case .waitingForMac: "Waiting for Mac"
        case .connected, .session: "Connected to Mac"
        case .failed: "Can't listen for the Mac"
        }
    }

    public var detail: String {
        switch self {
        case .waitingForMac: "Connect your iPad to the Mac with a USB-C cable"
        case .connected(let n): n == 0 ? "Link up" : "\(n) test frames received"
        case .session(let info):
            if !info.isConfigured { "Link up, waiting for the Mac's settings" }
            else {
                "Mac display \(info.displayPointWidth)×\(info.displayPointHeight) pt · input source "
                    + (info.macInputSource.split(separator: ".").last.map(String.init) ?? info.macInputSource)
                    + (info.framesReceived > 0 ? " · \(info.framesReceived) frames" : "")
            }
        case .failed(let why): why
        }
    }
}
