import AVFAudio
import Foundation
import LainClientCore
import Speech
import Synchronization
import os

/// On-device live streaming dictation on Apple TV (`SpeechAnalyzer` + `SpeechTranscriber`), plus a
/// hardware/API probe to verify exactly which microphones and speech models tvOS exposes on live hardware.
@MainActor
final class TVDictation {
    enum State: Equatable {
        case idle
        case preparing(String)
        case listening(micName: String)
        case failed(String)
    }

    struct ProbeReport: Sendable, Equatable {
        var model: String
        var osVersion: String
        var recordPermission: String
        var playAndRecordError: String?
        var isInputAvailable: Bool
        var availableInputs: [String]
        var activeRouteInputs: [String]
        var engineInputFormat: String
        var speechAvailable: Bool
        var supportedLocale: String?
        var installedLocales: [String]
        var needsAssetDownload: Bool?

        /// Compact multi-line summary for the tvOS overlay and Xcode console.
        var summary: String {
            var lines: [String] = []
            lines.append("Device: \(model) · \(osVersion)")
            let inputsText = availableInputs.isEmpty ? "none" : availableInputs.joined(separator: ", ")
            let routeText = activeRouteInputs.isEmpty ? "none" : activeRouteInputs.joined(separator: ", ")
            lines.append("Mic perm: \(recordPermission) · inputAvail: \(isInputAvailable)")
            if let err = playAndRecordError {
                lines.append("PlayAndRecord error: \(err)")
            }
            lines.append("Available inputs: \(inputsText)")
            lines.append("Routed inputs: \(routeText) · fmt: \(engineInputFormat)")
            let loc = supportedLocale ?? "none"
            let dl = needsAssetDownload.map { $0 ? "download needed" : "ready" } ?? "unknown"
            lines.append("SpeechTranscriber: avail=\(speechAvailable) · locale=\(loc) (\(dl)) · installed=\(installedLocales.count)")
            return lines.joined(separator: "\n")
        }
    }

    private(set) var state = State.idle { didSet { if state != oldValue { onState(state) } } }
    private(set) var lastProbe: ProbeReport?
    var onState: (State) -> Void = { _ in }
    var onPartial: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    var onProbeUpdated: (ProbeReport) -> Void = { _ in }

    var isActive: Bool {
        switch state {
        case .preparing, .listening: true
        case .idle, .failed: false
        }
    }

    /// Latest audio RMS level (`0...1`) observed by the input tap, to confirm non-zero mic signal.
    var liveLevel: Float { meter.value }
    private let meter = AudioMeter()

    private var run: Task<Void, Never>?
    private var generation = 0
    private var engine: AVAudioEngine?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var pending = ""
    private var lastTyped: Character?
    private static let log = Logger(subsystem: "lain", category: "dictation")

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        lastTyped = nil
        pending = ""
        meter.set(0)
        state = .preparing("Starting live dictation…")
        generation += 1
        let mine = generation
        run = Task { [weak self] in
            do {
                try await self?.listen()
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == mine, self.state != .idle else { return }
                Self.log.error("TV dictation failed: \(String(describing: error), privacy: .public)")
                self.tearDown()
                self.state = .failed("\(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard isActive else { return }
        finish()
    }

    /// Probes microphone routes and `SpeechTranscriber` availability on this Apple TV without
    /// starting a transcription session (safe to run at launch or from the overlay).
    func runProbe(requestPermission: Bool = false) async -> ProbeReport {
        if requestPermission {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        let session = AVAudioSession.sharedInstance()
        let permStr: String = switch AVAudioApplication.shared.recordPermission {
        case .granted: "granted"
        case .denied: "denied"
        case .undetermined: "undetermined"
        @unknown default: "unknown"
        }

        var categoryError: String?
        if !isActive {
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
                try session.setActive(true)
            } catch {
                categoryError = error.localizedDescription
            }
        }

        let isInputAvail = session.isInputAvailable
        let avail = (session.availableInputs ?? []).map { "\($0.portName) [\($0.portType.rawValue)]" }
        let routed = session.currentRoute.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }

        let fmtDesc: String
        if isInputAvail {
            let probeEngine = AVAudioEngine()
            let fmt = probeEngine.inputNode.outputFormat(forBus: 0)
            fmtDesc = "\(Int(fmt.sampleRate))Hz/\(fmt.channelCount)ch"
        } else {
            fmtDesc = "no input"
        }

        if !isActive {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }

        let speechAvail = SpeechTranscriber.isAvailable
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
        var needsDownload: Bool?
        if let locale {
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            if (try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])) != nil {
                needsDownload = true
            } else {
                needsDownload = false
            }
        }

        let report = ProbeReport(
            model: ClientStatus.hardwareModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            recordPermission: permStr,
            playAndRecordError: categoryError,
            isInputAvailable: isInputAvail,
            availableInputs: avail,
            activeRouteInputs: routed,
            engineInputFormat: fmtDesc,
            speechAvailable: speechAvail,
            supportedLocale: locale?.identifier,
            installedLocales: installed,
            needsAssetDownload: needsDownload
        )
        Self.log.notice("TV dictation probe:\n\(report.summary, privacy: .public)")
        lastProbe = report
        onProbeUpdated(report)
        return report
    }

    // MARK: Private

    private func finish() {
        run?.cancel()
        if !pending.isEmpty { type(pending) }
        pending = ""
        onPartial("")
        let analyzer = self.analyzer
        tearDown()
        Task { await analyzer?.cancelAndFinishNow() }
        state = .idle
    }

    private func listen() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw Failure("Microphone permission denied (allow lain in Settings › Privacy & Security › Microphone)")
        }
        guard SpeechTranscriber.isAvailable else {
            throw Failure("SpeechTranscriber is unavailable on this Apple TV")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw Failure("No SpeechTranscriber locale for \(Locale.current.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            state = .preparing("Downloading speech model for \(locale.identifier)…")
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .mixWithOthers])
        } catch {
            Self.log.notice("measurement mode failed (\(error.localizedDescription, privacy: .public)); falling back to default")
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
        }
        try session.setActive(true)

        let avail = session.availableInputs ?? []
        let availDesc = avail.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        Self.log.notice("TV dictation availableInputs (isInputAvailable=\(session.isInputAvailable)): \(availDesc, privacy: .public)")

        // Prefer a remote/handheld/Bluetooth mic if exposed alongside a built-in mic.
        if let preferred = avail.first(where: { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE || $0.portType == .continuityMicrophone }) {
            try? session.setPreferredInput(preferred)
        }

        guard session.isInputAvailable else {
            throw Failure("No microphone input available (availableInputs: \(availDesc.isEmpty ? "none" : availDesc))")
        }

        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw Failure("Audio input node has invalid format (\(Int(format.sampleRate))Hz/\(format.channelCount)ch; inputs: \(availDesc))")
        }

        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)
        guard !Task.isCancelled else { return await analyzer.cancelAndFinishNow() }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(converter, into: feed, meter: meter))
        engine.prepare()
        try engine.start()
        (self.engine, self.feed, self.analyzer) = (engine, feed, analyzer)

        let activeMic = session.currentRoute.inputs.first.map { "\($0.portName) [\($0.portType.rawValue)]" } ?? "Unknown mic"
        Self.log.notice("TV dictation listening on \(activeMic, privacy: .public) (\(Int(format.sampleRate))Hz/\(format.channelCount)ch)")
        state = .listening(micName: activeMic)

        for try await result in transcriber.results {
            let text = String(result.text.characters)
            Self.log.debug("TV dictation result final=\(result.isFinal) chars=\(text.count)")
            if result.isFinal {
                pending = ""
                onPartial("")
                type(text)
            } else {
                pending = text
                onPartial(text)
            }
        }
        finish()
    }

    private nonisolated static func tap(_ converter: sending AnalyzerInputConverter,
                                        into feed: AsyncStream<AnalyzerInput>.Continuation,
                                        meter: AudioMeter) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let converter = converter
        return { buffer, time in
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { let s = ch[i]; sum += s * s }
                let rms = n > 0 ? sqrt(sum / Float(n)) : 0
                meter.set(rms)
            }
            guard let inputs = try? converter.convert(buffer, at: time) else { return }
            for input in inputs { feed.yield(input) }
        }
    }

    private func type(_ text: String) {
        guard let first = text.first else { return }
        var out = text
        if let last = lastTyped, !last.isWhitespace, !first.isWhitespace, !first.isPunctuation { out = " " + out }
        lastTyped = out.last
        onFinal(out)
    }

    private func tearDown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        feed?.finish()
        (engine, feed, analyzer) = (nil, nil, nil)
        meter.set(0)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    private struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ why: String) { errorDescription = why }
    }
}

private final class AudioMeter: Sendable {
    private let bits = Atomic<UInt32>(0)
    var value: Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    func set(_ value: Float) { bits.store(value.bitPattern, ordering: .relaxed) }
}
