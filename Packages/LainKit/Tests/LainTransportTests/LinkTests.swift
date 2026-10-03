import Foundation
import Dispatch
import LainProtocol
import LainTelemetry
import Security
import Testing
@testable import LainTransport

/// A client listener whose links answer `Hello` automatically (as ClientSession will).
struct ClientHarness {
    let listener: ClientLinkListener
    let links: Inbox<Link>
    let secrets: InMemorySecretStore

    init(secrets: InMemorySecretStore = InMemorySecretStore(), acceptsPairing: Bool = true) throws {
        let links = Inbox<Link>()
        self.links = links
        self.secrets = secrets
        listener = try ClientLinkListener(port: 0, secrets: secrets, acceptsPairing: acceptsPairing) { link in
            link.realtime.send(.hello(sampleHello))
            links.put(link)
        }
    }
}

@Suite(.serialized) struct LinkEstablishment {
    @Test func firstConnectionPairsThenReusesTheSecret() async throws {
        let client = try ClientHarness()
        defer { client.listener.cancel() }
        let hostSecrets = InMemorySecretStore()
        let dialer = LoopbackDialer(port: client.listener.port)

        let (link, hello, paired) = try await HostLink.open(dialer: dialer, secrets: hostSecrets, peerID: "IPAD", allowPairing: true)
        #expect(hello == sampleHello)
        #expect(paired)
        let clientLink = try #require(await client.links.next())
        #expect(clientLink.sessionToken == link.sessionToken)
        let secret = try #require(hostSecrets.secret(for: "IPAD"))
        #expect(client.secrets.secret(for: "host") == secret)
        link.close()

        // Second session: authenticated with the stored secret, no pairing.
        let (link2, _, paired2) = try await HostLink.open(dialer: dialer, secrets: hostSecrets, peerID: "IPAD", allowPairing: false)
        #expect(!paired2)
        #expect(try #require(await client.links.next()).sessionToken == link2.sessionToken)
        #expect(hostSecrets.secret(for: "IPAD") == secret)
        link2.close()
    }

    @Test func staleSecretRepairsOverUSBOnly() async throws {
        let client = try ClientHarness(secrets: InMemorySecretStore(["host": ChannelAuth.randomBytes(32)]))
        defer { client.listener.cancel() }
        let stale = ChannelAuth.randomBytes(32)
        let dialer = LoopbackDialer(port: client.listener.port)

        await #expect(throws: TransportError.authenticationFailed) {
            _ = try await HostLink.open(dialer: dialer, secrets: InMemorySecretStore(["IPAD": stale]), peerID: "IPAD",
                                        allowPairing: false)
        }
        let hostSecrets = InMemorySecretStore(["IPAD": stale])
        let (link, _, repaired) = try await HostLink.open(dialer: dialer, secrets: hostSecrets, peerID: "IPAD", allowPairing: true)
        #expect(repaired)
        #expect(hostSecrets.secret(for: "IPAD") != stale)
        #expect(hostSecrets.secret(for: "IPAD") == client.secrets.secret(for: "host"))
        link.close()
    }

    @Test func listenerWithoutPairingRejectsPairingRequests() async throws {
        let client = try ClientHarness(acceptsPairing: false)
        defer { client.listener.cancel() }
        await #expect(throws: TransportError.authenticationFailed) {
            _ = try await HostLink.open(dialer: LoopbackDialer(port: client.listener.port), secrets: InMemorySecretStore(),
                                        peerID: "IPAD", allowPairing: true)
        }
        #expect(client.secrets.secret(for: "host") == nil)
    }

    @Test func connectionsThatDoNotOpenWithChannelHelloAreClosed() async throws {
        let client = try ClientHarness()
        defer { client.listener.cancel() }
        // Wrong first message (a handshake frame, but not ChannelHello): rejected with an Error.
        let wrong = MessageChannel(stream: try TCP.connectLoopback(port: client.listener.port), label: "wrong")
        wrong.start()
        wrong.send(.pair(Pair(secret: ChannelAuth.randomBytes(Pair.secretSize))))
        let reply = try await wrong.next(timeoutSeconds: 2)
        #expect(reply.message.type == .error)
        // Silence: closed after the hello timeout.
        let silent = MessageChannel(stream: try TCP.connectLoopback(port: client.listener.port), label: "silent")
        let closed = Inbox<Bool>()
        silent.setCloseHandler { _ in closed.put(true) }
        silent.start()
        #expect(await closed.next(within: ClientLinkListener.helloTimeout + 2) == true)
    }

    @Test func forgedVideoConnectionIsRejected() async throws {
        let client = try ClientHarness(secrets: InMemorySecretStore(["host": Array(repeating: 1, count: 32)]))
        defer { client.listener.cancel() }
        let token = ChannelAuth.randomBytes(16)
        let realtime = MessageChannel(stream: try TCP.connectLoopback(port: client.listener.port), label: "rt")
        realtime.start()
        realtime.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: token, secret: Array(repeating: 1, count: 32))))
        let forged = MessageChannel(stream: try TCP.connectLoopback(port: client.listener.port), label: "forged")
        let closed = Inbox<Bool>()
        forged.setCloseHandler { _ in closed.put(true) }
        forged.start()
        forged.send(.channelHello(ChannelAuth.hello(kind: .video, token: token, secret: Array(repeating: 2, count: 32))))
        #expect(await closed.next() == true)
        #expect(await client.links.next(within: 0.3) == nil)
        realtime.close()
    }
}

/// Dialer and acceptor roles (§7.7 D29): candidate secrets, the read-failure rules, pairing policy,
/// the client-dials direction, session bookkeeping, and the USB socket options.
@Suite(.serialized) struct LinkRoles {
    @Test func theAcceptorReportsWhichStoredAccountMatched() async throws {
        let usb = ChannelAuth.randomBytes(32), macA = ChannelAuth.randomBytes(32), macB = ChannelAuth.randomBytes(32)
        let idA = UUID().uuidString, idB = UUID().uuidString
        let client = try AcceptingClient(secrets: InMemorySecretStore(
            [PairingAccounts.usbHost: usb, PairingAccounts.mac(idA): macA, PairingAccounts.mac(idB): macB]))
        defer { client.listener.cancel() }
        let dialer = LoopbackDialer(port: client.listener.port)
        for (secret, account) in [(macB, PairingAccounts.mac(idB)), (usb, PairingAccounts.usbHost), (macA, PairingAccounts.mac(idA))] {
            let (link, _, paired) = try await HostLink.open(dialer: dialer, secrets: InMemorySecretStore(["IPAD": secret]),
                                                            peerID: "IPAD", allowPairing: false)
            #expect(!paired)
            let accepted = try #require(await client.accepted.next())
            #expect(accepted.peer == account && accepted.secret == secret && !accepted.paired)
            #expect(accepted.link.sessionToken == link.sessionToken && accepted.link.transport == .usb)
            link.close()
        }

        // The host's side: no primary account, every stored iPad is a candidate.
        let a = ChannelAuth.randomBytes(32), b = ChannelAuth.randomBytes(32)
        let host = try AcceptorHarness(secrets: InMemorySecretStore(["IPAD-1": a, "IPAD-2": b]))
        defer { host.cancel() }
        let link = try await LinkDialer(dialer: LoopbackDialer(port: host.port)).open(secret: b)
        let accepted = try #require(await host.accepted.next())
        #expect(accepted.peer == "IPAD-2" && accepted.secret == b && accepted.link.sessionToken == link.sessionToken)
        link.close()
    }

    @Test func aWrongSecretIsAnsweredThenClosed() async throws {
        let host = try AcceptorHarness(secrets: InMemorySecretStore(["IPAD": ChannelAuth.randomBytes(32)]))
        defer { host.cancel() }
        let realtime = try rawChannel(to: host.port)
        defer { realtime.close() }
        realtime.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: ChannelAuth.randomBytes(16),
                                                      secret: ChannelAuth.randomBytes(32))))
        let reply = try await realtime.next(timeoutSeconds: 2)
        #expect(reply.message == .error(ErrorMessage(code: .authenticationFailed, message: "bad HMAC")))
        #expect(await closeWatch(realtime).next(within: 2) == true)
        #expect(transportError(await host.rejected.next()) == .authenticationFailed)
        #expect(await host.accepted.next(within: 0.2) == nil)
    }

    @Test func unlistableSecretsStillAuthenticateTheUSBHost() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let store = ScriptedSecrets([PairingAccounts.usbHost: secret], failsListing: true)
        let client = try AcceptingClient(secrets: store)
        defer { client.listener.cancel() }
        let hostSecrets = InMemorySecretStore(["IPAD": secret])
        let (link, _, paired) = try await HostLink.open(dialer: LoopbackDialer(port: client.listener.port), secrets: hostSecrets,
                                                        peerID: "IPAD", allowPairing: true)
        #expect(!paired)
        #expect(try #require(await client.accepted.next()).peer == PairingAccounts.usbHost)
        #expect(store.writeCount == 0)   // no Pair ever reached the client
        #expect(hostSecrets.secret(for: "IPAD") == secret)
        link.close()
    }

    @Test func anUnreadablePrimarySecretAnswersInternalAndNeverRepairs() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let store = ScriptedSecrets([PairingAccounts.usbHost: secret], failsSecretRead: true)
        let client = try AcceptingClient(secrets: store)
        defer { client.listener.cancel() }

        // On the wire: Error(internal), not authenticationFailed (which would make the host re-pair).
        let realtime = try rawChannel(to: client.listener.port)
        defer { realtime.close() }
        realtime.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: ChannelAuth.randomBytes(16), secret: secret)))
        let reply = try await realtime.next(timeoutSeconds: 2)
        guard case .error(let e) = reply.message else { Issue.record("expected Error, got \(reply.message.type)"); return }
        #expect(e.code == .internal)
        #expect(await client.rejected.next() is ScriptedSecrets.Failure)

        // HostLink fails this attempt as it is: the caller retries with the same secret.
        let hostSecrets = InMemorySecretStore(["IPAD": secret])
        let error = await #expect(throws: TransportError.self) {
            _ = try await HostLink.open(dialer: LoopbackDialer(port: client.listener.port), secrets: hostSecrets,
                                        peerID: "IPAD", allowPairing: true)
        }
        guard case .unexpectedMessage? = error else { Issue.record("expected a plain failure, got \(String(describing: error))"); return }
        #expect(hostSecrets.secret(for: "IPAD") == secret)
        #expect(store.writeCount == 0)
        #expect(await client.accepted.next(within: 0.2) == nil)
    }

    @Test func anAcceptorThatDoesNotPairRefusesPairing() async throws {
        let store = ScriptedSecrets()
        let host = try AcceptorHarness(secrets: store)   // like the host's Wi-Fi acceptor: wireless never pairs (D13)
        defer { host.cancel() }
        // Refused in place of its ChannelAccept, so the dialer's open fails.
        await #expect(throws: TransportError.authenticationFailed) {
            _ = try await LinkDialer(dialer: LoopbackDialer(port: host.port)).open(pairing: Pair(secret: ChannelAuth.randomBytes(32)))
        }
        #expect(transportError(await host.rejected.next()) == .authenticationFailed)
        #expect(store.writeCount == 0)
        #expect(await host.accepted.next(within: 0.2) == nil)
    }

    @Test func theClientDialsAndTheHostAccepts() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let path = LinkTransport.network(interface: "lo0", peerToPeer: false)
        let host = try AcceptorHarness(secrets: InMemorySecretStore(["IPAD-SERIAL": secret]), transport: path)
        defer { host.cancel() }
        let link = try await LinkDialer(dialer: LoopbackDialer(port: host.port), label: "lain.client",
                                        transport: { _ in path }).open(secret: secret)
        defer { link.close() }
        #expect(link.transport == path)
        link.realtime.send(.hello(sampleHello))   // the client sends Hello first, whichever side dialed (§7.1)

        let accepted = try #require(await host.accepted.next())
        #expect(accepted.peer == "IPAD-SERIAL" && accepted.secret == secret && !accepted.paired)
        #expect(accepted.link.sessionToken == link.sessionToken && accepted.link.transport == path)
        #expect(try await accepted.link.realtime.next(timeoutSeconds: 2).message == .hello(sampleHello))
        accepted.link.realtime.send(.helloAck(sampleHelloAck))
        #expect(try await LinkDialer.reply(on: link, timeoutSeconds: 2).message == .helloAck(sampleHelloAck))
        for (accepting, dialing) in zip(accepted.link.channels, link.channels) {
            accepting.send(.ping(Ping(id: 1, sentAtNs: 2)))
            #expect(try await dialing.next(timeoutSeconds: 2).message == .ping(Ping(id: 1, sentAtNs: 2)))
            dialing.send(.ping(Ping(id: 3, sentAtNs: 4)))
            #expect(try await accepting.next(timeoutSeconds: 2).message == .ping(Ping(id: 3, sentAtNs: 4)))
        }
    }

    @Test func videoAndAudioMayArriveBeforeRealtime() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let host = try AcceptorHarness(secrets: InMemorySecretStore(["IPAD": secret]))
        defer { host.cancel() }
        let token = ChannelAuth.randomBytes(16)
        let video = try rawChannel(to: host.port), audio = try rawChannel(to: host.port)
        defer { video.close(); audio.close() }
        video.send(.channelHello(ChannelAuth.hello(kind: .video, token: token, secret: secret)))
        audio.send(.channelHello(ChannelAuth.hello(kind: .audio, token: token, secret: secret)))
        #expect(await host.accepted.next(within: 0.3) == nil)   // both wait for their realtime

        let realtime = try rawChannel(to: host.port)
        defer { realtime.close() }
        realtime.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: token, secret: secret)))
        let accepted = try #require(await host.accepted.next())
        #expect(accepted.link.sessionToken == token && accepted.peer == "IPAD")
        // Each was answered at the session's version once it joined.
        for channel in [realtime, video, audio] {
            guard case .channelAccept(let a) = try await channel.next(timeoutSeconds: 2).message else {
                Issue.record("no ChannelAccept"); return
            }
            #expect(a.chosen == LainProtocol.newestVersion)
            channel.setVersion(a.chosen)
        }
        accepted.link.video.send(.ping(Ping(id: 7, sentAtNs: 0)))
        #expect(try await video.next(timeoutSeconds: 2).message == .ping(Ping(id: 7, sentAtNs: 0)))
    }

    @Test func aLateJoinForADeliveredSessionIsClosed() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let host = try AcceptorHarness(secrets: InMemorySecretStore(["IPAD": secret]))
        defer { host.cancel() }
        let link = try await LinkDialer(dialer: LoopbackDialer(port: host.port)).open(secret: secret)
        defer { link.close() }
        let accepted = try #require(await host.accepted.next())

        // Another video connection for the delivered session: closed at once, and the delivered one stays.
        let late = try rawChannel(to: host.port)
        defer { late.close() }
        let lateClosed = closeWatch(late)
        late.send(.channelHello(ChannelAuth.hello(kind: .video, token: link.sessionToken, secret: secret)))
        #expect(await lateClosed.next(within: 1) == true)   // well before the hello timeout
        #expect(await host.accepted.next(within: 0.2) == nil)
        accepted.link.video.send(.ping(Ping(id: 3, sentAtNs: 0)))
        #expect(try await link.video.next(timeoutSeconds: 2).message == .ping(Ping(id: 3, sentAtNs: 0)))
    }

    @Test func aSessionWhoseVideoAndAudioNeverComeIsDropped() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let host = try AcceptorHarness(secrets: InMemorySecretStore(["IPAD": secret]))
        defer { host.cancel() }
        let token = ChannelAuth.randomBytes(16)
        let realtime = try rawChannel(to: host.port)
        defer { realtime.close() }
        let closed = closeWatch(realtime)
        realtime.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: token, secret: secret)))
        #expect(await closed.next(within: 1) == nil)   // accepted; waiting for video and audio
        #expect(await closed.next(within: LinkAcceptor.helloTimeout + 2) == true)

        // A join after the drop is closed at once.
        let video = try rawChannel(to: host.port)
        defer { video.close() }
        let videoClosed = closeWatch(video)
        video.send(.channelHello(ChannelAuth.hello(kind: .video, token: token, secret: secret)))
        #expect(await videoClosed.next(within: 1) == true)
        #expect(await host.accepted.next(within: 0.1) == nil)
    }

    @Test func cancelClosesOnlyWhatWasNotDelivered() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let host = try AcceptorHarness(secrets: InMemorySecretStore(["IPAD": secret]))
        let link = try await LinkDialer(dialer: LoopbackDialer(port: host.port)).open(secret: secret)
        defer { link.close() }
        let accepted = try #require(await host.accepted.next())
        let pending = try rawChannel(to: host.port)
        defer { pending.close() }
        let pendingClosed = closeWatch(pending)
        pending.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: ChannelAuth.randomBytes(16), secret: secret)))
        #expect(await pendingClosed.next(within: 0.3) == nil)

        host.cancel()
        #expect(await pendingClosed.next(within: 1) == true)
        accepted.link.realtime.send(.ping(Ping(id: 5, sentAtNs: 0)))   // the delivered link is the consumer's
        #expect(try await link.realtime.next(timeoutSeconds: 2).message == .ping(Ping(id: 5, sentAtNs: 0)))
    }

    @Test func theClientListenerSetsNoDelayOnEveryAcceptedSocket() async throws {
        let client = try AcceptingClient(secrets: InMemorySecretStore())
        defer { client.listener.cancel() }
        let (link, _, _) = try await HostLink.open(dialer: LoopbackDialer(port: client.listener.port), secrets: InMemorySecretStore(),
                                                   peerID: "IPAD", allowPairing: true)
        defer { link.close() }
        let accepted = try #require(await client.accepted.next())
        // §7.1: the iPad side of every connection. Darwin reports the option as its flag bit (4), not 1.
        for channel in accepted.link.channels {
            #expect(tcpNoDelay(try #require(channel.stream as? SocketStream)) != 0)
        }
        #expect(tcpNoDelay(try #require(link.realtime.stream as? SocketStream)) == 0)   // the dialed end: the check reads it
    }

    @Test func pairingStoresTheSecretForUSBAndForWiFiTogether() async throws {
        let hostId = UUID().uuidString
        let client = try AcceptingClient(secrets: InMemorySecretStore())
        defer { client.listener.cancel() }
        let hostSecrets = InMemorySecretStore()
        let (link, _, paired) = try await HostLink.open(dialer: LoopbackDialer(port: client.listener.port), secrets: hostSecrets,
                                                        peerID: "IPAD", allowPairing: true, hostId: hostId)
        #expect(paired)
        let secret = try #require(hostSecrets.secret(for: "IPAD"))
        #expect(client.secrets.allSecrets() == [PairingAccounts.usbHost: secret, PairingAccounts.mac(hostId): secret])
        let accepted = try #require(await client.accepted.next())
        #expect(accepted.paired && accepted.peer == PairingAccounts.usbHost && accepted.secret == secret)
        link.close()

        // A malformed host id never becomes an account: USB only.
        let other = try AcceptingClient(secrets: InMemorySecretStore())
        defer { other.listener.cancel() }
        let (link2, _, _) = try await HostLink.open(dialer: LoopbackDialer(port: other.listener.port), secrets: InMemorySecretStore(),
                                                    peerID: "IPAD", allowPairing: true, hostId: hostId.lowercased())
        #expect(Array(other.secrets.allSecrets().keys) == [PairingAccounts.usbHost])
        link2.close()
    }

    @Test func aLegacyPeerIsToldWhyInItsOwnFraming() async throws {
        let client = try AcceptingClient(secrets: InMemorySecretStore())
        defer { client.listener.cancel() }
        // A v2 host's first frame: a pairing ChannelHello in a v2 header.
        let v2 = try TCP.connectLoopback(port: client.listener.port)
        defer { v2.close() }
        let reply = LockedBytes(), closed = Inbox<Bool>()
        v2.start(queue: DispatchQueue(label: "v2"), onBytes: { _ = reply.append($0) }, onClose: { _ in closed.put(true) })
        v2.write(legacyChannelHello(version: 2))
        #expect(await closed.next() == true)
        let answer = reply.bytes
        try #require(answer.count > FrameHeader.size)
        #expect(answer[2] == 2)   // framed in v2…
        guard case .error(let e) = try MessageCodec.decode(reframed(answer, version: LainProtocol.handshakeVersion)).message else {
            Issue.record("not an Error"); return
        }
        #expect(e.code == .versionMismatch)   // …with the Error layout v2 already had
        #expect(transportError(await client.rejected.next()) == .versionMismatch(remote: 2))
        #expect(client.secrets.allSecrets().isEmpty && client.accepted.count == 0)

        // A dialer that gets such an answer (here from a peer on v2) says so, instead of just "closed".
        let peer = try TCPListener(port: 0, queue: DispatchQueue(label: "v2.peer")) { socket in
            let answered = Mutex(false)
            socket.start(queue: DispatchQueue(label: "v2.conn"), onBytes: { _ in
                guard answered.withLock({ a in defer { a = true }; return !a }) else { return }
                socket.write(answer)
                socket.close()
            }, onClose: { _ in })
        }
        defer { peer.cancel() }
        await #expect(throws: TransportError.versionMismatch(remote: 2)) {
            _ = try await HostLink.open(dialer: LoopbackDialer(port: peer.port), secrets: InMemorySecretStore(), peerID: "IPAD",
                                        allowPairing: true)
        }
    }

    @Test func aLegacyAcceptorsAnswerInOurFramingIsAVersionMismatch() async throws {
        // A v2 acceptor answers our handshake frame with Error(versionMismatch) framed in our header's
        // version (it can't read our ChannelHello).
        let sockets = Inbox<SocketStream>()
        let peer = try TCPListener(port: 0, queue: DispatchQueue(label: "peer")) { socket in
            sockets.put(socket)
            socket.start(queue: DispatchQueue(label: "peer.conn"), onBytes: { _ in }, onClose: { _ in })
            socket.write(MessageCodec.legacyVersionMismatch(remote: LainProtocol.handshakeVersion, why: "v2 here",
                                                            sequence: 0, timestampNs: 0))
        }
        defer { peer.cancel() }
        await #expect(throws: TransportError.versionMismatch(remote: 0)) {
            _ = try await LinkDialer(dialer: LoopbackDialer(port: peer.port)).open(secret: ChannelAuth.randomBytes(32))
        }
        while let socket = await sockets.next(within: 0) { socket.close() }
    }
}

/// Negotiation (PROTOCOL-VERSIONING §3.2): the highest version both lists name with equal digests.
@Suite struct Negotiation {
    func open(dialer dialerVersions: VersionList, acceptor acceptorVersions: VersionList,
              secrets: InMemorySecretStore = InMemorySecretStore()) async throws -> (Link, AcceptingClient<InMemorySecretStore>) {
        let client = try AcceptingClient(secrets: secrets, versions: acceptorVersions)
        let links = LinkDialer(dialer: LoopbackDialer(port: client.listener.port), versions: dialerVersions)
        let link = try await links.open(pairing: Pair(secret: ChannelAuth.randomBytes(32)))
        return (link, client)
    }

    @Test(arguments: [
        (versions((3, 1), (4, 1)), versions((3, 1), (4, 1)), UInt8(4)),
        (versions((3, 1)), versions((3, 1), (4, 1)), UInt8(3)),          // an older dialer
        (versions((3, 1), (4, 1)), versions((3, 1)), UInt8(3)),          // an older acceptor
        (versions((3, 1), (4, 1)), versions((3, 1), (4, 2)), UInt8(3)),  // two builds of v4: v3 is common
        (versions((4, 1), (5, 1)), versions((3, 1), (4, 1)), UInt8(4)),
    ])
    func theHighestCommonVersionWins(dialer: VersionList, acceptor: VersionList, expected: UInt8) async throws {
        let (link, client) = try await open(dialer: dialer, acceptor: acceptor)
        defer { link.close(); client.listener.cancel() }
        #expect(link.version == expected && link.peerVersions == acceptor)
        #expect(link.channels.allSatisfy { $0.version == expected })
        let accepted = try #require(await client.accepted.next())
        #expect(accepted.link.version == expected && accepted.link.peerVersions == dialer)
        #expect(accepted.link.channels.allSatisfy { $0.version == expected })
        // The session's first message arrives framed in the agreed version.
        let hello = try await link.realtime.next(timeoutSeconds: 2)
        #expect(hello.header.version == expected && hello.message == .hello(sampleHello))
        accepted.link.close()
    }

    @Test func noCommonVersionIsReportedOnBothSidesAndNothingPairs() async throws {
        let secrets = InMemorySecretStore()
        let client = try AcceptingClient(secrets: secrets, versions: versions((5, 1), (6, 1)))
        defer { client.listener.cancel() }
        let links = LinkDialer(dialer: LoopbackDialer(port: client.listener.port), versions: versions((3, 1), (4, 1)))
        await #expect(throws: TransportError.noCommonVersion(local: versions((3, 1), (4, 1)), peer: versions((5, 1), (6, 1)))) {
            _ = try await links.open(pairing: Pair(secret: ChannelAuth.randomBytes(32)))
        }
        #expect(transportError(await client.rejected.next())
                    == .noCommonVersion(local: versions((5, 1), (6, 1)), peer: versions((3, 1), (4, 1))))
        #expect(secrets.allSecrets().isEmpty && client.accepted.count == 0)   // a pairing waits for a version
        #expect(VersionGap(TransportError.noCommonVersion(local: versions((3, 1), (4, 1)), peer: versions((5, 1), (6, 1))))
                    == .peerNewer(peer: "protocol v5–v6"))
    }

    @Test func gapsNameTheSideToUpdate() {
        #expect(VersionGap(local: versions((5, 1), (6, 1)), peer: versions((3, 1), (4, 1))) == .peerOlder(peer: "protocol v3–v4"))
        #expect(VersionGap(local: versions((3, 1), (4, 1)), peer: versions((5, 1))) == .peerNewer(peer: "protocol v5"))
        #expect(VersionGap(local: versions((4, 1)), peer: versions((4, 2))) == .differentBuilds(version: 4))
        #expect(VersionGap(TransportError.versionMismatch(remote: 2)) == .peerOlder(peer: "protocol v2"))
        #expect(VersionGap(TransportError.versionMismatch(remote: 0)) == .peerOlder(peer: "a protocol from before v3"))
        #expect(VersionGap(TransportError.closed) == nil)
        #expect(VersionGap(local: versions((3, 1), (4, 1)), advertised: [4, 5]) == nil)   // shared: the handshake decides
        #expect(VersionGap(local: versions((3, 1), (4, 1)), advertised: [2]) == .peerOlder(peer: "protocol v2"))
        #expect(VersionGap(local: versions((3, 1), (4, 1)), advertised: [5, 6]) == .peerNewer(peer: "protocol v5–v6"))
        #expect(VersionGap(local: versions((3, 1), (4, 1)), advertised: []) == .peerOlder(peer: "an unknown protocol"))
    }

    @Test func anAcceptThatIsntTheHighestCommonVersionFailsTheLink() async throws {
        // A peer (or a bug) that picks a lower version than both sides share.
        let peer = try TCPListener(port: 0, queue: DispatchQueue(label: "downgrader")) { socket in
            socket.start(queue: DispatchQueue(label: "downgrader.conn"), onBytes: { _ in }, onClose: { _ in })
            socket.write(MessageCodec.encode(.channelAccept(ChannelAccept(chosen: 3, versions: versions((3, 1), (4, 1)))),
                                             sequence: 0, timestampNs: 0))
        }
        defer { peer.cancel() }
        let links = LinkDialer(dialer: LoopbackDialer(port: peer.port), versions: versions((3, 1), (4, 1)))
        await #expect(throws: TransportError.self) { _ = try await links.open(secret: ChannelAuth.randomBytes(32)) }
    }

    @Test func videoMustOfferWhatItsRealtimeOffered() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let client = try AcceptingClient(secrets: InMemorySecretStore([PairingAccounts.usbHost: secret]),
                                         versions: versions((3, 1), (4, 1)))
        defer { client.listener.cancel() }
        let token = ChannelAuth.randomBytes(16)
        let realtime = try rawChannel(to: client.listener.port, "rt")
        realtime.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: token, secret: secret, versions: versions((3, 1), (4, 1)))))
        #expect(try await realtime.next(timeoutSeconds: 2).message
                    == .channelAccept(ChannelAccept(chosen: 4, versions: versions((3, 1), (4, 1)))))
        let video = try rawChannel(to: client.listener.port, "video")
        video.send(.channelHello(ChannelAuth.hello(kind: .video, token: token, secret: secret, versions: versions((3, 1)))))
        guard case .error(let e) = try await video.next(timeoutSeconds: 2).message else { Issue.record("not refused"); return }
        #expect(e.code == .authenticationFailed)
        realtime.close()
    }
}

/// `MessageChannel`'s version-mismatch surfacing: a frame in a version this build doesn't implement.
@Suite struct ChannelVersionMismatch {
    @Test func aLegacyFrameIsTheCloseError() async throws {
        let (a, b) = MemoryStream.pair()
        let channel = MessageChannel(stream: b, label: "b")
        channel.start()
        a.start(queue: DispatchQueue(label: "a"), onBytes: { _ in }, onClose: { _ in })
        a.write(reframed(MessageCodec.encode(.ping(Ping(id: 1, sentAtNs: 0)), sequence: 0, timestampNs: 0), version: 2))
        await #expect(throws: TransportError.versionMismatch(remote: 2)) { _ = try await channel.next(timeoutSeconds: 2) }
        let reported = Inbox<TransportError?>()
        channel.setCloseHandler { reported.put($0 as? TransportError) }
        #expect(await reported.next() == .versionMismatch(remote: 2))
    }

    @Test func onlyAnAcceptorAnswersAndOnlyAMismatchedFirstFrame() async throws {
        func answer(acceptor: Bool, first: [Message]) async -> [UInt8] {
            let (a, b) = MemoryStream.pair()
            let channel = MessageChannel(stream: b, label: "b", answeringVersionMismatch: acceptor)
            channel.start()
            let got = LockedBytes(), closed = Inbox<Bool>()
            a.start(queue: DispatchQueue(label: "a"), onBytes: { _ = got.append($0) }, onClose: { _ in closed.put(true) })
            for m in first { a.write(MessageCodec.encode(m, sequence: 0, timestampNs: 0)) }
            a.write(reframed(MessageCodec.encode(.ping(Ping(id: 1, sentAtNs: 0)), sequence: 0, timestampNs: 0), version: 1))
            #expect(await closed.next() == true)
            withExtendedLifetime((a, channel)) {}
            return got.bytes
        }
        let answered = await answer(acceptor: true, first: [])
        #expect(answered.count > FrameHeader.size && answered[2] == 1 && answered[3] == MessageType.error.rawValue)
        #expect(await answer(acceptor: false, first: []).isEmpty)
        let hello = ProtocolSamples.all.first { $0.type == .channelHello }!
        #expect(await answer(acceptor: true, first: [hello]).isEmpty)
    }
}

@Suite struct SecretAccounts {
    @Test func accountNames() {
        let id = UUID().uuidString
        #expect(PairingAccounts.usbHost == "host")
        #expect(PairingAccounts.mac(id) == "mac:" + id)
        #expect(PairingAccounts.hostId(fromAccount: PairingAccounts.mac(id)) == id)
        #expect(PairingAccounts.hostId(fromAccount: PairingAccounts.usbHost) == nil)
        #expect(PairingAccounts.hostId(fromAccount: PairingAccounts.mac(id.lowercased())) == nil)
        #expect(PairingAccounts.isCanonicalHostId(id))
        for bad in [id.lowercased(), "", "{\(id)}", id + " ", "mac:" + id] { #expect(!PairingAccounts.isCanonicalHostId(bad)) }
    }

    @Test func inMemoryStoreListsEverything() {
        let s = InMemorySecretStore(["host": [1], "mac:X": [2]])
        #expect(s.allSecrets() == ["host": [1], "mac:X": [2]])
        s.removeSecret(for: "host")
        #expect(s.allSecrets() == ["mac:X": [2]])
    }

    /// The Keychain itself is exercised by the hosted tests (Apps/*Tests); this is the result parsing.
    @Test func keychainItemsParseSkippingMalformedOnes() {
        let account = kSecAttrAccount as String, data = kSecValueData as String
        let items: [Any] = [
            [account: "host", data: Data([1, 2])] as [String: Any],
            [account: "mac:X", data: Data([3])] as [String: Any],
            [data: Data([4])] as [String: Any],                   // no account
            [account: "no-data"] as [String: Any],                // no data
            [account: 7, data: Data([5])] as [String: Any],       // not a string account
            "not an item",
        ]
        #expect(KeychainSecretStore.secrets(fromItems: items) == ["host": [1, 2], "mac:X": [3]])
        #expect(KeychainSecretStore.secrets(fromItems: nil).isEmpty)
    }
}

/// `getsockopt(TCP_NODELAY)`: nonzero when set.
func tcpNoDelay(_ socket: SocketStream) -> Int32 {
    var value: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(socket.fd, IPPROTO_TCP, TCP_NODELAY, &value, &length)
    return value
}

#if os(macOS)
import LainTestSupport
import LainUSBMux

/// Step 5's integration test: fake usbmuxd → the client listener code (running on macOS) → full
/// ChannelHello + Hello/HelloAck handshake, then ping/pong RTT and FrameAck backpressure.
@Suite(.serialized) struct USBPathIntegration {
    @Test func handshakePingAndBackpressureOverUSBMux() async throws {
        // Client side: answers pings, acks video frames after a delay (a slow client).
        let ackDelayMs = 5
        let client = try ClientHarness()
        defer { client.listener.cancel() }
        let mux = try FakeUSBMuxd(devices: [.init(deviceID: 5, serialNumber: "IPAD-SERIAL")], targetPort: client.listener.port)
        defer { mux.stop() }

        // Host side: discover the device, dial through usbmuxd, handshake.
        let usbmux = USBMuxClient(socketPath: mux.socketPath)
        var events = usbmux.events().makeAsyncIterator()
        guard case .attached(let device) = try await events.next() else { Issue.record("no device"); return }
        let t0 = MonotonicClock.now()
        let (link, hello, _) = try await HostLink.open(dialer: USBMuxDialer(client: usbmux, deviceID: device.deviceID),
                                                   secrets: InMemorySecretStore(), peerID: device.serialNumber,
                                                   allowPairing: true)
        let handshakeMs = Double(MonotonicClock.now() - t0) / 1e6
        #expect(hello == sampleHello)
        #expect(mux.connectCount == 3)
        let clientLink = try #require(await client.links.next())

        clientLink.realtime.setHandler { env in
            switch env.message {
            case .helloAck: break
            case .ping(let p):
                clientLink.realtime.send(.pong(Pong(id: p.id, pingSentAtNs: p.sentAtNs, receivedAtNs: MonotonicClock.now(),
                                                    sentAtNs: MonotonicClock.now())))
            default: break
            }
        }
        clientLink.video.setHandler { env in
            guard case .videoFrame(let f) = env.message else { return }
            let received = MonotonicClock.now()
            clientLink.video.queue.asyncAfter(deadline: .now() + .milliseconds(ackDelayMs)) {
                clientLink.video.send(.frameAck(FrameAck(frameId: f.frameId, receivedAtNs: received, bytes: UInt32(f.data.count))))
            }
        }
        link.realtime.send(.helloAck(sampleHelloAck))

        // Ping/pong: RTT and clock offset (same clock on both sides here, so the offset must be ~0).
        let pongs = Inbox<Pong>()
        link.realtime.setHandler { env in if case .pong(let p) = env.message { pongs.put(p) } }
        var estimator = ClockOffsetEstimator()
        var rtts = RollingPercentiles(capacity: 50)
        for i in 0..<50 {
            link.realtime.send(.ping(Ping(id: UInt32(i), sentAtNs: MonotonicClock.now())))
            let p = try #require(await pongs.next())
            let sample = estimator.add(t0: p.pingSentAtNs, t1: p.receivedAtNs, t2: p.sentAtNs, t3: MonotonicClock.now())
            let s = try #require(sample)
            rtts.record(Double(s.rttNs) / 1000)
        }
        let best = try #require(estimator.best)
        #expect(abs(best.offsetNs) <= best.rttNs / 2 + 1)

        // Backpressure: offer a frame every 1 ms for 300 ms with at most 2 unacknowledged.
        let window = WindowBox(maxInFlight: 2)
        let acksDone = Inbox<Int>()
        link.video.setHandler { env in
            guard case .frameAck(let a) = env.message else { return }
            if window.ack(a.frameId) { acksDone.put(1) }
        }
        let frame = [UInt8](repeating: 0xAB, count: 256 * 1024)
        var offered = 0, sent = 0
        let deadline = MonotonicClock.now() + 300_000_000
        while MonotonicClock.now() < deadline {
            offered += 1
            if let id = window.trySend(bytes: frame.count) {
                link.video.send(.videoFrame(VideoFrame(frameId: id, configId: 1, captureTimeNs: MonotonicClock.now(),
                                                       encodeDoneNs: MonotonicClock.now(), isKeyframe: false, data: frame)))
                sent += 1
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<sent { _ = await acksDone.next(within: 2) }
        #expect(window.maxObserved <= 2)
        #expect(window.inFlight == 0)
        #expect(sent > 10 && sent < offered)   // the slow client's acks, not the socket, set the pace
        let msPerFrame = 300.0 / Double(sent)
        print(String(format: "USB-path loopback (fake usbmuxd): handshake %.1f ms | ping RTT p50 %.0f µs p95 %.0f µs | "
                     + "backpressure: %d of %d frames sent at %.1f ms/frame (ack delay %d ms, N=2)",
                     handshakeMs, rtts.p50 ?? 0, rtts.p95 ?? 0, sent, offered, msPerFrame, ackDelayMs))
        link.close()
    }

    @Test func theHostsUSBVideoStreamKeepsItsSmallSendBuffer() async throws {
        let client = try ClientHarness()
        defer { client.listener.cancel() }
        let mux = try FakeUSBMuxd(devices: [.init(deviceID: 5, serialNumber: "IPAD-SERIAL")], targetPort: client.listener.port)
        defer { mux.stop() }
        let (link, _, _) = try await HostLink.open(dialer: USBMuxDialer(client: USBMuxClient(socketPath: mux.socketPath), deviceID: 5),
                                                   secrets: InMemorySecretStore(), peerID: "IPAD-SERIAL", allowPairing: true)
        defer { link.close() }
        let video = try #require(link.video.stream as? SocketStream)
        let realtime = try #require(link.realtime.stream as? SocketStream)
        #expect(video.sendBufferSize >= HostLink.videoSendBuffer)   // §7.3
        #expect(realtime.sendBufferSize < video.sendBufferSize)     // video only (a usbmuxd socket starts at 8 KB)
    }

    @Test func theUSBDialerDefaultsToTheClientsPort() {
        // Read in the initializer, not compiled into callers as a default argument value.
        #expect(USBMuxDialer(deviceID: 5).port == LainProtocol.usbPort)
        #expect(USBMuxDialer(deviceID: 5, port: 1234).port == 1234)
    }
}
#endif

import Synchronization

/// FrameAckWindow under a lock, recording the peak in-flight count.
final class WindowBox: Sendable {
    private let state: Mutex<(window: FrameAckWindow, nextId: UInt32, peak: Int)>
    init(maxInFlight: Int) { state = Mutex((FrameAckWindow(maxInFlight: maxInFlight), 1, 0)) }
    func trySend(bytes: Int) -> UInt32? {
        state.withLock { s in
            guard s.window.canSend else { return nil }
            let id = s.nextId
            s.nextId += 1
            s.window.sent(frameId: id, bytes: bytes, at: MonotonicClock.now())
            s.peak = max(s.peak, s.window.inFlightCount)
            return id
        }
    }
    func ack(_ id: UInt32) -> Bool { state.withLock { $0.window.acked(frameId: id, at: MonotonicClock.now()) != nil } }
    var maxObserved: Int { state.withLock { $0.peak } }
    var inFlight: Int { state.withLock { $0.window.inFlightCount } }
}
