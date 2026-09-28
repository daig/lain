import LainProtocol

/// What the client's connect screen shows (§6.6). Grows into ClientSession's state (§6.1).
public enum ClientStatus: Sendable, Equatable {
    case waitingForMac
    case connected(framesReceived: Int)
    case failed(String)

    public init(_ endpoint: ClientEndpoint.Status) {
        switch endpoint {
        case .listening: self = .waitingForMac
        case .connected(let n): self = .connected(framesReceived: n)
        }
    }

    public var title: String {
        switch self {
        case .waitingForMac: "Waiting for Mac"
        case .connected: "Connected to Mac"
        case .failed: "Can't listen for the Mac"
        }
    }

    public var detail: String {
        switch self {
        case .waitingForMac: "Connect your iPad to the Mac with a USB-C cable"
        case .connected(let n): n == 0 ? "Link up" : "\(n) test frames received"
        case .failed(let why): why
        }
    }
}
