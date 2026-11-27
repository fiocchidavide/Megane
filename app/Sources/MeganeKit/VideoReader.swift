import AVFoundation
import CoreVideo

/// Pulls decoded frames out of a video file as ``CVPixelBuffer``s for live playback.
///
/// Wraps `AVPlayer` + `AVPlayerItemVideoOutput`. The output vends 32BGRA,
/// IOSurface-backed buffers so they hand straight to Core ML and Metal with no copy.
public final class VideoReader {

    public let player: AVPlayer
    private let output: AVPlayerItemVideoOutput

    public init(url: URL) {
        let item = AVPlayerItem(url: url)
        self.output = AVPlayerItemVideoOutput(pixelBufferAttributes: PixelBuffer.attributes)
        item.add(output)
        self.player = AVPlayer(playerItem: item)
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    /// The most recent frame for "now", or nil if none is ready yet.
    public func currentFrame() -> CVPixelBuffer? {
        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        return output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    }
}

/// Reads every frame of a file sequentially (for offline benchmarking on real footage).
public final class SequentialVideoReader {
    private let reader: AVAssetReader
    private let trackOutput: AVAssetReaderTrackOutput

    public init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "MeganeKit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no video track in \(url.lastPathComponent)"])
        }
        self.reader = try AVAssetReader(asset: asset)
        self.trackOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(trackOutput)
        reader.startReading()
    }

    /// Next decoded frame, or nil at end of file.
    public func next() -> CVPixelBuffer? {
        guard let sample = trackOutput.copyNextSampleBuffer() else { return nil }
        return CMSampleBufferGetImageBuffer(sample)
    }
}
