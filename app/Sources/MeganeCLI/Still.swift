import MeganeKit
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Upscale one image through the exact playback path (ANE student + Metal compositor) and
/// write a PNG, so the app's output can be checked pixel-for-pixel against Python.
/// `--pad WxH` runs the model at that larger size, as the player does for sizes the model
/// has no function for: the image in the top-left, its last column and row repeated.
func runStill(modelURL: URL, flags: [String: String]) throws {
    guard let inPath = flags["image"], let outPath = flags["out"] else {
        throw StillError.usage
    }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StillError.read(inPath) }
    let w = image.width, h = image.height

    let pad = flags["pad"].map { $0.split(separator: "x").compactMap { Int($0) } } ?? [w, h]
    guard pad.count == 2, pad[0] >= w, pad[1] >= h else { throw StillError.usage }
    guard let frame = PixelBuffer.make(width: pad[0], height: pad[1]) else { throw BenchError.allocFailed }
    try draw(image, into: frame)
    padEdges(frame, width: w, height: h)

    let upscaler = try StudentUpscaler(modelURL: modelURL, width: pad[0], height: pad[1])
    let device = MTLCreateSystemDefaultDevice()!
    let compositor = try Compositor(device: device)
    compositor.dither = false   // bit-exact output, for comparisons
    let queue = device.makeCommandQueue()!

    let residual = try upscaler.run(frame)
    let output = renderTarget(device, 2 * w, 2 * h, storage: .shared)
    let commandBuffer = queue.makeCommandBuffer()!
    try compositor.encode(source: frame, residual: residual, frame: (w, h), into: commandBuffer,
                          target: renderPass(output), targetSize: (output.width, output.height))
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: output.width * output.height * 4)
    output.getBytes(&bytes, bytesPerRow: output.width * 4,
                    from: MTLRegionMake2D(0, 0, output.width, output.height), mipmapLevel: 0)
    try writePNG(bytes, width: output.width, height: output.height, to: outPath)
    print("\(w)x\(h) -> \(output.width)x\(output.height)  wrote \(outPath)")
}

/// An offscreen BGRA texture to render the 2× frame into (same shader path as the window).
func renderTarget(_ device: MTLDevice, _ w: Int, _ h: Int, storage: MTLStorageMode) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = storage
    return device.makeTexture(descriptor: d)!
}

func renderPass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    pass.colorAttachments[0].storeAction = .store
    return pass
}

/// Repeat the last column, then the last row, of the `width`×`height` top-left over the rest.
private func padEdges(_ buffer: CVPixelBuffer, width: Int, height: Int) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
    let pw = CVPixelBufferGetWidth(buffer), ph = CVPixelBufferGetHeight(buffer)
    for y in 0..<height { for x in width..<pw { base[y * stride + x] = base[y * stride + width - 1] } }
    for y in height..<ph { for x in 0..<pw { base[y * stride + x] = base[(height - 1) * stride + x] } }
}

/// Copy the image's pixel values into a BGRA buffer unchanged (no colour management).
private func draw(_ image: CGImage, into buffer: CVPixelBuffer) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                              width: image.width, height: image.height, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw StillError.read("bitmap context") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
}

private func writePNG(_ bgra: [UInt8], width: Int, height: Int, to path: String) throws {
    let provider = CGDataProvider(data: Data(bgra) as CFData)!
    guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { throw StillError.write(path) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw StillError.write(path) }
}

enum StillError: Swift.Error, CustomStringConvertible {
    case usage, read(String), write(String)
    var description: String {
        switch self {
        case .usage: return "still needs --image <in.png> --out <out.png>"
        case .read(let p): return "cannot read \(p)"
        case .write(let p): return "cannot write \(p)"
        }
    }
}
