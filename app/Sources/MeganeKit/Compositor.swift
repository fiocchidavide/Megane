import CoreGraphics
import CoreVideo
import Metal

/// Turns a source frame + the student's residual into the 2× frame and draws it, on the GPU.
///
/// This is the same composition the student was trained through (`compose()` in the training code),
/// so it must match it exactly:
///
///     restored = source + residual[0:3]                              (W×H)
///     out      = bilinear2x(restored) + pixel_shuffle(residual[3:])  (2W×2H; luma or RGB detail)
///     out      = Clamp_Highlights(out, 5×5 max of source luma)
///
/// Two passes, nothing 4K ever touches memory:
///   * `megane_prep` (W×H): one RGBA16F texture = (restored.rgb, 5×5 max luma).
///   * a fragment shader that composes straight into the render target. One hardware bilinear
///     sample of the prep texture gives both bilinear terms (Metal's normalized sampling with
///     clamp-to-edge is exactly PyTorch's `align_corners=False`), plus one read of the detail.
/// When the viewport is exactly 2W×2H (1080p fullscreen on 4K) each pixel is composed once;
/// otherwise the 2× image is evaluated at the 4 nearest 2× pixels and resampled bilinearly.
///
/// The source and residual may be larger than the frame (a size the model was exported for,
/// padded with replicated edges): only the top-left W×H is read, so the output is cropped to
/// 2W×2H, and the residual's channel stride is the padded height.
public final class Compositor {

    public enum Error: Swift.Error { case badTexture, noEncoder }

    public let device: MTLDevice
    private let prepPipeline: MTLComputePipelineState
    private let exactPipeline: MTLRenderPipelineState
    private let scaledPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache
    private var prep: MTLTexture?
    /// Dither the output to 8 bits (playback). Off for bit-exact comparisons (`megane-cli still`).
    public var dither = true

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 kLuma = float3(0.299, 0.587, 0.114);   // as in Anime4K_Clamp_Highlights

    // The frame's own size inside the (possibly padded) buffers, the residual's channel
    // stride in rows (the padded height), and whether to dither the 8-bit output.
    struct Frame { int W; int H; int stride; int dither; };

    // Interleaved gradient noise (Jimenez 2014), in [-0.5, 0.5) of an 8-bit step: dithering
    // before the drawable rounds to 8 bits, as mpv does. Without it Anime4K's smooth
    // gradients (restored compression noise) round to visible bands.
    inline float3 dither8(float3 c, float2 pos) {
        float n = fract(52.9829189 * fract(dot(floor(pos), float2(0.06711056, 0.00583715))));
        return c + (n - 0.5) / 255.0;
    }

    // (restored.rgb, Clamp_Highlights stats = max luma over a 5x5 window, edge clamped)
    kernel void megane_prep(texture2d<float, access::read>  src  [[texture(0)]],
                         texture2d<float, access::read>  res  [[texture(1)]],  // C channel blocks of `stride` rows
                         texture2d<half,  access::write> prep [[texture(2)]],
                         constant Frame& frame [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
        int W = frame.W, H = frame.H, S = frame.stride;
        if (int(gid.x) >= W || int(gid.y) >= H) return;
        float m = 0.0;
        for (int dy = -2; dy <= 2; dy++)
            for (int dx = -2; dx <= 2; dx++) {
                uint2 p = uint2(clamp(int(gid.x) + dx, 0, W - 1), clamp(int(gid.y) + dy, 0, H - 1));
                m = max(m, dot(src.read(p).rgb, kLuma));
            }
        float3 restored = src.read(gid).rgb + float3(res.read(gid).r,
                                                     res.read(uint2(gid.x, S + gid.y)).r,
                                                     res.read(uint2(gid.x, 2 * S + gid.y)).r);
        prep.write(half4(half3(restored), half(m)), gid);
    }

    struct VOut { float4 pos [[position]]; };

    vertex VOut megane_vtx(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    struct Viewport { float2 origin; float2 size; };

    // The 2x pixel q (integer, 0 <= q < 2W x 2H).
    inline float3 compose_at(int2 q, texture2d<float> prep, texture2d<float, access::read> res,
                             sampler smp, int S) {
        int W = prep.get_width(), H = prep.get_height();
        float4 p = prep.sample(smp, (float2(q) + 0.5) / float2(2 * W, 2 * H));
        // pixel_shuffle: subpixel (i, j) of source pixel (x, y) is detail channel i*2 + j,
        // one luma value (7-channel residual) or one per colour (15-channel: R, G, B blocks).
        int s = (q.y & 1) * 2 + (q.x & 1);
        uint sx = q.x / 2, sy = q.y / 2;
        float3 d = res.get_height() >= uint(15 * S)
            ? float3(res.read(uint2(sx, (3 + s) * S + sy)).r, res.read(uint2(sx, (7 + s) * S + sy)).r,
                     res.read(uint2(sx, (11 + s) * S + sy)).r)
            : float3(res.read(uint2(sx, (3 + s) * S + sy)).r);
        float3 out = p.rgb + d;
        float y = dot(out, kLuma);
        out -= y - min(y, p.a);
        return saturate(out);
    }

    // Viewport is exactly 2W x 2H: one 2x pixel per fragment.
    fragment float4 megane_exact(VOut in [[stage_in]],
                              texture2d<float> prep [[texture(0)]],
                              texture2d<float, access::read> res [[texture(1)]],
                              sampler smp [[sampler(0)]],
                              constant Viewport& vp [[buffer(0)]],
                              constant Frame& frame [[buffer(1)]]) {
        float3 rgb = compose_at(int2(in.pos.xy - vp.origin), prep, res, smp, frame.stride);
        return float4(frame.dither ? dither8(rgb, in.pos.xy) : rgb, 1.0);
    }

    // Any other viewport: bilinear resample of the 2x image.
    fragment float4 megane_scaled(VOut in [[stage_in]],
                               texture2d<float> prep [[texture(0)]],
                               texture2d<float, access::read> res [[texture(1)]],
                               sampler smp [[sampler(0)]],
                               constant Viewport& vp [[buffer(0)]],
                               constant Frame& frame [[buffer(1)]]) {
        int S = frame.stride;
        int2 size2x = int2(2 * prep.get_width(), 2 * prep.get_height());
        float2 c = (in.pos.xy - vp.origin) / vp.size * float2(size2x) - 0.5;
        int2 i0 = int2(floor(c));
        float2 f = c - float2(i0);
        int2 lo = clamp(i0, int2(0), size2x - 1), hi = clamp(i0 + 1, int2(0), size2x - 1);
        float3 a = compose_at(lo, prep, res, smp, S), b = compose_at(int2(hi.x, lo.y), prep, res, smp, S);
        float3 c0 = compose_at(int2(lo.x, hi.y), prep, res, smp, S), d = compose_at(hi, prep, res, smp, S);
        float3 rgb = mix(mix(a, b, f.x), mix(c0, d, f.x), f.y);
        return float4(frame.dither ? dither8(rgb, in.pos.xy) : rgb, 1.0);
    }
    """

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        self.prepPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "megane_prep")!)
        func render(_ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "megane_vtx")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: d)
        }
        self.exactPipeline = try render("megane_exact")
        self.scaledPipeline = try render("megane_scaled")

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { throw Error.badTexture }
        self.sampler = sampler

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw Error.badTexture }
        self.textureCache = cache
    }

    /// Encode the prep pass and a render pass drawing the 2× frame into `target`, aspect-fit
    /// (black bars outside). `target` is a drawable's render pass or an offscreen texture's.
    /// `overlay` then draws into the same pass (e.g. subtitles), given the video's rectangle
    /// in target pixels (top-left origin). `frame` is the video's size when `source` is padded
    /// beyond it (default: all of `source`).
    public func encode(source: CVPixelBuffer, residual: CVPixelBuffer, frame: (width: Int, height: Int)? = nil,
                       into commandBuffer: MTLCommandBuffer,
                       target: MTLRenderPassDescriptor, targetSize: (width: Int, height: Int),
                       overlay: ((MTLRenderCommandEncoder, CGRect) -> Void)? = nil) throws {
        let w = frame?.width ?? CVPixelBufferGetWidth(source), h = frame?.height ?? CVPixelBufferGetHeight(source)
        var dims = SIMD4<Int32>(Int32(w), Int32(h), Int32(CVPixelBufferGetHeight(source)), dither ? 1 : 0)
        guard let (src, srcRef) = wrap(source, .bgra8Unorm),
              let (res, resRef) = wrap(residual, .r16Float) else { throw Error.badTexture }
        let prep = prepTexture(w, h)

        guard let compute = commandBuffer.makeComputeCommandEncoder() else { throw Error.noEncoder }
        compute.setComputePipelineState(prepPipeline)
        compute.setTextures([src, res, prep], range: 0..<3)
        compute.setBytes(&dims, length: MemoryLayout<SIMD4<Int32>>.size, index: 0)
        let tw = prepPipeline.threadExecutionWidth
        compute.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: prepPipeline.maxTotalThreadsPerThreadgroup / tw, depth: 1))
        compute.endEncoding()

        // Aspect-fit the 2W×2H image; integer-snap so a same-size target hits the exact path.
        let scale = min(Double(targetSize.width) / Double(2 * w), Double(targetSize.height) / Double(2 * h))
        let vw = (Double(2 * w) * scale).rounded(), vh = (Double(2 * h) * scale).rounded()
        let ox = ((Double(targetSize.width) - vw) / 2).rounded(), oy = ((Double(targetSize.height) - vh) / 2).rounded()
        var viewport = SIMD4<Float>(Float(ox), Float(oy), Float(vw), Float(vh))
        let exact = Int(vw) == 2 * w && Int(vh) == 2 * h

        guard let render = commandBuffer.makeRenderCommandEncoder(descriptor: target) else { throw Error.noEncoder }
        render.setViewport(MTLViewport(originX: ox, originY: oy, width: vw, height: vh, znear: 0, zfar: 1))
        render.setRenderPipelineState(exact ? exactPipeline : scaledPipeline)
        render.setFragmentTextures([prep, res], range: 0..<2)
        render.setFragmentSamplerState(sampler, index: 0)
        render.setFragmentBytes(&viewport, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        render.setFragmentBytes(&dims, length: MemoryLayout<SIMD4<Int32>>.size, index: 1)
        render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let overlay {
            render.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(targetSize.width),
                                           height: Double(targetSize.height), znear: 0, zfar: 1))
            overlay(render, CGRect(x: ox, y: oy, width: vw, height: vh))
        }
        render.endEncoding()
        // CVMetalTextures must outlive the GPU work that reads them.
        commandBuffer.addCompletedHandler { _ in _ = (srcRef, resRef) }
    }

    private func wrap(_ buffer: CVPixelBuffer, _ format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }

    private func prepTexture(_ w: Int, _ h: Int) -> MTLTexture {
        if let t = prep, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private   // GPU-only: keeps lossless compression, no CPU coherency
        prep = device.makeTexture(descriptor: d)
        return prep!
    }
}
