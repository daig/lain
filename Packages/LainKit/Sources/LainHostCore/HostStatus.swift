import LainProtocol

/// What the host's status menu shows: `HostSession`'s state (§5.7).
public enum HostStatus: Sendable, Equatable {
    /// No iPad on USB.
    case waitingForIPad
    /// An iPad is attached; dialing lain on it (it must be open in the foreground, §7.2).
    case connecting
    /// A session is up.
    case connected(deviceModel: String)
    /// usbmuxd is unreachable or similar; the session retries on its own.
    case error(String)

    public var title: String {
        switch self {
        case .waitingForIPad: "Waiting for iPad"
        case .connecting: "iPad attached: open lain on the iPad"
        case .connected(let model): "Connected to \(model)"
        case .error(let why): "Error: \(why)"
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public static let protocolDescription = "Protocol v\(LainProtocol.majorVersion)"
}
