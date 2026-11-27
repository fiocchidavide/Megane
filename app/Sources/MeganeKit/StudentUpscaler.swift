import CoreML
import CoreVideo
import Foundation

/// Runs the student distilled from Anime4K Mode A on the Neural Engine for one source size.
///
/// The model is a multifunction package with one fixed-shape function per source size
/// (`f<W>x<H>`); fixed shapes are what the ANE runs fastest. Its single output, `residual`
/// (1×C×H×W FP16: RGB restore residual + 2× detail, C = 7 for luma or 15 for RGB detail), is
/// written straight into an IOSurface-backed `OneComponent16Half` buffer, W wide and C·H tall,
/// that Metal reads
/// zero-copy. ``Compositor`` then turns source + residual into the 2× frame. Two such buffers
/// alternate, so the ANE can fill the next one while the GPU still reads the last.
public final class StudentUpscaler {

    public enum Error: Swift.Error, CustomStringConvertible {
        case unsupportedSize(Int, Int, available: [String])
        case allocFailed
        case predictionFailed(Swift.Error)

        public var description: String {
            switch self {
            case .unsupportedSize(let w, let h, let available):
                return "no model function for \(w)x\(h); exported sizes: \(available.joined(separator: ", "))"
            case .allocFailed: return "failed to allocate the residual buffer"
            case .predictionFailed(let e): return "prediction failed: \(e)"
            }
        }
    }

    /// Channels of a luma-detail residual (3 RGB restore + 4 subpixels); RGB-detail models
    /// (Anime4K VL, exact) have 15 (3 + 3 x 4).
    public static let channels = 7
    /// This model's residual channels (7 or 15), from its output description.
    public let channels: Int
    public let width: Int
    public let height: Int

    private let model: MLModel
    /// `OneComponent16Half`, `width` × (7 · `height`): channel c occupies rows c·H ..< (c+1)·H.
    private var residuals: [CVPixelBuffer] = []
    private var options: [MLPredictionOptions] = []
    private var next = 0

    /// True if the package at `url` is a student (has a `residual` output) rather than an
    /// image-to-image model such as the transpiled Anime4K.
    public static func isStudent(_ url: URL) -> Bool {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly   // only reading the description: skip the ANE compile
        return (try? compiledURL(for: url)).flatMap { try? MLModel(contentsOf: $0, configuration: config) }?
            .modelDescription.outputDescriptionsByName["residual"] != nil
    }

    public init(modelURL: URL, width: Int, height: Int,
                computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        self.width = width
        self.height = height
        let compiled = try Self.compiledURL(for: modelURL)

        // Core ML's own placement prefers the GPU for this graph; the ANE has to be asked for.
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.functionName = "f\(width)x\(height)"
        do {
            self.model = try MLModel(contentsOf: compiled, configuration: config)
        } catch {
            let available = (try? Self.functionNames(compiled)) ?? []
            throw Error.unsupportedSize(width, height, available: available)
        }

        let shape = model.modelDescription.outputDescriptionsByName["residual"]?.multiArrayConstraint?.shape
        channels = shape.flatMap { $0.count == 4 ? $0[1].intValue : nil } ?? Self.channels
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        for _ in 0..<2 {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, channels * height,
                                      kCVPixelFormatType_OneComponent16Half, attrs as CFDictionary,
                                      &buffer) == kCVReturnSuccess, let buffer else { throw Error.allocFailed }
            let backing = MLMultiArray(pixelBuffer: buffer, shape: [1, NSNumber(value: channels),
                                                                   NSNumber(value: height), NSNumber(value: width)])
            let opts = MLPredictionOptions()
            opts.outputBackings = ["residual": backing]
            residuals.append(buffer)
            options.append(opts)
        }
    }

    /// Run the model on one BGRA frame; returns the residual buffer it filled. That buffer is
    /// not written again until two calls later.
    public func run(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        let input = try MLDictionaryFeatureProvider(dictionary: ["frame": MLFeatureValue(pixelBuffer: frame)])
        let i = next
        next = (next + 1) % residuals.count
        do {
            _ = try model.prediction(from: input, options: options[i])
        } catch {
            throw Error.predictionFailed(error)
        }
        return residuals[i]
    }

    // MARK: - Compiled-model cache

    /// Compile once per package and reuse (compiling a multifunction package takes a moment).
    static func compiledURL(for url: URL) throws -> URL {
        guard url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" else { return url }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("megane", isDirectory: true)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("Manifest.json").path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let target = cache.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(Int(stamp)).mlmodelc")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let compiled = try MLModel.compileModel(at: url)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: compiled, to: target)
        return target
    }

    /// The source sizes a student package was exported for, e.g. `["f1280x720", "f1920x1080"]`.
    public static func sizes(of url: URL) -> [String] {
        (try? compiledURL(for: url)).flatMap { try? functionNames($0) } ?? []
    }

    private static func functionNames(_ compiled: URL) throws -> [String] {
        let semaphore = DispatchSemaphore(value: 0)
        let box = NamesBox()
        Task {
            if let structure = try? await MLModelStructure.load(contentsOf: compiled),
               case .program(let program) = structure {
                box.names = program.functions.keys.sorted()
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.names
    }
}

private final class NamesBox: @unchecked Sendable { var names: [String] = [] }
