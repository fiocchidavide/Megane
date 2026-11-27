import CoreML
import CoreVideo
import Foundation

/// Runs the Megane Mode-A model on a video frame using the Apple Neural Engine.
///
/// The Core ML model takes an image (``CVPixelBuffer``) and returns an upscaled
/// image (``CVPixelBuffer``). Because both ends are images, frames stay in unified
/// memory — no CPU copies between decode, ANE inference, and Metal display.
public final class Upscaler {

    public enum Error: Swift.Error, CustomStringConvertible {
        case noImageInput
        case noImageOutput
        case predictionFailed(Swift.Error)

        public var description: String {
            switch self {
            case .noImageInput: return "model has no image input"
            case .noImageOutput: return "model produced no image output"
            case .predictionFailed(let e): return "prediction failed: \(e)"
            }
        }
    }

    private let model: MLModel
    private let inputName: String
    private let outputName: String

    /// Input resolution the model was exported for (frames must match this).
    public let inputSize: (width: Int, height: Int)?

    /// - Parameters:
    ///   - modelURL: a `.mlpackage`, `.mlmodel`, or already-compiled `.mlmodelc`.
    ///   - computeUnits: `.all` lets Core ML place work on the ANE (falls back to GPU/CPU).
    public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let compiled: URL
        switch modelURL.pathExtension {
        case "mlpackage", "mlmodel":
            compiled = try MLModel.compileModel(at: modelURL)
        default:
            compiled = modelURL
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        self.model = try MLModel(contentsOf: compiled, configuration: config)

        let desc = model.modelDescription
        guard let input = desc.inputDescriptionsByName.first(where: { $0.value.type == .image }) else {
            throw Error.noImageInput
        }
        guard let output = desc.outputDescriptionsByName.first(where: { $0.value.type == .image }) else {
            throw Error.noImageOutput
        }
        self.inputName = input.key
        self.outputName = output.key
        if let c = input.value.imageConstraint {
            self.inputSize = (c.pixelsWide, c.pixelsHigh)
        } else {
            self.inputSize = nil
        }
    }

    /// Upscale one frame. Returns the model's own output pixel buffer.
    public func upscale(_ pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let feature = MLFeatureValue(pixelBuffer: pixelBuffer)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: feature])
        let result: MLFeatureProvider
        do {
            result = try model.prediction(from: provider)
        } catch {
            throw Error.predictionFailed(error)
        }
        guard let buffer = result.featureValue(for: outputName)?.imageBufferValue else {
            throw Error.noImageOutput
        }
        return buffer
    }
}
