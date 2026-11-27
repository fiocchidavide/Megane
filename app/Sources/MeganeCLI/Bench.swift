import MeganeKit
import CoreML
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Print the model's I/O description.
func runInfo(modelURL: URL, computeUnits: MLComputeUnits) throws {
    if StudentUpscaler.isStudent(modelURL) {
        let sizes = StudentUpscaler.sizes(of: modelURL).map { $0.dropFirst() }
        print("student model (ANE): 2x upscale, source sizes \(sizes.joined(separator: ", "))")
        return
    }
    let upscaler = try Upscaler(modelURL: modelURL, computeUnits: computeUnits)
    if let size = upscaler.inputSize {
        print("model input : \(size.width)x\(size.height)")
        print("model output: \(size.width * 2)x\(size.height * 2)  (2x)")
    } else {
        print("model input : flexible")
    }
    print("compute     : \(computeUnits)")
}

/// Headless throughput benchmark — the runnable proof that the ANE pipeline works.
///
/// Feeds frames (synthetic, or decoded from --video) through the upscaler in a loop
/// and reports per-frame latency and effective fps. Warms up first so the ANE model
/// is compiled/loaded before timing.
func runBench(modelURL: URL, flags: [String: String]) throws {
    if StudentUpscaler.isStudent(modelURL) { return try runStudentBench(modelURL: modelURL, flags: flags) }
    let computeUnits = computeUnits(from: flags) ?? .all
    let upscaler = try Upscaler(modelURL: modelURL, computeUnits: computeUnits)

    let width = Int(flags["width"] ?? "") ?? upscaler.inputSize?.width ?? 1920
    let height = Int(flags["height"] ?? "") ?? upscaler.inputSize?.height ?? 1080
    let frameCount = Int(flags["frames"] ?? "") ?? 120

    // Prepare a pool of source frames (reused round-robin to isolate model cost).
    var frames: [CVPixelBuffer] = []
    if let videoPath = flags["video"] {
        let reader = try runBlocking { try await SequentialVideoReader(url: URL(fileURLWithPath: videoPath)) }
        while frames.count < 16, let f = reader.next() { frames.append(f) }
        guard !frames.isEmpty else { throw BenchError.noFrames }
        print("source      : \(videoPath) (\(frames.count) frames sampled)")
    } else {
        for i in 0..<8 {
            guard let pb = PixelBuffer.make(width: width, height: height) else { throw BenchError.allocFailed }
            PixelBuffer.fillTestPattern(pb, frame: i * 17)
            frames.append(pb)
        }
        print("source      : synthetic \(width)x\(height)")
    }

    print("compute     : \(computeUnits)")
    print("warming up…")
    for _ in 0..<5 { _ = try upscaler.upscale(frames[0]) }

    var timings: [Double] = []
    timings.reserveCapacity(frameCount)
    let clock = ContinuousClock()
    for i in 0..<frameCount {
        let frame = frames[i % frames.count]
        let elapsed = clock.measure { _ = try? upscaler.upscale(frame) }
        timings.append(Double(elapsed.components.attoseconds) / 1e18
                       + Double(elapsed.components.seconds))
    }

    timings.sort()
    let mean = timings.reduce(0, +) / Double(timings.count) * 1000
    let median = timings[timings.count / 2] * 1000
    let p95 = timings[min(timings.count - 1, Int(Double(timings.count) * 0.95))] * 1000
    print(String(format: "frames      : %d @ %dx%d -> %dx%d", frameCount, width, height, width * 2, height * 2))
    print(String(format: "latency     : mean %.2f ms  median %.2f ms  p95 %.2f ms", mean, median, p95))
    print(String(format: "throughput  : %.1f fps", 1000.0 / median))
    let headroom = (1000.0 / median) / 24.0
    print(String(format: "24fps budget: %.1fx headroom", headroom))
}

/// Student path: ANE inference + the GPU compositor into an offscreen 2× target, per frame.
func runStudentBench(modelURL: URL, flags: [String: String]) throws {
    let width = Int(flags["width"] ?? "") ?? 1920
    let height = Int(flags["height"] ?? "") ?? 1080
    let frameCount = Int(flags["frames"] ?? "") ?? 120
    let units = computeUnits(from: flags) ?? .cpuAndNeuralEngine
    let student = try StudentUpscaler(modelURL: modelURL, width: width, height: height, computeUnits: units)
    let device = MTLCreateSystemDefaultDevice()!
    let compositor = try Compositor(device: device)
    let queue = device.makeCommandQueue()!
    let target = renderTarget(device, 2 * width, 2 * height, storage: .private)

    var frames: [CVPixelBuffer] = []
    for i in 0..<8 {
        guard let pb = PixelBuffer.make(width: width, height: height) else { throw BenchError.allocFailed }
        PixelBuffer.fillTestPattern(pb, frame: i * 17)
        frames.append(pb)
    }
    print("source      : synthetic \(width)x\(height), compute: \(units.name)")

    var model: [Double] = [], gpu: [Double] = []
    for i in 0..<(frameCount + 5) {
        let t0 = CACurrentMediaTime()
        let residual = try student.run(frames[i % frames.count])
        let t1 = CACurrentMediaTime()
        let commandBuffer = queue.makeCommandBuffer()!
        try compositor.encode(source: frames[i % frames.count], residual: residual, into: commandBuffer,
                              target: renderPass(target), targetSize: (target.width, target.height))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if i >= 5 {   // warm-up
            model.append(t1 - t0)
            gpu.append(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
        }
    }
    let med = { (a: [Double]) in a.sorted()[a.count / 2] * 1000 }
    print(String(format: "frames      : %d @ %dx%d -> %dx%d", frameCount, width, height, 2 * width, 2 * height))
    print(String(format: "model       : median %.2f ms (%@)", med(model), units.name))
    print(String(format: "compositor  : median %.2f ms GPU", med(gpu)))
    print(String(format: "throughput  : %.1f fps if serial (24fps budget: %.1fx headroom)",
                 1000.0 / (med(model) + med(gpu)), 1000.0 / (med(model) + med(gpu)) / 24.0))
}

enum BenchError: Swift.Error, CustomStringConvertible {
    case allocFailed, noFrames
    var description: String {
        switch self {
        case .allocFailed: return "failed to allocate pixel buffer"
        case .noFrames: return "no frames decoded from video"
        }
    }
}

/// Run an async initializer from synchronous CLI code.
func runBlocking<T>(_ work: @Sendable @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        do { box.result = .success(try await work()) }
        catch { box.result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result!.get()
}

final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Swift.Error>?
}
