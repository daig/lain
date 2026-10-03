import LainProtocol
import LainTransport

/// What the host's status menu shows: `HostSession`'s state (§5.7).
public enum HostStatus: Sendable, Equatable {
    /// No iPad on USB.
    case waitingForIPad
    /// An iPad is attached; dialing lain on it (it must be open in the foreground, §7.2).
    case connecting
    /// A session is up, over USB or Wi-Fi (§7.7).
    case connected(deviceModel: String, via: LinkTransport = .usb)
    /// usbmuxd is unreachable, lain on the iPad speaks another protocol, or similar; the session retries
    /// on its own.
    case error(String)

    /// lain on the iPad shares no protocol version with this one (PROTOCOL-VERSIONING §8): which side to
    /// update.
    public static func versionGap(_ gap: VersionGap) -> HostStatus {
        switch gap {
        case .peerOlder(let peer):
            .error("lain on the iPad is too old (it speaks \(peer), this Mac protocol \(VersionList.offered)): update it")
        case .peerNewer(let peer):
            .error("lain on the iPad is newer (it speaks \(peer), this Mac protocol \(VersionList.offered)): update lain on this Mac")
        case .differentBuilds(let version):
            .error("the iPad runs a different development build of protocol v\(version): update both from the same tree")
        }
    }

    /// lain on the iPad keeps closing the link right after `ChannelHello` without a word: a very old app
    /// (v1) that can't parse it.
    public static let iPadNeedsUpdate = versionGap(olderAppGap)
    static let olderAppGap = VersionGap.peerOlder(peer: "an older protocol")

    /// Video capture stopped on its own in several sessions in a row: the attached iPad is dialed again
    /// once the backoff is over (`HostSession.Tuning.captureRetryInterval`), or at once if it is replugged.
    public static let captureBackingOff = HostStatus.error("backing off after capture failures")

    public var title: String {
        switch self {
        case .waitingForIPad: "Waiting for iPad"
        case .connecting: "iPad attached: open lain on the iPad"
        case .connected(let model, let transport): "Connected to \(model) over \(transport.menuName)"
        case .error(let why): "Error: \(why)"
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// "Protocol v3–v4" (what this Mac offers).
    public static var protocolDescription: String { "Protocol \(VersionList.offered)" }
}

extension LinkTransport {
    /// For the menu: "USB", "Wi-Fi (AWDL)" (peer-to-peer, no router) or "Wi-Fi (LAN, en1)".
    var menuName: String {
        switch self {
        case .usb: "USB"
        case .network(_, peerToPeer: true): "Wi-Fi (AWDL)"
        case .network(let interface?, peerToPeer: false): "Wi-Fi (LAN, \(interface))"
        case .network(nil, peerToPeer: false): "Wi-Fi (LAN)"
        }
    }
}

/// The host's Wi-Fi listener as the menu shows it (§7.7 D29 decision 9).
public enum HostWiFiStatus: Sendable, Equatable {
    /// Not listening: Wi-Fi isn't enabled, no iPad has paired over USB yet, the pairing secrets can't
    /// be read (retrying), or the network isn't there.
    case off(String)
    /// The listener is starting.
    case starting
    /// Listening on `port` with one PSK per paired iPad, advertised as `name` (nil: not advertised, or
    /// Bonjour hasn't confirmed the name yet).
    case advertising(name: String?, port: UInt16, pairedCount: Int)
    /// Local Network access is off for lain.
    case denied
    /// The listener failed; it restarts with backoff.
    case failed(String)

    public var title: String {
        switch self {
        case .off(let why): "Wi-Fi: off: \(why)"
        case .starting: "Wi-Fi: starting…"
        case .advertising(let name?, _, let n): "Wi-Fi: advertising as \(name) with \(Self.paired(n))"
        case .advertising(nil, let port, let n): "Wi-Fi: listening on port \(port) with \(Self.paired(n))"
        case .denied: "Wi-Fi blocked: allow lain in System Settings › Privacy & Security › Local Network"
        case .failed(let why): "Wi-Fi failed: \(why); retrying"
        }
    }

    private static func paired(_ n: Int) -> String { n == 1 ? "1 paired iPad" : "\(n) paired iPads" }
}
