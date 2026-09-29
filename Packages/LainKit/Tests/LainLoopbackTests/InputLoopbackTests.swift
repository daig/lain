#if os(macOS)
import CoreGraphics
import Dispatch
import LainClientCore
import LainHostCore
import LainInput
import LainProtocol
import LainTelemetry
import LainTestSupport
import LainTransport
import LainUSBMux
import Synchronization
import Testing

/// M2 end to end (§12.2 layer 2): the real `ClientSession` (as on the iPad) ↔ fake usbmuxd ↔ the real
/// `HostSession`, with a recording `InputSink` standing in for `InputInjector` and a "virtual Mac"
/// cursor that follows injected moves, so the warp logic runs as on hardware.
///
/// The client is driven through `ClientInputPipeline` entry points with explicit timestamps, and the
/// same calls are replayed on a standalone pipeline (the oracle): the host's sink must receive exactly
/// the oracle's input messages, in order.
@Suite(.serialized) struct InputLoopbackTests {
    static let display = HostDisplay(displayID: 1, origin: CGPoint(x: 100, y: 50), pointSize: CGSize(width: 1512, height: 982))
    static let settings = HostInputSettings(doubleClickIntervalMs: 500, keyRepeatDelayMs: 225, keyRepeatIntervalMs: 30,
                                            inputSourceID: "com.apple.keylayout.Colemak")
    static let hello = Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                             decodeCapabilities: [.hevcMain], keyboardType: .ansi)
    /// The Mac's real cursor at connect, global points → (300, 250) display-relative.
    static let startCursor = CGPoint(x: 400, y: 300)
    static let keyA = PhysicalKey(page: PhysicalKey.keyboardPage, usage: 0x04)
    static let keyB = PhysicalKey(page: PhysicalKey.keyboardPage, usage: 0x05)

    // MARK: Fakes

    /// The Mac: records sink calls and moves its cursor where injected pointer events put it.
    final class VirtualMac: InputSink, DisplayProvider {
        enum Call: Equatable, Sendable {
            case key(KeyEvent), move(PointerMove), button(PointerButton), scroll(Scroll), releaseAll
            case displayOrigin(CGPoint), keyboardType(KeyboardType)
        }

        let display: HostDisplay
        private struct State { var calls: [Call] = []; var origin = CGPoint.zero; var cursor: CGPoint }
        private let state: Mutex<State>

        init(display: HostDisplay, cursor: CGPoint) {
            self.display = display
            state = Mutex(State(cursor: cursor))
        }

        var calls: [Call] { state.withLock { $0.calls } }
        var inputCalls: [Call] {
            calls.filter {
                switch $0 {
                case .displayOrigin, .keyboardType: false
                default: true
                }
            }
        }
        /// The Mac's own mouse (or an app) moves the cursor.
        func setCursor(global: CGPoint) { state.withLock { $0.cursor = global } }

        func key(_ event: KeyEvent) { state.withLock { $0.calls.append(.key(event)) } }
        func move(_ m: PointerMove) {
            state.withLock { s in
                s.calls.append(.move(m))
                s.cursor = CGPoint(x: s.origin.x + m.x, y: s.origin.y + m.y)
            }
        }
        func button(_ b: PointerButton) {
            state.withLock { s in
                s.calls.append(.button(b))
                s.cursor = CGPoint(x: s.origin.x + b.x, y: s.origin.y + b.y)
            }
        }
        func scroll(_ s: Scroll) { state.withLock { $0.calls.append(.scroll(s)) } }
        func releaseAll() { state.withLock { $0.calls.append(.releaseAll) } }
        func setDisplayOrigin(_ origin: CGPoint) {
            state.withLock { $0.calls.append(.displayOrigin(origin)); $0.origin = origin }
        }
        func setKeyboardType(_ type: KeyboardType) { state.withLock { $0.calls.append(.keyboardType(type)) } }

        func targetDisplay() -> HostDisplay { display }
        func cursorLocation() -> CGPoint? { state.withLock { $0.cursor } }
    }

    final class FakePower: PowerAssertions {
        private let state = Mutex((holding: false, begins: 0, ends: 0))
        var holding: Bool { state.withLock { $0.holding } }
        var begins: Int { state.withLock { $0.begins } }
        func beginPreventingDisplaySleep() { state.withLock { $0.holding = true; $0.begins += 1 } }
        func endPreventingDisplaySleep() { state.withLock { $0.holding = false; $0.ends += 1 } }
        func declareUserActivity() {}
    }

    /// Counts `setSecret` calls: a pairing stores a secret, a re-authentication doesn't.
    final class CountingSecrets: SecretStore {
        let inner = InMemorySecretStore()
        private let writes = Atomic<Int>(0)
        var writeCount: Int { writes.load(ordering: .relaxed) }
        func secret(for peer: String) throws -> [UInt8]? { inner.secret(for: peer) }
        func setSecret(_ secret: [UInt8], for peer: String) throws {
            writes.add(1, ordering: .relaxed)
            inner.setSecret(secret, for: peer)
        }
        func removeSecret(for peer: String) throws { inner.removeSecret(for: peer) }
    }

    final class Recorder<T: Sendable>: Sendable {
        private let items = Mutex<[T]>([])
        func put(_ v: T) { items.withLock { $0.append(v) } }
        var all: [T] { items.withLock { $0 } }
        var last: T? { items.withLock { $0.last } }
    }

    // MARK: Rig

    final class Rig {
        let mac = VirtualMac(display: InputLoopbackTests.display, cursor: InputLoopbackTests.startCursor)
        let power = FakePower()
        let hostSecrets = CountingSecrets()
        let clientSecrets = CountingSecrets()
        let clientStatus = Recorder<ClientSession.Status>()
        let hostStatus = Recorder<HostStatus>()
        let client: ClientSession
        let mux: FakeUSBMuxd
        let host: HostSession
        /// The same calls, replayed on a standalone pipeline.
        let oracle: ClientInputPipeline
        let oracleOut = Recorder<Message>()

        init() throws {
            let clientStatus = clientStatus, hostStatus = hostStatus, oracleOut = oracleOut
            client = try ClientSession(port: 0, secrets: clientSecrets, hello: InputLoopbackTests.hello) { clientStatus.put($0) }
            mux = try FakeUSBMuxd(devices: [.init(deviceID: 7, serialNumber: "IPAD-7")], targetPort: client.port)
            let deps = HostSession.Dependencies(
                usbmux: USBMuxClient(socketPath: mux.socketPath), secrets: hostSecrets, sink: mac, display: mac,
                power: power, settings: { InputLoopbackTests.settings })
            host = HostSession(dependencies: deps) { hostStatus.put($0) }
            oracle = ClientInputPipeline { oracleOut.put($0) }
        }

        func tearDown() {
            host.stop()
            mux.stop()
            client.stop()
        }

        var clientConfigured: Bool {
            if case .connected(let info) = clientStatus.last { info.isConfigured } else { false }
        }

        /// Runs `body` on the client's input queue and on the oracle.
        func drive(_ body: (ClientInputPipeline) -> Void) {
            body(oracle)
            client.input.sync(body)
        }

        /// The oracle's output since the last call, as the sink calls it should produce.
        private let consumed = Mutex(0)
        func expectedSinkCalls() -> [VirtualMac.Call] {
            let all = oracleOut.all
            let fresh = consumed.withLock { n in
                defer { n = all.count }
                return Array(all[n...])
            }
            return fresh.compactMap {
                switch $0 {
                case .keyEvent(let e): .key(e)
                case .pointerMove(let m): .move(m)
                case .pointerButton(let b): .button(b)
                case .scroll(let s): .scroll(s)
                case .releaseAll: .releaseAll
                default: nil
                }
            }
        }
    }

    /// Waits until the sink's input calls after `mark` number `expected.count`, then compares.
    func expectSink(_ rig: Rig, from mark: Int, _ expected: [VirtualMac.Call],
                    sourceLocation: SourceLocation = #_sourceLocation) async {
        let arrived = await eventually { rig.mac.inputCalls.count >= mark + expected.count }
        #expect(arrived, "sink got \(rig.mac.inputCalls.count - mark) of \(expected.count) calls", sourceLocation: sourceLocation)
        let got = Array(rig.mac.inputCalls.dropFirst(mark))
        #expect(got == expected, sourceLocation: sourceLocation)
    }

    // MARK: The test

    @Test func inputFlowsEndToEndAndEverythingIsReleasedOnDetach() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.host.start()

        // Handshake: pairing, Hello → HelloAck, bounds applied on the client, first warp to the Mac cursor.
        #expect(await eventually { rig.clientConfigured })
        guard case .connected(let info) = rig.clientStatus.last else { Issue.record("not connected"); return }
        #expect(info.displayPointWidth == 1512 && info.displayPointHeight == 982)
        #expect(info.macInputSource == "com.apple.keylayout.Colemak")
        #expect(await eventually { rig.hostStatus.last == .connected(deviceModel: "iPad16,6") })
        #expect(rig.power.holding)
        #expect(rig.mac.calls.prefix(2) == [.keyboardType(.ansi), .displayOrigin(CGPoint(x: 100, y: 50))])
        #expect(rig.hostSecrets.writeCount == 1 && rig.clientSecrets.writeCount == 1)   // paired once
        #expect(await eventually { rig.client.input.cursor.x == 300 && rig.client.input.cursor.y == 250 })
        #expect(rig.client.input.cursor.displayPointWidth == 1512 && rig.client.input.cursor.displayPointHeight == 982)
        rig.client.input.sync { p in
            #expect(p.isConfigured && p.pointer.width == 1512 && p.pointer.height == 982)
            #expect(p.keyRepeat.delayNs == 225_000_000 && p.keyRepeat.intervalNs == 30_000_000)
        }
        rig.oracle.configure(.host(display: Self.display, settings: Self.settings))
        rig.oracle.warp(x: 300, y: 250)

        let t0 = MonotonicClock.now()
        func at(_ ms: Double) -> UInt64 { t0 + UInt64(ms * 1e6) }

        // 1. Keys: Opt-Tab → Cmd-Tab with hold semantics (Tab twice while Opt stays down), then a
        //    held key repeating at the Mac's rate, then ReleaseAll(.focusLost) with keys held.
        var mark = rig.mac.inputCalls.count
        rig.drive { p in
            p.keyChanged(.leftOption, isDown: true, at: at(0))
            p.keyChanged(.tab, isDown: true, at: at(10))
            p.keyChanged(.tab, isDown: false, at: at(40))
            p.keyChanged(.tab, isDown: true, at: at(80))
            p.keyChanged(.tab, isDown: false, at: at(110))
            p.keyChanged(.leftOption, isDown: false, at: at(150))
            p.keyChanged(Self.keyA, isDown: true, at: at(200))
            p.tick(at: at(300))   // before the delay: nothing
            p.tick(at: at(426))   // 200 + 225: first repeat
            p.tick(at: at(457))   // + 30: second repeat
            p.keyChanged(Self.keyA, isDown: false, at: at(470))
            p.keyChanged(.leftShift, isDown: true, at: at(500))
            p.keyChanged(Self.keyB, isDown: true, at: at(510))
            p.releaseAll(.focusLost)
            p.keyChanged(Self.keyB, isDown: false, at: at(600))       // orphans after ReleaseAll: dropped
            p.keyChanged(.leftShift, isDown: false, at: at(610))
        }
        let keys = rig.expectedSinkCalls()
        let keyUsages: [String] = keys.map {
            switch $0 {
            case .key(let e): "\(String(e.usage, radix: 16))\(e.isDown ? "↓" : "↑")\(e.isRepeat ? "r" : "")"
            case .releaseAll: "R"
            default: "?"
            }
        }
        #expect(keyUsages == ["e2↓", "e2↑", "e3↓", "2b↓", "2b↑", "2b↓", "2b↑", "e3↑",
                              "4↓", "4↓r", "4↓r", "4↑", "e1↓", "5↓", "R"])
        if case .key(let tab) = keys[3] { #expect(tab.modifiers == [.command]) }
        await expectSink(rig, from: mark, keys)

        // 2. Pointer: moves (y up-positive in, y-down out), a drag, a double click, a right click.
        mark = rig.mac.inputCalls.count
        rig.drive { p in
            p.mouseMoved(dx: 10, dy: 5, at: at(1000))
            p.mouseMoved(dx: 0, dy: 0, at: at(1008))   // zero delta: ignored
            p.mouseMoved(dx: 10, dy: 5, at: at(1016))
            p.mouseButton(.left, isDown: true, at: at(1100))
            p.mouseMoved(dx: 20, dy: -10, at: at(1110))
            p.mouseMoved(dx: 20, dy: -10, at: at(1118))
            p.mouseButton(.left, isDown: false, at: at(1200))
            p.mouseButton(.left, isDown: true, at: at(1500))
            p.mouseButton(.left, isDown: false, at: at(1520))
            p.mouseButton(.left, isDown: true, at: at(1600))
            p.mouseButton(.left, isDown: false, at: at(1620))
            p.mouseButton(.right, isDown: true, at: at(1800))
            p.mouseButton(.right, isDown: false, at: at(1810))
        }
        let pointer = rig.expectedSinkCalls()
        let moves = pointer.compactMap { if case .move(let m) = $0 { m } else { nil } }
        let buttons = pointer.compactMap { if case .button(let b) = $0 { b } else { nil } }
        #expect(moves.count == 4)
        #expect(moves[0].x > 300 && moves[0].y < 250)             // right and up
        #expect(moves[1].buttons == 0 && moves[2].buttons == 1 && moves[3].buttons == 1)   // drag
        #expect(moves[3].y > moves[1].y)                            // dragged down
        #expect(buttons.map(\.clickCount) == [1, 1, 1, 1, 2, 2, 1, 1])
        #expect(buttons.last?.button == .right)
        await expectSink(rig, from: mark, pointer)

        // 3. Scroll: a fling, then momentum ticks at 120 Hz until it dies out.
        mark = rig.mac.inputCalls.count
        rig.drive { p in
            p.scrollBegan(at: at(2000))
            for i in 1...6 { p.scrollChanged(dx: 0, dy: -20, at: at(2000 + Double(i) * 8.33)) }
            p.scrollEnded(at: at(2055))
            for i in 1...600 { p.tick(at: at(2055 + Double(i) * 8.33)) }
        }
        let scroll = rig.expectedSinkCalls().compactMap { if case .scroll(let s) = $0 { s } else { nil } }
        #expect(scroll.first == Scroll(dx: 0, dy: -20, phase: .began, momentumPhase: .none))
        #expect(scroll.contains(Scroll(dx: 0, dy: 0, phase: .ended, momentumPhase: .none)))
        let momentum = scroll.filter { $0.momentumPhase != .none }
        #expect(momentum.first?.momentumPhase == .began && momentum.last?.momentumPhase == .ended)
        #expect(momentum.count > 10 && momentum.dropLast().allSatisfy { $0.dy < 0 && $0.phase == .none })
        await expectSink(rig, from: mark, scroll.map { .scroll($0) })

        // 4. Pinch past the ×1.25 threshold each way → Cmd-= then Cmd-−; rotate is ignored.
        mark = rig.mac.inputCalls.count
        rig.drive { p in
            p.gesture(.magnify, phase: .began, value: 0.1, at: at(8000))
            p.gesture(.magnify, phase: .changed, value: 0.1, at: at(8010))   // scale 1.2
            p.gesture(.magnify, phase: .changed, value: 0.1, at: at(8020))   // 1.3: one step in
            p.gesture(.magnify, phase: .ended, value: 0, at: at(8030))
            p.gesture(.rotate, phase: .began, value: 0.3, at: at(8100))
            p.gesture(.rotate, phase: .ended, value: 0, at: at(8110))
            p.gesture(.magnify, phase: .began, value: -0.1, at: at(8200))
            p.gesture(.magnify, phase: .changed, value: -0.15, at: at(8210))  // 0.75: one step out
            p.gesture(.magnify, phase: .ended, value: 0, at: at(8220))
        }
        #expect(rig.expectedSinkCalls().isEmpty)   // gestures only
        func zoom(_ usage: UInt16) -> [VirtualMac.Call] {
            [.key(KeyEvent(usage: 0xE3, isDown: true, modifiers: [.command])),
             .key(KeyEvent(usage: usage, isDown: true, modifiers: [.command])),
             .key(KeyEvent(usage: usage, isDown: false, modifiers: [.command])),
             .key(KeyEvent(usage: 0xE3, isDown: false, modifiers: []))]
        }
        await expectSink(rig, from: mark, zoom(0x2E) + zoom(0x2D))

        // 5. The Mac's own mouse moves the cursor: the client follows (CursorWarp, §5.4).
        #expect(rig.mac.cursorLocation() == CGPoint(x: 100 + moves[3].x, y: 50 + moves[3].y))
        rig.mac.setCursor(global: CGPoint(x: 1100, y: 650))
        #expect(await eventually { rig.client.input.cursor.x == 1000 && rig.client.input.cursor.y == 600 })
        rig.oracle.warp(x: 1000, y: 600)

        // 6. Detach with a key, a modifier and a button held (invariant 4).
        mark = rig.mac.inputCalls.count
        rig.drive { p in
            p.keyChanged(.leftCommand, isDown: true, at: at(9000))
            p.keyChanged(Self.keyA, isDown: true, at: at(9010))
            p.mouseButton(.left, isDown: true, at: at(9020))
        }
        let held = rig.expectedSinkCalls()
        #expect(held.count == 3)
        await expectSink(rig, from: mark, held)
        rig.mux.detach(deviceID: 7)
        #expect(await eventually { rig.mac.inputCalls.last == .releaseAll })
        #expect(await eventually { rig.hostStatus.last == .waitingForIPad })
        #expect(await eventually { !rig.power.holding })
        #expect(await eventually { if case .listening = rig.clientStatus.last { true } else { false } })
        rig.client.input.sync { p in
            #expect(p.keyboard.macHeldKeys.isEmpty && p.heldButtons.mask == 0 && !p.keyRepeat.isRepeating)
        }
        let afterRelease = rig.mac.inputCalls.count
        #expect(Array(rig.mac.inputCalls.dropFirst(mark)) == held + [.releaseAll])

        // 7. Replug: the host redials, re-authenticates with the stored secret (no new pairing), and
        //    input flows again. Key-ups for keys held before the detach are orphans and send nothing.
        rig.mux.attach(.init(deviceID: 7, serialNumber: "IPAD-7"))
        #expect(await eventually { rig.hostStatus.last == .connected(deviceModel: "iPad16,6") })
        #expect(await eventually { rig.clientConfigured })
        #expect(rig.hostSecrets.writeCount == 1 && rig.clientSecrets.writeCount == 1)
        #expect(rig.power.holding && rig.power.begins == 2)
        rig.client.input.sync { p in
            p.keyChanged(.leftCommand, isDown: false, at: at(12000))
            p.keyChanged(Self.keyA, isDown: false, at: at(12010))
            p.mouseButton(.left, isDown: false, at: at(12020))
            p.keyChanged(Self.keyB, isDown: true, at: at(12100))
            p.keyChanged(Self.keyB, isDown: false, at: at(12150))
        }
        await expectSink(rig, from: afterRelease, [.key(KeyEvent(usage: 0x05, isDown: true, modifiers: [])),
                                                  .key(KeyEvent(usage: 0x05, isDown: false, modifiers: []))])

        // 8. stop() releases synchronously.
        rig.host.stop()
        #expect(rig.mac.inputCalls.last == .releaseAll)
        #expect(!rig.power.holding)
    }
}

/// Polls `condition` until it holds or `seconds` pass.
private func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
#endif
