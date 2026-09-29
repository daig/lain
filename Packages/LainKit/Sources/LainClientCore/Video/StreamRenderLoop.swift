import Foundation
import Metal
import QuartzCore
import Synchronization

/// Drives the stream's `CAMetalLayer` from a `CAMetalDisplayLink` at 120 Hz on a dedicated render
/// thread (§6.2): each tick runs the input tick (momentum, key repeat), takes the newest decoded frame
/// from the pipeline's latest-wins slot, and draws frame + cursor in one pass. Ticks where nothing
/// changed (same frame, cursor, sprite and size) present nothing.
///
/// The layer is configured here: Display P3, `bgr10a2Unorm`, framebuffer-only, two drawables, opaque.
/// The owning view sets `layer.frame`, `contentsScale` and `drawableSize` on layout.
public final class StreamRenderLoop: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    public typealias CursorPosition = @Sendable () -> (x: Double, y: Double)?
    public typealias DisplayPointSize = @Sendable () -> (width: Double, height: Double)?

    public let layer: CAMetalLayer
    public let video: ClientVideoPipeline
    // Render thread only (after start):
    private let renderer: VideoRenderer
    private let cursorPosition: CursorPosition
    private let displayPointSize: DisplayPointSize
    private let tick: @Sendable () -> Void
    private var link: CAMetalDisplayLink?
    private var current: DecodedFrame?
    private var session: UInt64 = .max
    private var sprite: (version: UInt64, sprite: CursorSprite, macVisible: Bool)?
    private var last = LastDrawn()
    private let stopped = Atomic<Bool>(false)

    private struct LastDrawn: Equatable {
        var frameId: UInt32?
        var cursor: SIMD2<Double>?
        var spriteKey: UInt64?
        var points: SIMD2<Double>?
        var width = 0
        var height = 0
    }

    /// - Parameters:
    ///   - cursorPosition: the cursor in streamed-display points, nil when it's on another display.
    ///   - displayPointSize: the streamed display's size in points (cursor space), nil when unknown.
    ///   - tick: called first on every display-link tick (the input pipeline's tick).
    public init(video: ClientVideoPipeline, cursorPosition: @escaping CursorPosition,
                displayPointSize: @escaping DisplayPointSize, tick: @escaping @Sendable () -> Void) throws {
        renderer = try VideoRenderer(pixelFormat: .bgr10a2Unorm)
        self.video = video
        self.cursorPosition = cursorPosition
        self.displayPointSize = displayPointSize
        self.tick = tick
        layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgr10a2Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.isOpaque = true
        super.init()
    }

    /// Starts the render thread and the display link.
    public func start() {
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.preferredFrameLatency = 1
        self.link = link
        let thread = Thread { [self] in
            // `self.link` is written before the thread starts and read only here and by the delegate.
            guard let link = self.link else { return }
            link.add(to: .current, forMode: .default)
            while !stopped.load(ordering: .relaxed) {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
            }
            link.invalidate()
        }
        thread.name = "lain.render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func stop() { stopped.store(true, ordering: .relaxed) }

    // MARK: CAMetalDisplayLinkDelegate (render thread)

    public func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        tick()

        let generation = video.sessionGeneration
        if generation != session {
            session = generation
            current = nil
            renderer.flush()
        }
        if let newest = video.latest.take() { current = newest }

        let overlay = video.cursor
        let version = overlay.version
        if sprite?.version != version {
            let c = overlay.current
            sprite = (version, c.sprite, c.macVisible)
        }
        let showCursor = (sprite?.macVisible ?? true) && !overlay.isHiddenForTyping
        let point = showCursor ? cursorPosition().map { SIMD2($0.x, $0.y) } : nil
        let points = displayPointSize().flatMap { $0.width > 0 && $0.height > 0 ? SIMD2($0.width, $0.height) : nil }

        let texture = update.drawable.texture
        let now = LastDrawn(frameId: current?.frameId, cursor: point, spriteKey: point == nil ? nil : sprite?.sprite.key,
                            points: points, width: texture.width, height: texture.height)
        guard now != last else { return }   // nothing changed: present nothing
        last = now

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }
        let scene = VideoRenderer.Scene(frame: current, displayPointSize: points, cursorPoint: point,
                                        cursorSprite: point == nil ? nil : sprite?.sprite)
        renderer.encode(scene, into: commandBuffer, target: texture)
        commandBuffer.present(update.drawable)
        commandBuffer.commit()
        if let frame = current {
            video.presented(frame.frameId, receivedNs: frame.receivedNs,
                            at: UInt64(max(update.targetPresentationTimestamp, 0) * 1e9))
        }
    }
}
