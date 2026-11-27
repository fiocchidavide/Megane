import CoreVideo
import Foundation

/// Helpers for creating Metal- and Core ML-compatible pixel buffers.
///
/// All buffers are 32BGRA and IOSurface-backed so they can be shared zero-copy
/// between AVFoundation decode, the ANE, and the Metal renderer.
public enum PixelBuffer {

    /// Attributes that keep a buffer usable by both Metal and Core ML.
    public static var attributes: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
    }

    public static func make(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }

    /// Fill a buffer with a simple test pattern (for the headless benchmark).
    public static func fillTestPattern(_ buffer: CVPixelBuffer, frame: Int = 0) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = ptr + y * stride
            for x in 0..<width {
                let p = row + x * 4
                p[0] = UInt8((x + frame) & 0xFF)          // B
                p[1] = UInt8((y + frame) & 0xFF)          // G
                p[2] = UInt8((x ^ y) & 0xFF)              // R
                p[3] = 255                                // A
            }
        }
    }
}
