import Dispatch
import LainProtocol

/// A reliable, ordered byte pipe: a TCP socket, a usbmuxd pipe, or an in-memory pair (§7.1).
/// Received bytes and the close notification are delivered on the queue passed to `start`, in order.
public protocol ByteStream: AnyObject, Sendable {
    /// Begins delivery. Call once.
    func start(queue: DispatchQueue, onBytes: @escaping @Sendable ([UInt8]) -> Void,
               onClose: @escaping @Sendable ((any Error)?) -> Void)
    /// Queues bytes for sending; never blocks the caller.
    func write(_ bytes: [UInt8])
    /// Closes after already-queued writes have been sent.
    func close()
}

public enum TransportError: Error, Equatable, Sendable {
    case posix(String, Int32)
    case closed
    case timeout
    case authenticationFailed
    /// The peer runs a lain from before version negotiation (legacy): `remote` is its version when its
    /// frame named one, 0 when it answered ours with `Error(versionMismatch)`.
    case versionMismatch(remote: UInt8)
    /// Both sides negotiate, but no version is common to both (PROTOCOL-VERSIONING §3.2).
    case noCommonVersion(local: VersionList, peer: VersionList)
    case unexpectedMessage(String)
    case noSecret
}
