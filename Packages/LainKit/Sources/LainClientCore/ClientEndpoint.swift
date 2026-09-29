import Dispatch
import LainProtocol
import LainTelemetry
import LainTransport
import Synchronization

/// The client's end of the USB link for M1 (§6.1): the loopback listener, `Hello` on each new link,
/// and a responder that answers pings and acks video frames as soon as they arrive (enough for
/// `--bench usbmux`, S1). ClientSession grows from this in M2/M3.
public final class ClientEndpoint: Sendable {
    public enum Status: Sendable, Equatable {
        case listening(port: UInt16)
        case connected(framesReceived: Int)
    }

    public let port: UInt16
    private let listener: ClientLinkListener
    private let current: CurrentLink

    /// `port` nil: `LainProtocol.usbPort`; 0 picks an ephemeral port (tests).
    public init(port: UInt16? = nil, secrets: some SecretStore, hello: Hello,
                onStatus: @escaping @Sendable (Status) -> Void) throws {
        let port = port ?? LainProtocol.usbPort
        let current = CurrentLink()
        self.current = current
        let log = Telemetry.logger("client")
        listener = try ClientLinkListener(port: port, secrets: secrets, acceptsPairing: true) { link in
            let previous = current.state.withLock { c in
                defer { c = link }
                return c
            }
            previous?.close()
            let frames = Atomic<Int>(0)
            let listening = Status.listening(port: port)
            link.realtime.setHandler { env in
                switch env.message {
                case .ping(let p):
                    let now = MonotonicClock.now()
                    link.realtime.send(.pong(Pong(id: p.id, pingSentAtNs: p.sentAtNs, receivedAtNs: now, sentAtNs: MonotonicClock.now())))
                case .helloAck(let ack):
                    log.notice("HelloAck: \(ack.displayPointWidth)×\(ack.displayPointHeight) pt, input source \(ack.macInputSource, privacy: .public)")
                default:
                    break
                }
            }
            link.video.setHandler { env in
                guard case .videoFrame(let f) = env.message else { return }
                link.video.send(.frameAck(FrameAck(frameId: f.frameId, receivedAtNs: MonotonicClock.now(), bytes: UInt32(f.data.count))))
                let n = frames.add(1, ordering: .relaxed).newValue
                if n % 30 == 0 { onStatus(.connected(framesReceived: n)) }
            }
            link.audio.setHandler { _ in }
            link.realtime.setCloseHandler { _ in
                let isCurrent = current.state.withLock { c in
                    guard c?.sessionToken == link.sessionToken else { return false }
                    c = nil
                    return true
                }
                if isCurrent { link.close(); onStatus(listening) }
            }
            link.realtime.send(.hello(hello))
            onStatus(.connected(framesReceived: 0))
        }
        self.port = listener.port
        onStatus(.listening(port: listener.port))
    }

    public func stop() {
        listener.cancel()
        current.state.withLock { c in c?.close(); c = nil }
    }
}

private final class CurrentLink: Sendable {
    let state = Mutex<Link?>(nil)
}
