import CLibass
import Metal

/// Draws libass output (alpha bitmaps + a colour each) as blended quads over the video.
///
/// Bitmaps are packed into an R8 atlas only when libass reports a change, so a static line
/// costs one upload when it appears and then just a few quads per frame. Two atlases alternate
/// so an upload never overwrites one the GPU may still be reading.
final class SubtitleOverlay {

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var atlases: [MTLTexture?] = [nil, nil]
    private var current = 0
    private var quads: [Quad] = []

    private struct Quad {          // matches `Quad` in the shader
        var rect: SIMD4<Float>     // x, y, w, h in pixels, relative to the video rectangle
        var uv: SIMD4<Float>       // u, v, du, dv in atlas pixels
        var color: SIMD4<Float>    // premultiplied-ready RGBA (A = opacity)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Quad { float4 rect; float4 uv; float4 color; };
    struct VOut { float4 pos [[position]]; float2 uv; float4 color; };

    vertex VOut sub_vtx(uint vid [[vertex_id]], uint iid [[instance_id]],
                        const device Quad* quads [[buffer(0)]], constant float4& target [[buffer(1)]]) {
        // target: drawable size (xy) and the video rectangle's origin in it (zw)
        Quad q = quads[iid];
        float2 corner = float2(vid & 1, vid >> 1);
        float2 px = target.zw + q.rect.xy + corner * q.rect.zw;
        VOut o;
        o.pos = float4(px.x / target.x * 2.0 - 1.0, 1.0 - px.y / target.y * 2.0, 0.0, 1.0);
        o.uv = q.uv.xy + corner * q.uv.zw;
        o.color = q.color;
        return o;
    }

    // gamma > 0: the layer is tagged as gamma-`gamma` video (VideoPipeline.setColorSpace), but
    // subtitle colours are meant for the display as they are (as mpv draws them, after colour
    // management): re-encode them so the system's conversion gives them back. -1: sRGB layer.
    fragment float4 sub_frag(VOut in [[stage_in]], texture2d<float, access::read> atlas [[texture(0)]],
                             constant float& gamma [[buffer(0)]]) {
        float3 c = in.color.rgb;
        if (gamma > 0) {
            float3 linear = select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
            c = pow(linear, 1.0 / gamma);
        }
        float a = atlas.read(uint2(in.uv)).r * in.color.a;
        return float4(c * a, a);   // premultiplied
    }
    """

    init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "sub_vtx")
        d.fragmentFunction = library.makeFunction(name: "sub_frag")
        let c = d.colorAttachments[0]!
        c.pixelFormat = pixelFormat
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: d)
    }

    /// Update from libass (only repacks when `changed`) and draw into `encoder`.
    /// `origin` is the video rectangle's top-left in target pixels. It is applied when drawing,
    /// not baked into the quads: the window can move it without libass seeing a change.
    func draw(_ images: UnsafeMutablePointer<ASS_Image>?, changed: Bool, origin: CGPoint,
              targetSize: CGSize, gamma: Float, encoder: MTLRenderCommandEncoder) {
        if changed { upload(images) }
        guard !quads.isEmpty, let atlas = atlases[current] else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(quads, length: MemoryLayout<Quad>.stride * quads.count, index: 0)
        var target = SIMD4<Float>(Float(targetSize.width), Float(targetSize.height), Float(origin.x), Float(origin.y))
        encoder.setVertexBytes(&target, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.setFragmentTexture(atlas, index: 0)
        var g = gamma
        encoder.setFragmentBytes(&g, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: quads.count)
    }

    /// Shelf-pack every bitmap into the next atlas and rebuild the quad list.
    private func upload(_ images: UnsafeMutablePointer<ASS_Image>?) {
        quads.removeAll(keepingCapacity: true)
        var list: [ASS_Image] = []
        var img = images
        while let i = img { if i.pointee.w > 0 && i.pointee.h > 0 { list.append(i.pointee) }; img = i.pointee.next }
        guard !list.isEmpty else { return }

        // pack in an atlas at least as wide as the widest bitmap (a full-width sign on a 5K
        // display is wider than 4096), growing its height as needed
        let limit = device.supportsFamily(.apple3) ? 16384 : 8192
        let width = min(limit, max(4096, list.map { Int($0.w) }.max() ?? 0))
        var x = 0, y = 0, rowH = 0
        var places: [(Int, Int)] = []
        for i in list {
            let w = Int(i.w), h = Int(i.h)
            if x + w > width { x = 0; y += rowH + 1; rowH = 0 }
            places.append((x, y))
            x += w + 1
            rowH = max(rowH, h)
        }
        let height = min(limit, y + rowH)
        current = 1 - current
        if let a = atlases[current], a.width == width, a.height >= height {} else {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width,
                                                             height: max(256, height.nextPowerOfTwo), mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            atlases[current] = device.makeTexture(descriptor: d)
        }
        guard let atlas = atlases[current] else { return }

        for (i, (px, py)) in zip(list, places) where px + Int(i.w) <= atlas.width && py + Int(i.h) <= atlas.height {
            atlas.replace(region: MTLRegionMake2D(px, py, Int(i.w), Int(i.h)), mipmapLevel: 0,
                          withBytes: i.bitmap, bytesPerRow: Int(i.stride))
            let c = i.color
            let color = SIMD4<Float>(Float((c >> 24) & 0xFF) / 255, Float((c >> 16) & 0xFF) / 255,
                                     Float((c >> 8) & 0xFF) / 255, Float(255 - (c & 0xFF)) / 255)
            quads.append(Quad(rect: SIMD4(Float(i.dst_x), Float(i.dst_y), Float(i.w), Float(i.h)),
                              uv: SIMD4(Float(px), Float(py), Float(i.w), Float(i.h)), color: color))
        }
    }
}

private extension Int {
    var nextPowerOfTwo: Int { self <= 1 ? 1 : 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount) }
}
