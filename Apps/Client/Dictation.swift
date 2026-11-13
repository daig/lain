import AVFAudio
import Speech
import os

/// Dictation on the iPad, for the host: the microphone into Apple's on-device recognizer
/// (`SpeechAnalyzer` with a `DictationTranscriber`), which reports text as it firms up. What is still
/// changing (`onPartial`) is only shown; what is final (`onFinal`) is typed on the host, so nothing typed
/// there is ever taken back.
@MainActor
final class Dictation {
    enum State: Equatable {
        case idle
        /// Getting ready: asking for the microphone, or fetching the language's speech model.
        case preparing(String)
        case listening
        case failed(String)
    }

    private(set) var state = State.idle { didSet { if state != oldValue { onState(state) } } }
    var onState: (State) -> Void = { _ in }
    /// The words still being worked out since the last final text ("" once they are final).
    var onPartial: (String) -> Void = { _ in }
    /// Text that won't change again, ready to type; spaced to follow what came before it.
    var onFinal: (String) -> Void = { _ in }

    var isActive: Bool { state != .idle && !isFailed }
    private var isFailed: Bool { if case .failed = state { true } else { false } }

    private var run: Task<Void, Never>?
    /// Counts the dictations started, so that an earlier one's late ending can't touch the current one.
    private var generation = 0
    private var engine: AVAudioEngine?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    /// What the recognizer has heard but not made final yet: typed as it stands if it never does.
    private var pending = ""
    /// The last character typed in this dictation, to space the next piece.
    private var lastTyped: Character?
    private static let log = Logger(subsystem: "lain", category: "dictation")

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        lastTyped = nil
        pending = ""
        state = .preparing("Starting dictation…")
        generation += 1
        let mine = generation
        run = Task { [weak self] in
            do { try await self?.listen() } catch is CancellationError {} catch {
                // Stopped, or a later dictation is running: the recognizer's ending isn't a failure.
                guard let self, self.generation == mine, self.state != .idle else { return }
                Self.log.error("dictation failed: \(String(describing: error), privacy: .public)")
                self.tearDown()
                self.state = .failed("Dictation isn't available: \(error.localizedDescription)")
            }
        }
    }

    /// Stops listening. What was heard but not yet made final is typed at once, as it stands: waiting for the
    /// recognizer to finish it took seconds and seldom changed it.
    func stop() {
        guard isActive else { return }
        finish()
    }

    /// Ends the dictation now: types what was heard but never made final, and lets go of everything.
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
            throw Failure("allow the microphone for lain in Settings")
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw Failure("no dictation for \(Locale.current.identifier)")
        }
        let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                               reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            state = .preparing("Downloading the speech model for \(locale.identifier)…")
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()

        let session = AVAudioSession.sharedInstance()
        // Playing and recording, so the host's sound (muted while listening) comes back afterwards.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)
        guard !Task.isCancelled else { return await analyzer.cancelAndFinishNow() }   // stopped while getting ready
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(converter, into: feed))
        engine.prepare()
        try engine.start()
        (self.engine, self.feed, self.analyzer) = (engine, feed, analyzer)
        state = .listening

        for try await result in transcriber.results {
            let text = String(result.text.characters)
            Self.log.debug("dictation result final=\(result.isFinal) chars=\(text.count)")
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

    /// The audio thread's block: made outside the main actor, which it must not inherit.
    private nonisolated static func tap(_ converter: sending AnalyzerInputConverter,
                                        into feed: AsyncStream<AnalyzerInput>.Continuation) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let converter = converter   // used by the tap alone
        return { buffer, time in
            guard let inputs = try? converter.convert(buffer, at: time) else { return }
            for input in inputs { feed.yield(input) }
        }
    }

    /// Final text, with a space before it where the piece before left none.
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
        // Back to playing only (the host's sound), with the session left active.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    private struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ why: String) { errorDescription = why }
    }
}
