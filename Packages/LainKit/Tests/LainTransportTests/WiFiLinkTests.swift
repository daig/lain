import Dispatch
import Foundation
import LainProtocol
import Network
import Testing
@testable import LainTransport

// A Wi-Fi link end to end over loopback (§7.7 D29): the client role (`LinkDialer` over a `WiFiLinkDialer`
// holding one pairing's PSK) dials the host role (`LinkAcceptor` fed by a `NetworkStreamListener` holding
// every paired iPad's PSK). Loopback only: never advertised, nothing browses. Not macOS-only: on the
// iOS simulator this is the iPad's TLS client.

/// The host's Wi-Fi side as the host builds it: a TLS-PSK listener with one PSK per stored iPad secret,
/// feeding one acceptor whose candidates are every stored secret (no primary account), pairing refused.
final class WiFiHost: Sendable {
    let secrets: ScriptedSecrets
    let accepted: Inbox<AcceptedLink>
    /// The acceptor's refusals (after TLS, at `ChannelHello`).
    let refused: Inbox<any Error>
    /// The listener's (TLS).
    let tlsRejected: Inbox<NetworkStreamError>
    let acceptor: LinkAcceptor
    let listener: NetworkStreamListener
    let port: UInt16

    init(secrets stored: [String: [UInt8]]) async throws {
        let secrets = ScriptedSecrets(stored)
        let accepted = Inbox<AcceptedLink>(), refused = Inbox<any Error>(), tlsRejected = Inbox<NetworkStreamError>()
        let ready = Inbox<UInt16>()
        let acceptor = LinkAcceptor(secrets: secrets, label: "test.wifi", onReject: { refused.put($0) },
                                    onLink: { accepted.put($0) })
        let listener = try NetworkStreamListener(
            psks: stored.values.map(WiFiPSK.init(secret:)), options: .loopback,
            onEvent: { event in
                switch event {
                case .state(.ready(let port)): ready.put(port)
                case .rejected(let error): tlsRejected.put(error)
                default: break
                }
            }, onAccept: { acceptor.accept($0) })
        guard let port = await ready.next() else {
            listener.cancel()
            throw TransportError.timeout
        }
        (self.secrets, self.accepted, self.refused, self.tlsRejected) = (secrets, accepted, refused, tlsRejected)
        (self.acceptor, self.listener, self.port) = (acceptor, listener, port)
    }

    var endpoint: NWEndpoint { .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!) }

    /// One link attempt from the client, with `psk` (a fresh `WiFiLinkDialer` per attempt).
    func dialer(psk: WiFiPSK) -> LinkDialer {
        LinkDialer(dialer: WiFiLinkDialer(endpoint: endpoint, psk: psk, options: .loopback), label: "test.client.wifi")
    }

    /// One connection written by hand: TLS with `psk`, then whatever the test sends.
    func rawChannel(psk: WiFiPSK, _ kind: ConnectionKind) async throws -> MessageChannel {
        let stream = try await NetworkStreamDialer(endpoint: endpoint, psk: psk, options: .loopback).dial(kind: kind)
        let channel = MessageChannel(stream: stream, label: "test.raw.\(kind)")
        channel.start()
        return channel
    }

    func cancel() {
        listener.cancel()
        acceptor.cancel()
    }
}

@Suite(.serialized) struct WiFiLinks {
    let stored = ["IPAD-1": ChannelAuth.randomBytes(32), "IPAD-2": ChannelAuth.randomBytes(32),
                  "IPAD-3": ChannelAuth.randomBytes(32)]

    @Test func theClientDialsAndTheHostAcceptsOverTLSPSK() async throws {
        let host = try await WiFiHost(secrets: stored)
        defer { host.cancel() }
        for (account, secret) in stored.sorted(by: { $0.key < $1.key }) {
            let psk = WiFiPSK(secret: secret)
            let link = try await host.dialer(psk: psk).open(secret: secret)
            defer { link.close() }
            let accepted = try #require(await host.accepted.next())
            defer { accepted.link.close() }
            #expect(accepted.peer == account && accepted.secret == secret && !accepted.paired)
            #expect(accepted.link.sessionToken == link.sessionToken)

            // One loopback path for all six ends, TLS 1.2 ECDHE-PSK under this pairing's key.
            let dialed = link.channels.compactMap { $0.stream as? NetworkStream }
            let hostSide = accepted.link.channels.compactMap { $0.stream as? NetworkStream }
            try #require(dialed.count == 3 && hostSide.count == 3)
            let interface = dialed[0].path.interfaceName
            #expect(dialed[0].path.kind == .loopback && !interface.isEmpty)
            #expect(link.transport == .network(interface: interface, peerToPeer: false))
            #expect(accepted.link.transport == link.transport)
            for stream in dialed + hostSide {
                #expect(stream.path.interfaceName == interface)
                #expect(stream.tls == NegotiatedTLS(version: WiFiTLS.version, cipherSuite: WiFiTLS.cipherSuite))
                #expect(stream.pskIdentity == psk.identity)
            }
            // LinkDialer dials through `dial(kind:)`, so realtime alone gets the voice service class.
            #expect(dialed[0].core.connection.parameters.serviceClass == .interactiveVoice)
            #expect(dialed[1...].allSatisfy { $0.core.connection.parameters.serviceClass == .bestEffort })

            // The client sends Hello first, whichever side dialed (§7.1); the host answers HelloAck.
            link.realtime.send(.hello(sampleHello))
            #expect(try await accepted.link.realtime.next(timeoutSeconds: 2).message == .hello(sampleHello))
            accepted.link.realtime.send(.helloAck(sampleHelloAck))
            #expect(try await LinkDialer.reply(on: link, timeoutSeconds: 2).message == .helloAck(sampleHelloAck))
            for (accepting, dialing) in zip(accepted.link.channels, link.channels) {
                accepting.send(.ping(Ping(id: 1, sentAtNs: 2)))
                #expect(try await dialing.next(timeoutSeconds: 2).message == .ping(Ping(id: 1, sentAtNs: 2)))
                dialing.send(.ping(Ping(id: 3, sentAtNs: 4)))
                #expect(try await accepting.next(timeoutSeconds: 2).message == .ping(Ping(id: 3, sentAtNs: 4)))
            }
            // A keyframe-sized frame to the client and its ack back.
            let keyframe = VideoFrame(frameId: 1, configId: 1, captureTimeNs: 1, encodeDoneNs: 2, isKeyframe: true,
                                      data: patternBytes(1_300_000, seed: 5))
            let ack = FrameAck(frameId: 1, receivedAtNs: 3, bytes: 1_300_000)
            accepted.link.video.send(.videoFrame(keyframe))
            #expect(try await link.video.next(timeoutSeconds: 5).message == .videoFrame(keyframe))
            link.video.send(.frameAck(ack))
            #expect(try await accepted.link.video.next(timeoutSeconds: 2).message == .frameAck(ack))
        }
        #expect(host.secrets.writeCount == 0)
        #expect(await host.refused.next(within: 0.1) == nil)
    }

    @Test func aWrongSecretFailsAtTLSAndNothingIsDelivered() async throws {
        let host = try await WiFiHost(secrets: stored)
        defer { host.cancel() }
        // A secret the host doesn't hold: its PSK identity is unknown there.
        let stranger = ChannelAuth.randomBytes(32)
        await #expect(throws: NetworkStreamError.unknownIdentity) {
            _ = try await host.dialer(psk: WiFiPSK(secret: stranger)).open(secret: stranger)
        }
        #expect(await host.tlsRejected.next() == .unknownIdentity)
        // A known identity with another key.
        let known = try #require(stored["IPAD-1"])
        let forged = WiFiPSK(identity: WiFiPSK(secret: known).identity, key: WiFiPSK(secret: stranger).key)
        await #expect(throws: NetworkStreamError.wrongKey) { _ = try await host.dialer(psk: forged).open(secret: known) }
        #expect(await host.tlsRejected.next() == .wrongKey)
        // Neither reached the acceptor.
        #expect(await host.accepted.next(within: 0.3) == nil)
        #expect(await host.refused.next(within: 0.1) == nil)
    }

    @Test func aPairingHelloIsRefusedEvenUnderAValidPSK() async throws {
        let host = try await WiFiHost(secrets: stored)
        defer { host.cancel() }
        // Wireless never pairs (D13): a zero-HMAC hello plus Pair on a connection TLS accepted.
        let secret = try #require(stored["IPAD-1"])
        let realtime = try await host.rawChannel(psk: WiFiPSK(secret: secret), .realtime)
        defer { realtime.close() }
        realtime.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: ChannelAuth.randomBytes(16), secret: nil)))
        realtime.send(.pair(Pair(secret: ChannelAuth.randomBytes(32))))
        #expect(try await realtime.next(timeoutSeconds: 2).message
                == .error(ErrorMessage(code: .authenticationFailed, message: "pairing not accepted here")))
        #expect(await closeWatch(realtime).next(within: 3) == true)   // after `next`, which replaces the close handler
        // A dialer's open fails the same way.
        await #expect(throws: TransportError.authenticationFailed) {
            _ = try await host.dialer(psk: WiFiPSK(secret: secret)).open(pairing: Pair(secret: ChannelAuth.randomBytes(32)))
        }
        #expect(transportError(await host.refused.next()) == .authenticationFailed)
        #expect(transportError(await host.refused.next()) == .authenticationFailed)
        #expect(await host.accepted.next(within: 0.3) == nil)
        #expect(host.secrets.writeCount == 0)
        #expect(host.secrets.inner.allSecrets() == stored)
    }

    @Test func aChannelHelloUnderAnotherPairingThanItsTLSKeyIsRefused() async throws {
        let host = try await WiFiHost(secrets: stored)
        defer { host.cancel() }
        let one = try #require(stored["IPAD-1"]), two = try #require(stored["IPAD-2"])

        // TLS under IPAD-1's key, ChannelHello under IPAD-2's secret (which the host also holds).
        func refusal(tls: [UInt8], hmac: [UInt8]) async throws -> Message {
            let channel = try await host.rawChannel(psk: WiFiPSK(secret: tls), .realtime)
            defer { channel.close() }
            channel.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: ChannelAuth.randomBytes(16), secret: hmac)))
            return try await channel.next(timeoutSeconds: 2).message
        }
        #expect(try await refusal(tls: one, hmac: two)
                == .error(ErrorMessage(code: .authenticationFailed, message: "HMAC under another pairing than the TLS key")))
        #expect(transportError(await host.refused.next()) == .authenticationFailed)
        await #expect(throws: TransportError.authenticationFailed) {   // a dialer's open fails in place of its ChannelAccept
            _ = try await host.dialer(psk: WiFiPSK(secret: one)).open(secret: two)
        }
        #expect(transportError(await host.refused.next()) == .authenticationFailed)

        // Under a secret the host doesn't hold at all.
        #expect(try await refusal(tls: one, hmac: ChannelAuth.randomBytes(32))
                == .error(ErrorMessage(code: .authenticationFailed, message: "bad HMAC")))
        #expect(transportError(await host.refused.next()) == .authenticationFailed)

        // Video joining a well-bound realtime over another pairing's TLS key: refused, and the session
        // is never delivered.
        let token = ChannelAuth.randomBytes(16)
        let realtime = try await host.rawChannel(psk: WiFiPSK(secret: one), .realtime)
        let video = try await host.rawChannel(psk: WiFiPSK(secret: two), .video)
        let audio = try await host.rawChannel(psk: WiFiPSK(secret: one), .audio)
        defer { [realtime, video, audio].forEach { $0.close() } }
        realtime.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: token, secret: one)))
        video.send(.channelHello(ChannelAuth.hello(kind: .video, token: token, secret: one)))
        audio.send(.channelHello(ChannelAuth.hello(kind: .audio, token: token, secret: one)))
        #expect(try await video.next(timeoutSeconds: 2).message
                == .error(ErrorMessage(code: .authenticationFailed, message: "video under another pairing than its TLS key")))
        #expect(transportError(await host.refused.next()) == .authenticationFailed)
        #expect(await host.accepted.next(within: 0.5) == nil)
        #expect(host.secrets.writeCount == 0)
    }
}
