import Dispatch
import LainProtocol
import Testing
@testable import LainTransport

@Suite struct Streams {
    @Test func memoryPairDeliversInOrderIncludingBeforeStart() async {
        let (a, b) = MemoryStream.pair()
        a.write([1, 2])
        a.write([3])
        let got = Inbox<[UInt8]>()
        let closed = Inbox<Bool>()
        b.start(queue: DispatchQueue(label: "t"), onBytes: { got.put($0) }, onClose: { _ in closed.put(true) })
        a.write([4])
        #expect(await got.next() == [1, 2])
        #expect(await got.next() == [3])
        #expect(await got.next() == [4])
        a.close()
        #expect(await closed.next() == true)
        #expect(b.bytesDelivered == 4)
    }

    @Test func socketLoopbackCarriesLargeWritesIntact() async throws {
        let accepted = Inbox<SocketStream>()
        let listener = try TCPListener(port: 0, queue: DispatchQueue(label: "l")) { accepted.put($0) }
        defer { listener.cancel() }
        let client = try TCP.connectLoopback(port: listener.port)
        let server = try #require(await accepted.next())
        let received = Inbox<Int>()
        let total = 5 * 1024 * 1024
        let payload = (0..<total).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let collected = LockedBytes()
        server.start(queue: DispatchQueue(label: "s"), onBytes: { bytes in
            if collected.append(bytes) == total { received.put(total) }
        }, onClose: { _ in })
        client.start(queue: DispatchQueue(label: "c"), onBytes: { _ in }, onClose: { _ in })
        for chunk in stride(from: 0, to: total, by: 700_000) { client.write(Array(payload[chunk..<min(chunk + 700_000, total)])) }
        #expect(await received.next(within: 10) == total)
        #expect(collected.bytes == payload)
        server.close()
        client.close()
    }

    @Test func remoteCloseIsReported() async throws {
        let accepted = Inbox<SocketStream>()
        let listener = try TCPListener(port: 0, queue: DispatchQueue(label: "l")) { accepted.put($0) }
        defer { listener.cancel() }
        let client = try TCP.connectLoopback(port: listener.port)
        let server = try #require(await accepted.next())
        let closed = Inbox<Bool>()
        client.start(queue: DispatchQueue(label: "c"), onBytes: { _ in }, onClose: { closed.put($0 == nil) })
        server.start(queue: DispatchQueue(label: "s"), onBytes: { _ in }, onClose: { _ in })
        server.close()
        #expect(await closed.next() == true)
    }

    @Test func sendBufferCanBeKeptSmall() throws {
        let listener = try TCPListener(port: 0, queue: DispatchQueue(label: "l")) { _ in }
        defer { listener.cancel() }
        let client = try TCP.connectLoopback(port: listener.port)
        client.setSendBufferSize(HostLink.videoSendBuffer)
        #expect(client.sendBufferSize == HostLink.videoSendBuffer)
        client.close()
    }
}

final class LockedBytes: @unchecked Sendable {
    private let lock = NSLockish()
    private var storage: [UInt8] = []
    func append(_ b: [UInt8]) -> Int { lock.with { storage += b; return storage.count } }
    var bytes: [UInt8] { lock.with { storage } }
}

import Synchronization
final class NSLockish: Sendable {
    private let m = Mutex<Void>(())
    func with<R>(_ body: () -> R) -> R { m.withLock { _ in body() } }
}

@Suite struct Channels {
    func pair() -> (MessageChannel, MessageChannel) {
        let (a, b) = MemoryStream.pair()
        let ca = MessageChannel(stream: a, label: "a", version: LainProtocol.newestVersion)
        let cb = MessageChannel(stream: b, label: "b", version: LainProtocol.newestVersion)
        ca.start(); cb.start()
        return (ca, cb)
    }

    @Test func buffersUntilAHandlerIsSetAndCountsSequence() async {
        let (a, b) = pair()
        for i in 0..<3 { a.send(.ping(Ping(id: UInt32(i), sentAtNs: 0))) }
        let got = Inbox<Envelope>()
        try? await Task.sleep(for: .milliseconds(20))
        b.setHandler { got.put($0) }
        for i in 0..<3 {
            let env = await got.next()
            #expect(env?.message == .ping(Ping(id: UInt32(i), sentAtNs: 0)))
            #expect(env?.header.sequence == UInt32(i))
        }
    }

    @Test func receiveOnceTakesExactlyOne() async throws {
        let (a, b) = pair()
        a.send(.ping(Ping(id: 1, sentAtNs: 0)))
        a.send(.releaseAll(ReleaseAll(reason: .focusLost)))
        let first = try await b.next(timeoutSeconds: 2)
        #expect(first.message == .ping(Ping(id: 1, sentAtNs: 0)))
        let second = try await b.next(timeoutSeconds: 2)
        #expect(second.message == .releaseAll(ReleaseAll(reason: .focusLost)))
        await #expect(throws: TransportError.timeout) { try await b.next(timeoutSeconds: 0.05) }
    }

    @Test func garbageClosesTheChannel() async {
        let (a, b) = MemoryStream.pair()
        let cb = MessageChannel(stream: b, label: "b")
        let closed = Inbox<Bool>()
        cb.setCloseHandler { _ in closed.put(true) }
        cb.start()
        a.start(queue: DispatchQueue(label: "a"), onBytes: { _ in }, onClose: { _ in })
        a.write([UInt8](repeating: 0xEE, count: 64))
        #expect(await closed.next() == true)
    }
}

/// A channel takes only frames in its layer: handshake frames until `setVersion`, then that version's.
@Suite struct ChannelVersions {
    func closeError(of channel: MessageChannel) async -> (any Error)? {
        let closed = Inbox<String>()
        channel.setCloseHandler { closed.put(String(describing: $0)) }
        return await closed.next().map { TransportError.unexpectedMessage($0) }
    }

    @Test func aChannelSwitchesFromTheHandshakeToItsVersion() async throws {
        let (a, b) = MemoryStream.pair()
        let ca = MessageChannel(stream: a, label: "a"), cb = MessageChannel(stream: b, label: "b")
        ca.start(); cb.start()
        let accept = ChannelAccept(chosen: 3, versions: VersionList.supported)
        #expect(ca.send(.channelAccept(accept)))
        ca.setVersion(3)
        ca.send(.ping(Ping(id: 1, sentAtNs: 0)))
        let first = try await cb.next(timeoutSeconds: 2)
        #expect(first.header.version == LainProtocol.handshakeVersion && first.message == .channelAccept(accept))
        cb.setVersion(3)   // before reading the session frame that follows
        let second = try await cb.next(timeoutSeconds: 2)
        #expect(second.header.version == 3 && second.message == .ping(Ping(id: 1, sentAtNs: 0)))
    }

    @Test func aFrameInAnotherVersionClosesTheChannel() async {
        let (a, b) = MemoryStream.pair()
        let ca = MessageChannel(stream: a, label: "a", version: 4), cb = MessageChannel(stream: b, label: "b", version: 3)
        ca.start(); cb.start()
        let closed = Inbox<String>()
        cb.setCloseHandler { closed.put(String(describing: $0)) }
        cb.setHandler { _ in Issue.record("delivered a v4 frame on a v3 channel") }
        ca.send(.ping(Ping(id: 1, sentAtNs: 0)))
        #expect(await closed.next()?.contains("a ping frame in v4 on a channel at v3") == true)
    }

    @Test func aSessionFrameBeforeTheVersionIsSetClosesTheChannel() async {
        let (a, b) = MemoryStream.pair()
        let ca = MessageChannel(stream: a, label: "a", version: 3), cb = MessageChannel(stream: b, label: "b")
        ca.start(); cb.start()
        let closed = Inbox<String>()
        cb.setCloseHandler { closed.put(String(describing: $0)) }
        cb.setHandler { _ in Issue.record("delivered a session frame during the handshake") }
        ca.send(.ping(Ping(id: 1, sentAtNs: 0)))
        #expect(await closed.next()?.contains("on a channel at the handshake") == true)
    }
}

@Suite struct AckWindow {
    @Test func gatesOnInFlightCount() {
        var w = FrameAckWindow(maxInFlight: 2)
        #expect(w.canSend)
        w.sent(frameId: 1, bytes: 100, at: 0)
        w.sent(frameId: 2, bytes: 200, at: 10)
        #expect(!w.canSend)
        #expect(w.acked(frameId: 1, at: 50) == .init(frameId: 1, roundTripNs: 50, bytes: 100))
        #expect(w.canSend && w.inFlightCount == 1)
    }

    @Test func ackRetiresOlderFramesAndIgnoresUnknown() {
        var w = FrameAckWindow(maxInFlight: 3)
        for i in 1...3 { w.sent(frameId: UInt32(i), bytes: 1, at: 0) }
        #expect(w.acked(frameId: 3, at: 9)?.frameId == 3)
        #expect(w.inFlightCount == 0)
        #expect(w.acked(frameId: 2, at: 10) == nil)
        w.sent(frameId: 4, bytes: 1, at: 0)
        w.reset()
        #expect(w.inFlightCount == 0)
    }
}

@Suite struct Secrets {
    @Test func inMemory() {
        let s = InMemorySecretStore()
        #expect(s.secret(for: "p") == nil)
        s.setSecret([1, 2], for: "p")
        #expect(s.secret(for: "p") == [1, 2])
        s.removeSecret(for: "p")
        #expect(s.secret(for: "p") == nil)
    }

    // KeychainSecretStore is not tested here: unhosted package test bundles have no application
    // identifier, so the Keychain returns -34018 (errSecMissingEntitlement) on the Mac and on the
    // iPad simulator alike. It needs an app-hosted test target (Apps/ClientTests, §12.2 layer 4).

    @Test func hmacCoversKindAndToken() {
        let secret = ChannelAuth.randomBytes(32)
        let token = ChannelAuth.randomBytes(16)
        let hello = ChannelAuth.hello(kind: .video, token: token, secret: secret)
        #expect(ChannelAuth.isValid(hello, secret: secret))
        #expect(!ChannelAuth.isValid(hello, secret: ChannelAuth.randomBytes(32)))
        var other = hello
        other.connectionKind = .audio
        #expect(!ChannelAuth.isValid(other, secret: secret))
        other = hello
        other.sessionToken[0] ^= 1
        #expect(!ChannelAuth.isValid(other, secret: secret))
        other = hello   // the offered versions are covered too: a downgrade can't be slipped in
        other.versions = other.versions.capped(at: other.versions.oldest)
        #expect(other.versions != hello.versions && !ChannelAuth.isValid(other, secret: secret))
        #expect(ChannelAuth.hello(kind: .realtime, token: token, secret: nil).hmac == ChannelAuth.pairingMAC)
    }
}
