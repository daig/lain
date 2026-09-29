import Dispatch
import LainProtocol
import LainTelemetry
import LainTransport
import Synchronization

/// The client's session (§6.1), superseding `ClientEndpoint` for the app: the loopback listener the Mac
/// dials, `Hello` on each new link, `HelloAck` applied to the input pipeline, input out on the
/// realtime channel, `CursorWarp` in, ping/pong, and frame acks (so `--bench usbmux` keeps working).
///
/// Invariant 4: when a link closes, or a new link replaces it, the pipeline forgets everything held
/// locally (the host releases on its side when the link drops).
public final class ClientSession: Sendable {
    public struct ConnectionInfo: Sendable, Equatable {
        public var displayPointWidth: UInt32 = 0
        public var displayPointHeight: UInt32 = 0
        public var macInputSource = ""
        public var framesReceived = 0
        /// `HelloAck` arrived and was applied; input flows.
        public var isConfigured = false
        public init() {}
    }

    public enum Status: Sendable, Equatable {
        case listening(port: UInt16)
        case connected(ConnectionInfo)
    }

    public let port: UInt16
    public let input: ClientInput
    private let listener: ClientLinkListener
    private let current: CurrentLink

    /// - Parameters:
    ///   - port: 47800 on the iPad; 0 in tests (the bound port is `port`).
    ///   - onStatus: called from the link's queues; hop to the main actor for UI.
    public init(port: UInt16 = LainProtocol.usbPort, secrets: some SecretStore, hello: Hello,
                input: ClientInput = ClientInput(), onStatus: @escaping @Sendable (Status) -> Void) throws {
        let current = CurrentLink()
        self.current = current
        self.input = input
        let log = Telemetry.logger("client")
        listener = try ClientLinkListener(port: port, secrets: secrets, acceptsPairing: true) { link in
            let previous = current.replace(with: link)
            if let previous {
                input.disconnect()   // transport switch: nothing stays held from the old link
                previous.close()
            }
            let info = Mutex(ConnectionInfo())
            let frames = Atomic<Int>(0)
            let publish: @Sendable () -> Void = { onStatus(.connected(info.withLock { $0 })) }

            let control: @Sendable (Envelope) -> Void = { env in
                switch env.message {
                case .ping(let p):
                    let received = MonotonicClock.now()
                    link.realtime.send(.pong(Pong(id: p.id, pingSentAtNs: p.sentAtNs, receivedAtNs: received,
                                                  sentAtNs: MonotonicClock.now())))
                case .helloAck(let ack):
                    log.notice("HelloAck: \(ack.displayPointWidth)×\(ack.displayPointHeight) pt, input source \(ack.macInputSource, privacy: .public)")
                    guard current.isCurrent(link) else { return }
                    input.configure(ack)
                    let realtime = link.realtime
                    input.connect { realtime.send($0) }
                    info.withLock { i in
                        i.displayPointWidth = ack.displayPointWidth
                        i.displayPointHeight = ack.displayPointHeight
                        i.macInputSource = ack.macInputSource
                        i.isConfigured = true
                    }
                    publish()
                case .cursorWarp(let w):
                    input.warp(x: w.x, y: w.y)
                default:
                    break
                }
            }
            link.realtime.setHandler(control)
            link.video.setHandler { env in
                guard case .videoFrame(let f) = env.message else { return control(env) }
                link.video.send(.frameAck(FrameAck(frameId: f.frameId, receivedAtNs: MonotonicClock.now(),
                                                   bytes: UInt32(f.data.count))))
                let n = frames.add(1, ordering: .relaxed).newValue
                if n % 30 == 0 {
                    info.withLock { $0.framesReceived = n }
                    publish()
                }
            }
            link.audio.setHandler { _ in }
            link.realtime.setCloseHandler { _ in
                guard current.clear(ifCurrent: link) else { return }
                input.disconnect()
                link.close()
                onStatus(.listening(port: current.port))
            }
            link.realtime.send(.hello(hello))
            publish()
        }
        self.port = listener.port
        current.port = listener.port
        onStatus(.listening(port: listener.port))
    }

    public func stop() {
        listener.cancel()
        if let link = current.replace(with: nil) {
            input.disconnect()
            link.close()
        }
    }
}

private final class CurrentLink: Sendable {
    private let state = Mutex<Link?>(nil)
    private let boundPort = Atomic<UInt16>(0)

    var port: UInt16 {
        get { boundPort.load(ordering: .relaxed) }
        set { boundPort.store(newValue, ordering: .relaxed) }
    }

    func replace(with link: Link?) -> Link? {
        state.withLock { c in
            defer { c = link }
            return c
        }
    }

    func isCurrent(_ link: Link) -> Bool {
        state.withLock { $0?.sessionToken == link.sessionToken }
    }

    func clear(ifCurrent link: Link) -> Bool {
        state.withLock { c in
            guard c?.sessionToken == link.sessionToken else { return false }
            c = nil
            return true
        }
    }
}
