import LainProtocol

/// What the host's status menu shows. Grows into HostSession's state (§5.7).
public enum HostStatus: Sendable, Equatable {
    case waitingForIPad

    public var title: String {
        switch self {
        case .waitingForIPad: "Waiting for iPad"
        }
    }

    public static let protocolDescription = "Protocol v\(LainProtocol.majorVersion)"
}
