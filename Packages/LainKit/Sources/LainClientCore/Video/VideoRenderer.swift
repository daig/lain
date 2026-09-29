import CoreVideo
import Foundation
import LainProtocol
import Metal
import simd

/// The client's Metal renderer core (§6.2), platform-neutral so it runs on the Mac in tests.
///
/// One render pass per tick: clear to black, draw the newest decoded frame (biplanar Y + CbCr
/// textures from a `CVMetalTextureCache`, converted to RGB with the stream's matrix and range), then
/// the cursor sprite with premultiplied-alpha blending. The output is written **without any transfer
/// function conversion**: the stream carries Display P3 with the sRGB transfer, which is exactly what
/// a Display P3 `CAMetalLayer` expects of its (non-sRGB-format) drawable, so colors are never converted
/// (D7). At 1:1 the frame is sampled nearest-neighbour; otherwise it's aspect-fit and filtered.
///
/// Not thread-safe: use it from one render thread.
public final class VideoRenderer {
    public enum RendererError: Error { case noDevice, textureCache(CVReturn), shader(String) }

    /// What to draw this tick.
    public struct Scene {
        /// nil before the first frame: only the cursor (over black) is drawn.
        public var frame: DecodedFrame?
        /// The streamed display's size in points (cursor space). nil: the frame at 2× (HiDPI).
        public var displayPointSize: SIMD2<Double>?
        /// Cursor position in streamed-display points (top-left origin); nil when off this display.
        public var cursorPoint: SIMD2<Double>?
        /// nil hides the cursor (typing, or the Mac hid it).
        public var cursorSprite: CursorSprite?

        public init(frame: DecodedFrame? = nil, displayPointSize: SIMD2<Double>? = nil, cursorPoint: SIMD2<Double>? = nil,
                    cursorSprite: CursorSprite? = nil) {
            self.frame = frame
            self.displayPointSize = displayPointSize
            self.cursorPoint = cursorPoint
            self.cursorSprite = cursorSprite
        }
    }

    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let pixelFormat: MTLPixelFormat
    private let videoState: any MTLRenderPipelineState
    private let cursorState: any MTLRenderPipelineState
    private let nearest: any MTLSamplerState
    private let linear: any MTLSamplerState
    private let textureCache: CVMetalTextureCache
    private var cursorTextures: [UInt64: any MTLTexture] = [:]

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(), pixelFormat: MTLPixelFormat = .bgr10a2Unorm) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw RendererError.noDevice }
        self.device = device
        commandQueue = queue
        self.pixelFormat = pixelFormat
        let library: any MTLLibrary
        do { library = try device.makeLibrary(source: Self.shaderSource, options: nil) } catch {
            throw RendererError.shader("\(error)")
        }
        func pipeline(_ fragment: String, blend: Bool) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "lain_quad")
            d.fragmentFunction = library.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!
            a.pixelFormat = pixelFormat
            if blend {
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do { return try device.makeRenderPipelineState(descriptor: d) } catch { throw RendererError.shader("\(error)") }
        }
        videoState = try pipeline("lain_ycbcr", blend: false)
        cursorState = try pipeline("lain_sprite", blend: true)
        func sampler(_ filter: MTLSamplerMinMagFilter) -> any MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter
            d.magFilter = filter
            d.sAddressMode = .clampToEdge
            d.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: d)!
        }
        nearest = sampler(.nearest)
        linear = sampler(.linear)
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw RendererError.textureCache(status) }
        textureCache = cache
    }

    // MARK: Geometry

    /// Where the content lands in a target of `target` pixels: 1:1 and centred when it fits exactly,
    /// otherwise aspect-fit (pixel-aligned origin).
    public static func contentRect(content: SIMD2<Double>, target: SIMD2<Double>) -> (origin: SIMD2<Double>, size: SIMD2<Double>) {
        guard content.x > 0, content.y > 0 else { return (.zero, target) }
        if content == target { return (.zero, target) }
        let scale = min(target.x / content.x, target.y / content.y)
        let size = content * scale
        let origin = ((target - size) / 2).rounded(.down)
        return (origin, size)
    }

    // MARK: Drawing

    /// Encodes the scene into `commandBuffer`, drawing into `target` (one render pass).
    public func encode(_ scene: Scene, into commandBuffer: any MTLCommandBuffer, target: any MTLTexture) {
        let targetSize = SIMD2(Double(target.width), Double(target.height))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        // The frame's pixel size decides the layout; before video, the display's 2× point size does.
        var contentPixels = SIMD2<Double>(0, 0)
        if let frame = scene.frame {
            contentPixels = SIMD2(Double(CVPixelBufferGetWidth(frame.image)), Double(CVPixelBufferGetHeight(frame.image)))
        } else if let points = scene.displayPointSize {
            contentPixels = points * 2
        }
        let rect = Self.contentRect(content: contentPixels, target: targetSize)

        var keepAlive: [CVMetalTexture] = []
        if let frame = scene.frame, let planes = planeTextures(frame) {
            keepAlive = [planes.0, planes.1]
            if let y = CVMetalTextureGetTexture(planes.0), let c = CVMetalTextureGetTexture(planes.1) {
                let oneToOne = rect.size == contentPixels
                encoder.setRenderPipelineState(videoState)
                var quad = Self.ndc(origin: rect.origin, size: rect.size, target: targetSize)
                encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                var params = Self.conversion(frame.format)
                encoder.setFragmentBytes(&params, length: MemoryLayout<ConversionParams>.stride, index: 0)
                encoder.setFragmentTexture(y, index: 0)
                encoder.setFragmentTexture(c, index: 1)
                encoder.setFragmentSamplerState(oneToOne ? nearest : linear, index: 0)
                encoder.setFragmentSamplerState(oneToOne && frame.format.chroma == .yuv444 ? nearest : linear, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        if let point = scene.cursorPoint, let sprite = scene.cursorSprite, let texture = cursorTexture(sprite) {
            let points = scene.displayPointSize ?? contentPixels / 2
            if points.x > 0, points.y > 0 {
                let pixelsPerPoint = rect.size / points
                let hotspot = SIMD2(sprite.hotspotX, sprite.hotspotY)
                let spriteSize = SIMD2(Double(sprite.pixelWidth), Double(sprite.pixelHeight)) / sprite.scale * pixelsPerPoint
                // Pixel-aligned so a 2× sprite on a 2× display maps texel to pixel.
                let origin = (rect.origin + (point - hotspot) * pixelsPerPoint).rounded(.down)
                encoder.setRenderPipelineState(cursorState)
                var quad = Self.ndc(origin: origin, size: spriteSize, target: targetSize)
                encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(spriteSize == SIMD2(Double(sprite.pixelWidth), Double(sprite.pixelHeight))
                    ? nearest : linear, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        encoder.endEncoding()
        if !keepAlive.isEmpty {
            // The CVMetalTextures must outlive the GPU's use of their IOSurfaces.
            let box = TextureKeepAlive(keepAlive)
            commandBuffer.addCompletedHandler { _ in box.release() }
        }
    }

    // MARK: Offscreen (tests)

    /// Renders `scene` into a new `width`×`height` texture of `format` and waits for the GPU.
    public func renderOffscreen(_ scene: Scene, width: Int, height: Int) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d), let cb = commandQueue.makeCommandBuffer() else { return nil }
        encode(scene, into: cb, target: texture)
        cb.commit()
        cb.waitUntilCompleted()
        return texture
    }

    /// Reads back a `.bgra8Unorm` texture as tightly packed BGRA bytes.
    public static func readBGRA8(_ texture: any MTLTexture) -> [UInt8] {
        precondition(texture.pixelFormat == .bgra8Unorm)
        var out = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        out.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return out
    }

    /// Drops cached cursor textures and flushes the video texture cache (e.g. on disconnect).
    public func flush() {
        cursorTextures.removeAll()
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    // MARK: Private

    private func planeTextures(_ frame: DecodedFrame) -> (CVMetalTexture, CVMetalTexture)? {
        let image = frame.image
        guard CVPixelBufferGetPlaneCount(image) == 2 else { return nil }
        let tenBit = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            || CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
            || CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        func plane(_ index: Int, _ format: MTLPixelFormat) -> CVMetalTexture? {
            var texture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, image, nil, format, CVPixelBufferGetWidthOfPlane(image, index),
                CVPixelBufferGetHeightOfPlane(image, index), index, &texture)
            return status == kCVReturnSuccess ? texture : nil
        }
        guard let y = plane(0, tenBit ? .r16Unorm : .r8Unorm), let c = plane(1, tenBit ? .rg16Unorm : .rg8Unorm) else { return nil }
        return (y, c)
    }

    private func cursorTexture(_ sprite: CursorSprite) -> (any MTLTexture)? {
        if let t = cursorTextures[sprite.key] { return t }
        guard sprite.pixelWidth > 0, sprite.pixelHeight > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: sprite.pixelWidth,
                                                         height: sprite.pixelHeight, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        sprite.pixels.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, sprite.pixelWidth, sprite.pixelHeight), mipmapLevel: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: sprite.pixelWidth * 4)
        }
        if cursorTextures.count >= CursorOverlay.maxShapes + 1 { cursorTextures.removeAll() }
        cursorTextures[sprite.key] = t
        return t
    }

    /// A pixel rect (top-left origin) as NDC (left, top, right, bottom).
    static func ndc(origin: SIMD2<Double>, size: SIMD2<Double>, target: SIMD2<Double>) -> SIMD4<Float> {
        let x0 = origin.x / target.x * 2 - 1, x1 = (origin.x + size.x) / target.x * 2 - 1
        let y0 = 1 - origin.y / target.y * 2, y1 = 1 - (origin.y + size.y) / target.y * 2
        return SIMD4(Float(x0), Float(y0), Float(x1), Float(y1))
    }

    struct ConversionParams {
        var rowR: SIMD4<Float>
        var rowG: SIMD4<Float>
        var rowB: SIMD4<Float>
        /// y = u·x − y, c = u·z − w (u: the texture's unorm value).
        var range: SIMD4<Float>
    }

    /// YCbCr → R'G'B' for the stream's matrix and range (ITU-T H.273). Values stay non-linear.
    static func conversion(_ f: FrameFormat) -> ConversionParams {
        let (kr, kb): (Double, Double) = switch f.matrix {
        case 5, 6: (0.299, 0.114)          // BT.601 / SMPTE 170M
        case 9, 10: (0.2627, 0.0593)       // BT.2020
        default: (0.2126, 0.0722)          // BT.709 (what lain sends)
        }
        let kg = 1 - kr - kb
        let rowR = SIMD4<Float>(1, 0, Float(2 * (1 - kr)), 0)
        let rowG = SIMD4<Float>(1, Float(-2 * kb * (1 - kb) / kg), Float(-2 * kr * (1 - kr) / kg), 0)
        let rowB = SIMD4<Float>(1, Float(2 * (1 - kb)), 0, 0)
        // Code value from the unorm sample: 10-bit samples sit in the high bits of 16-bit texels.
        let bits = Double(f.bitDepth > 8 ? f.bitDepth : 8)
        let codeScale = f.bitDepth > 8 ? 65535.0 / 64.0 * (bits == 10 ? 1 : pow(2, bits - 10)) : 255.0
        let unit = pow(2, bits - 8)
        let range: SIMD4<Float>
        if f.fullRange {
            let maxCode = pow(2, bits) - 1
            range = SIMD4(Float(codeScale / maxCode), 0, Float(codeScale / maxCode), Float(128 * unit / maxCode))
        } else {
            range = SIMD4(Float(codeScale / (219 * unit)), Float(16 / 219.0), Float(codeScale / (224 * unit)), Float(128 / 224.0))
        }
        return ConversionParams(rowR: rowR, rowG: rowG, rowB: rowB, range: range)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadOut { float4 position [[position]]; float2 uv; };

    // A triangle-strip quad over rect = (left, top, right, bottom) in NDC; uv (0,0) is the top-left.
    vertex QuadOut lain_quad(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 uv = float2(float(vid & 1), float(vid >> 1));
        QuadOut o;
        o.position = float4(mix(rect.x, rect.z, uv.x), mix(rect.y, rect.w, uv.y), 0, 1);
        o.uv = uv;
        return o;
    }

    struct Conversion { float4 rowR; float4 rowG; float4 rowB; float4 range; };

    fragment float4 lain_ycbcr(QuadOut in [[stage_in]],
                               texture2d<float> lumaTex [[texture(0)]], texture2d<float> chromaTex [[texture(1)]],
                               sampler lumaSampler [[sampler(0)]], sampler chromaSampler [[sampler(1)]],
                               constant Conversion &p [[buffer(0)]]) {
        float y = lumaTex.sample(lumaSampler, in.uv).r * p.range.x - p.range.y;
        float2 c = chromaTex.sample(chromaSampler, in.uv).rg * p.range.z - p.range.w;
        float3 v = float3(y, c);
        return float4(saturate(float3(dot(p.rowR.xyz, v), dot(p.rowG.xyz, v), dot(p.rowB.xyz, v))), 1);
    }

    // Premultiplied BGRA sprite (blended one / one-minus-source-alpha).
    fragment float4 lain_sprite(QuadOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    """
}

/// Holds CVMetalTextures until the command buffer that reads them completes.
private final class TextureKeepAlive: @unchecked Sendable {
    private var textures: [CVMetalTexture]
    init(_ textures: [CVMetalTexture]) { self.textures = textures }
    func release() { textures.removeAll() }
}
