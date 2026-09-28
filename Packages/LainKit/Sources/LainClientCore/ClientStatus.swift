import LainProtocol

/// What the client's connect screen shows (§6.6). Grows into ClientSession's state (§6.1).
public enum ClientStatus: Sendable, Equatable {
    case waitingForMac

    public var title: String {
        switch self {
        case .waitingForMac: "Waiting for Mac"
        }
    }

    public var detail: String {
        switch self {
        case .waitingForMac: "Connect your iPad to the Mac with a USB-C cable"
        }
    }
}
