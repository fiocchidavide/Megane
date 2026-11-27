import MeganeKit
import AppKit
import AVFoundation
import CoreML
import MetalKit

/// Live playback: decode → upscale → draw with Metal, per frame.
///
/// With a student model (distilled from Anime4K), each new frame runs on the Neural Engine and the
/// ``Compositor`` builds the 2× image on the GPU. With an image-to-image model (the
/// transpiled Anime4K) the model's output is drawn directly.
///
/// Options: `--fullscreen`, `--start <s>` (seek), `--duration <s>` (quit after; for power runs),
/// `--passthrough` (show the source frame, no upscaling: the player's own baseline cost).
func runPlay(modelURL: URL, videoURL: URL, computeUnits: MLComputeUnits?, flags: [String: String]) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let controller = try PlayerController(modelURL: modelURL, videoURL: videoURL, computeUnits: computeUnits,
                                          passthrough: flags["passthrough"] != nil)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered, defer: false
    )
    window.title = "Megane — \(videoURL.lastPathComponent)"
    window.contentView = controller.view
    window.contentAspectRatio = NSSize(width: 16, height: 9)
    window.center()
    window.makeKeyAndOrderFront(nil)
    if flags["fullscreen"] != nil { window.toggleFullScreen(nil) }

    app.activate(ignoringOtherApps: true)
    controller.start(at: Double(flags["start"] ?? "") ?? 0)
    if let duration = Double(flags["duration"] ?? "") {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            controller.printStats()
            exit(0)
        }
    }
    app.run()
}

final class PlayerController: NSObject, MTKViewDelegate {
    let view: MTKView
    private let reader: VideoReader
    private let renderer: MetalRenderer
    private let modelURL: URL
    private let isStudent: Bool
    private let passthrough: Bool
    private let computeUnits: MLComputeUnits
    private let upscaler: Upscaler?           // image-to-image models
    private var student: StudentUpscaler?     // created on the first frame (its size picks the function)
    private let compositor: Compositor

    private var frames = 0
    private var modelTime = 0.0
    private let gpuClock = GPUClock()
    private var lastError: String?

    init(modelURL: URL, videoURL: URL, computeUnits: MLComputeUnits?, passthrough: Bool) throws {
        self.modelURL = modelURL
        self.passthrough = passthrough
        self.isStudent = StudentUpscaler.isStudent(modelURL)
        // Students default to the ANE (Core ML's own pick is the GPU); image models to `.all`.
        self.computeUnits = computeUnits ?? (isStudent ? .cpuAndNeuralEngine : .all)
        self.upscaler = isStudent || passthrough ? nil : try Upscaler(modelURL: modelURL, computeUnits: self.computeUnits)
        self.renderer = try MetalRenderer()
        self.compositor = try Compositor(device: renderer.device)
        self.reader = VideoReader(url: videoURL)

        self.view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        super.init()
        view.delegate = self
        print(passthrough ? "passthrough: no upscaling"
              : "model: \(modelURL.lastPathComponent) (\(isStudent ? "student, ANE + Metal compositor" : "image model"))")
    }

    func start(at seconds: Double) {
        if seconds > 0 {
            reader.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                               toleranceBefore: .zero, toleranceAfter: .zero)
        }
        reader.play()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let frame = reader.currentFrame() else { return }   // nil unless a new video frame is due
        let t0 = CACurrentMediaTime()
        if passthrough {
            renderer.draw(pixelBuffer: frame, to: view)
        } else if isStudent {
            drawStudent(frame)
        } else {
            let upscaled = (try? upscaler!.upscale(frame)) ?? frame
            modelTime += CACurrentMediaTime() - t0
            renderer.draw(pixelBuffer: upscaled, to: view)
        }
        frames += 1
    }

    private func drawStudent(_ frame: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        do {
            if student?.width != w || student?.height != h {
                student = try StudentUpscaler(modelURL: modelURL, width: w, height: h, computeUnits: computeUnits)
                print("source \(w)x\(h) -> \(2 * w)x\(2 * h) (compute: \(computeUnits.name))")
            }
            let t0 = CACurrentMediaTime()
            let residual = try student!.run(frame)
            modelTime += CACurrentMediaTime() - t0
            guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
                  let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
            try compositor.encode(source: frame, residual: residual, into: commandBuffer, target: pass,
                                  targetSize: (drawable.texture.width, drawable.texture.height))
            let gpuClock = self.gpuClock
            commandBuffer.addCompletedHandler { cb in gpuClock.add(cb.gpuEndTime - cb.gpuStartTime) }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        } catch {
            if lastError != "\(error)" { print("upscale failed, showing source: \(error)") }
            lastError = "\(error)"
            renderer.draw(pixelBuffer: frame, to: view)
        }
    }

    func printStats() {
        guard frames > 0 else { return print("no frames shown") }
        print(String(format: "frames shown: %d, model time: %.2f ms/frame, GPU time (compose + draw): %.2f ms/frame",
                     frames, modelTime / Double(frames) * 1000, gpuClock.total / Double(frames) * 1000))
    }
}

/// GPU time summed from command-buffer completion handlers (which run off the main thread).
final class GPUClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0
    func add(_ t: Double) { lock.withLock { seconds += t } }
    var total: Double { lock.withLock { seconds } }
}
