import CoreVideo
import Metal
import MetalKit

/// Draws a ``CVPixelBuffer`` to an ``MTKView`` via a zero-copy Metal texture.
///
/// The pixel buffer is wrapped as an `MTLTexture` through a `CVMetalTextureCache`
/// (no copy), then sampled onto a fullscreen triangle. The view scales it to the
/// drawable, so the upscaled frame is presented directly.
public final class MetalRenderer {

    public enum Error: Swift.Error { case noQueue, noTextureCache, badTexture }

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };

    // Fullscreen triangle: no vertex buffer needed.
    vertex VOut megane_vtx(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv  = float2(p.x, 1.0 - p.y);   // flip Y: texture origin is top-left
        return o;
    }

    fragment float4 megane_frag(VOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler smp [[sampler(0)]]) {
        return tex.sample(smp, in.uv);
    }
    """

    public init(device: MTLDevice = MTLCreateSystemDefaultDevice()!) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Error.noQueue }
        self.queue = queue

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw Error.noTextureCache }
        self.textureCache = cache

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "megane_vtx")
        descriptor.fragmentFunction = library.makeFunction(name: "megane_frag")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: sd) else { throw Error.badTexture }
        self.sampler = sampler
    }

    /// The texture and the CVMetalTexture that owns it, which must outlive the GPU's use.
    private func texture(from buffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }

    /// Draw `texture` (e.g. the ``Compositor`` output) into the view, after whatever is already
    /// encoded in `commandBuffer`, then present and commit.
    public func draw(texture: MTLTexture, in commandBuffer: MTLCommandBuffer, to view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { commandBuffer.commit(); return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Draw one frame into the view's current drawable.
    public func draw(pixelBuffer: CVPixelBuffer, to view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let (texture, cvTexture) = texture(from: pixelBuffer),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in _ = cvTexture }
        commandBuffer.commit()
    }
}
