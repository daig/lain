#if os(macOS)
import LainClientCore
import LainHostCore
import LainProtocol
import LainTestSupport
import LainTransport
import LainUSBMux
import Testing

/// The same `--bench usbmux` code the owner runs against the iPad (S1), against the fake usbmuxd and
/// the client endpoint running on the Mac.
@Test func usbmuxBenchRunsEndToEndOverTheFakeDaemon() async throws {
    let hello = Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                      decodeCapabilities: [.hevcMain], keyboardType: .ansi)
    let endpoint = try ClientEndpoint(port: 0, secrets: InMemorySecretStore(), hello: hello) { _ in }
    defer { endpoint.stop() }
    let mux = try FakeUSBMuxd(devices: [.init(deviceID: 5, serialNumber: "IPAD-SERIAL")], targetPort: endpoint.port)
    defer { mux.stop() }
    var options = USBMuxBench.Options()
    options.pings = 50
    options.keyframes = 10
    options.sustainSeconds = 0.5
    options.waitForDeviceSeconds = 2
    let report = try await USBMuxBench.run(usbmux: USBMuxClient(socketPath: mux.socketPath), options: options, log: { _ in })
    print(report)
    #expect(report.device.deviceID == 5)
    #expect(report.rttUs.p50 > 0 && report.keyframeMs.p50 > 0 && report.sustainedMBps > 10)
}

@Test func benchFailsCleanlyWithoutADevice() async throws {
    let mux = try FakeUSBMuxd(devices: [], targetPort: 1)
    defer { mux.stop() }
    var options = USBMuxBench.Options()
    options.waitForDeviceSeconds = 0.3
    await #expect(throws: USBMuxBench.Failure.self) {
        _ = try await USBMuxBench.run(usbmux: USBMuxClient(socketPath: mux.socketPath), options: options, log: { _ in })
    }
}
#endif
