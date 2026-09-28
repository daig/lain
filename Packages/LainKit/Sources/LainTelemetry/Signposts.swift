import os

/// Logging and pipeline signposts: subsystem "lain", one category per component (§12).
public enum Telemetry {
    public static let subsystem = "lain"

    public static func logger(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }

    /// Signposts for pipeline stages, visible in Instruments' os_signpost track.
    public static let pipeline = OSSignposter(subsystem: subsystem, category: "pipeline")
}

/// Pipeline stages marked with signposts, one interval per frame.
public enum PipelineStage: String, Sendable, CaseIterable {
    case capture, encode, send, receive, decode, present

    public var name: StaticString {
        switch self {
        case .capture: "capture"
        case .encode: "encode"
        case .send: "send"
        case .receive: "receive"
        case .decode: "decode"
        case .present: "present"
        }
    }
}

extension OSSignposter {
    /// Begins a per-frame interval for `stage`; end it with `endInterval(stage.name, state)`.
    public func begin(_ stage: PipelineStage, frame: UInt32) -> OSSignpostIntervalState {
        beginInterval(stage.name, id: makeSignpostID(), "frame \(frame)")
    }

    public func end(_ stage: PipelineStage, _ state: OSSignpostIntervalState) {
        endInterval(stage.name, state)
    }
}
