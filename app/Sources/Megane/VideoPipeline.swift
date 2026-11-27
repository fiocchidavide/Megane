import MeganeKit
import CMPV
import CoreVideo
import Foundation
import Metal
import OpenGL.GL3
import QuartzCore

/// mpv render API → IOSurface → Neural Engine → Metal, on a dedicated render thread.
///
/// Per new video frame:
///   1. mpv renders the frame (hardware-decoded, colour-converted, no subtitles/OSD) at its
///      native size, through OpenGL, into an IOSurface-backed BGRA buffer: zero-copy. The
///      buffer has the smallest size the model was exported for that holds the frame; mpv
///      draws into its top-left and the rest repeats the frame's last column and row.
///   2. The student model runs on that same buffer on the ANE (``StudentUpscaler``).
///   3. ``Compositor`` composes the 2× frame straight into the window's drawable and the
///      subtitle overlay is drawn on top at display resolution.
///   4. The drawable is presented at mpv's target time (mpv hands frames out ~50 ms early,
///      which hides the ANE latency and keeps A/V sync exact).
/// Nothing runs between frames: no new frame, no work.
final class VideoPipeline: @unchecked Sendable {

    enum Error: Swift.Error, CustomStringConvertible {
        case gl(String), render(Int32)
        var description: String {
            switch self {
            case .gl(let s): return "OpenGL: \(s)"
            case .render(let rc): return "mpv render context: \(String(cString: mpv_error_string(rc)))"
            }
        }
    }

    let layer: CAMetalLayer
    /// Draws subtitles (and anything else) over the composed video, in display pixels.
    /// `gamma` is the layer's transfer (``setColorSpace``), 0 when untagged, for overlays whose
    /// colours are meant for the display as they are.
    var overlay: ((MTLRenderCommandEncoder, _ videoRect: CGRect, _ targetSize: CGSize, _ time: Double,
                   _ gamma: Float) -> Void)?
    /// Called on the main queue when the source size changes or the ANE can't serve it.
    var onStatus: ((String) -> Void)?
    /// Timings for the info panel; recorded only while enabled.
    let performance = PerformanceLog()

    private let mpv: MPV
    private var modelURL: URL                       // render queue
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let compositor: Compositor
    private let renderQueue = DispatchQueue(label: "anime4k.render", qos: .userInteractive)

    private var glContext: CGLContextObj?
    private var renderContext: OpaquePointer?

    // render-thread state
    private var targets: [GLTarget] = []
    private var nextTarget = 0
    private var student: StudentUpscaler?
    private var zeroResidual: CVPixelBuffer?        // for sizes the model wasn't exported for
    private var modelSizes: (url: URL, sizes: [(Int, Int)])?
    private var frameSize = (0, 0)                  // the video inside the targets (top-left)
    private var last: (source: CVPixelBuffer, residual: CVPixelBuffer)?
    private var lastRect = CGRect.zero              // where the video was drawn, in drawable pixels
    private let clockOffset: Double                 // CACurrentMediaTime() - mpv_get_time_ns()/1e9

    // Written on the main queue from mpv property changes, read on the render thread (which
    // must not call ordinary libmpv functions: see "Threading" in mpv/render.h).
    private let lock = NSLock()
    private var videoSize: (Int, Int)?
    private var clock = (pts: 0.0, at: 0.0, speed: 1.0, paused: false)
    private var upscaling = true
    private var gamma: Float = 0

    private struct GLTarget {
        let buffer: CVPixelBuffer
        let texture: GLuint
        let fbo: GLuint
        var width: Int { CVPixelBufferGetWidth(buffer) }
        var height: Int { CVPixelBufferGetHeight(buffer) }
    }

    init(mpv: MPV, modelURL: URL) throws {
        self.mpv = mpv
        self.modelURL = modelURL
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        compositor = try Compositor(device: device)
        layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        clockOffset = CACurrentMediaTime() - Double(mpv_get_time_ns(mpv.handle)) / 1e9

        try renderQueue.sync { try self.setUpGL() }
        mpv_render_context_set_update_callback(renderContext, { ctx in
            let me = Unmanaged<VideoPipeline>.fromOpaque(ctx!).takeUnretainedValue()
            me.renderQueue.async { me.update() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Free the render context; must happen before the mpv core is destroyed.
    func shutdown() {
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        renderQueue.sync {
            CGLSetCurrentContext(glContext)
            for t in targets { var f = t.fbo, tex = t.texture; glDeleteFramebuffers(1, &f); glDeleteTextures(1, &tex) }
            mpv_render_context_free(renderContext)
            renderContext = nil
        }
    }

    /// From `video-params` (dw, dh): the size mpv renders each frame at.
    func setVideoSize(_ w: Int, _ h: Int) { lock.withLock { videoSize = (w, h) } }

    /// From `video-params` (primaries, gamma): what the frames' values mean, so macOS can
    /// convert them for the display, as mpv does when it colour-manages (IINA). mpv hands us
    /// the video's own values (BT.1886: gamma 2.4), which an untagged layer would show with
    /// the display's lighter curve: lifted shadows. Transfers other than BT.1886 and sRGB
    /// (HDR) stay untagged.
    func setColorSpace(primaries: String?, gamma transfer: String?) {
        let g: Float = switch transfer ?? "bt.1886" {
        case "bt.1886": 2.4
        case "srgb": -1      // the sRGB curve itself
        default: 0
        }
        let space = g == 0 ? nil : Self.colorSpace(primaries: primaries ?? "bt.709", sRGBCurve: g < 0)
        lock.withLock { gamma = space == nil ? 0 : g }
        layer.colorspace = space
        redraw()
    }

    /// RGB with the given primaries (D65) and BT.1886's gamma 2.4; or sRGB itself (sRGB-curve
    /// video is sRGB in practice, whatever primaries it claims).
    private static func colorSpace(primaries: String, sRGBCurve: Bool) -> CGColorSpace? {
        if sRGBCurve { return CGColorSpace(name: CGColorSpace.sRGB) }
        // CIE xy of R, G, B
        let xy: [(Double, Double)] = switch primaries {
        case "bt.601-525": [(0.630, 0.340), (0.310, 0.595), (0.155, 0.070)]   // SMPTE C
        case "bt.601-625": [(0.640, 0.330), (0.290, 0.600), (0.150, 0.060)]   // EBU
        case "bt.2020": [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)]
        default: [(0.640, 0.330), (0.300, 0.600), (0.150, 0.060)]             // BT.709 (and sRGB)
        }
        // RGB → XYZ: each primary's XYZ (Y = 1) scaled so R + G + B = the D65 white
        let white = (x: 0.3127, y: 0.3290)
        let W = [white.x / white.y, 1, (1 - white.x - white.y) / white.y]
        let P = xy.map { [$0.0 / $0.1, 1, (1 - $0.0 - $0.1) / $0.1] }   // columns
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        // solve [P] s = W (Cramer), rows = X, Y, Z
        let rows = (0..<3).map { r in (0..<3).map { c in P[c][r] } }
        let d = det(rows)
        let s = (0..<3).map { k in det(rows.enumerated().map { r, row in row.enumerated().map { c, v in c == k ? W[r] : v } }) / d }
        let matrix = (0..<3).flatMap { c in P[c].map { CGFloat($0 * s[c]) } }   // Xr Yr Zr Xg Yg Zg Xb Yb Zb
        return CGColorSpace(calibratedRGBWhitePoint: W.map { CGFloat($0) }, blackPoint: [0, 0, 0],
                            gamma: [2.4, 2.4, 2.4], matrix: matrix)
    }

    /// From `playback-time`/`speed`/`pause`: lets the render thread place subtitles in time.
    func setClock(pts: Double? = nil, speed: Double? = nil, paused: Bool? = nil) {
        lock.withLock {
            if let pts { clock.pts = pts; clock.at = CACurrentMediaTime() }
            if let speed { clock.pts = mediaTime(at: CACurrentMediaTime()); clock.at = CACurrentMediaTime(); clock.speed = speed }
            if let paused { clock.paused = paused }
        }
    }

    /// Media time shown at host time `t` (extrapolated from the last `playback-time`).
    private func mediaTime(at t: CFTimeInterval) -> Double {
        clock.paused ? clock.pts : clock.pts + max(0, t - clock.at) * clock.speed
    }

    /// Turn the ANE upscaler on or off. Off, frames get plain bilinear 2× (a zero residual
    /// through the same compositor) and the Neural Engine isn't used at all. The current frame
    /// is redone immediately, so the switch shows even while paused.
    func setUpscaling(_ on: Bool) {
        lock.withLock { upscaling = on }
        renderQueue.async {
            guard let source = self.last?.source else { return }
            let residual = self.residual(for: source)
            self.last = (source, residual)
            self.present(source: source, residual: residual, at: 0)
        }
    }

    /// Switch to another exported model (e.g. the exact Anime4K rewrite instead of the student);
    /// the current frame is redone with it.
    func setModel(_ url: URL) {
        renderQueue.async {
            guard url != self.modelURL else { return }
            self.modelURL = url
            guard let t = self.targets.first else { return }
            // another model may come in other sizes: rebuild the targets on the next frame
            guard let b = self.bucket(for: self.frameSize), b == (t.width, t.height) else {
                self.frameSize = (0, 0)
                self.student = nil
                return
            }
            self.loadModel(width: t.width, height: t.height)
            guard let source = self.last?.source else { return }
            let residual = self.residual(for: source)
            self.last = (source, residual)
            self.present(source: source, residual: residual, at: 0)
        }
    }

    /// The model's residual for `source`, or a zero one when upscaling is off or unavailable.
    private func residual(for source: CVPixelBuffer) -> CVPixelBuffer {
        if lock.withLock({ upscaling }), let student, let r = try? student.run(source) { return r }
        return zeroResidual(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
    }

    /// Re-compose the last frame (window resized, subtitles changed while paused, ...).
    func redraw() {
        renderQueue.async {
            guard let last = self.last else { return }
            self.present(source: last.source, residual: last.residual, at: 0)
        }
    }

    // MARK: - OpenGL / mpv render context

    private func setUpGL() throws {
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, CGLPixelFormatAttribute(0),
        ]
        var pix: CGLPixelFormatObj?
        var count: GLint = 0
        guard CGLChoosePixelFormat(attrs, &pix, &count) == kCGLNoError, let pix else { throw Error.gl("pixel format") }
        defer { CGLReleasePixelFormat(pix) }
        guard CGLCreateContext(pix, nil, &glContext) == kCGLNoError, let glContext else { throw Error.gl("context") }
        CGLSetCurrentContext(glContext)

        // opened once; mpv looks up each GL function through it
        let gl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)
        var glInit = mpv_opengl_init_params(get_proc_address: { gl, name in dlsym(gl, name) },
                                            get_proc_address_ctx: gl)
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }
        let rc = withUnsafeMutablePointer(to: &glInit) { initPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return mpv_render_context_create(&renderContext, mpv.handle, &params)
        }
        if rc < 0 { throw Error.render(rc) }
    }

    /// Two IOSurface-backed BGRA buffers at the video's size, each wrapped as a GL FBO.
    private func makeTargets(width: Int, height: Int) throws {
        for t in targets { var f = t.fbo, tex = t.texture; glDeleteFramebuffers(1, &f); glDeleteTextures(1, &tex) }
        targets = []
        for _ in 0..<2 {
            var attrs = PixelBuffer.attributes
            attrs[kCVPixelBufferOpenGLCompatibilityKey as String] = true
            var pb: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb,
                  let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { throw Error.gl("IOSurface") }
            var tex: GLuint = 0, fbo: GLuint = 0
            glGenTextures(1, &tex)
            glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), tex)
            guard CGLTexImageIOSurface2D(glContext!, GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_RGBA),
                                         GLsizei(width), GLsizei(height), GLenum(GL_BGRA),
                                         GLenum(GL_UNSIGNED_INT_8_8_8_8_REV), surface, 0) == kCGLNoError
            else { throw Error.gl("CGLTexImageIOSurface2D") }
            glGenFramebuffers(1, &fbo)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                   GLenum(GL_TEXTURE_RECTANGLE), tex, 0)
            guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE)
            else { throw Error.gl("framebuffer incomplete") }
            targets.append(GLTarget(buffer: pb, texture: tex, fbo: fbo))
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }

    // MARK: - Per frame (render thread)

    private func update() {
        guard let renderContext else { return }
        CGLSetCurrentContext(glContext)
        let flags = mpv_render_context_update(renderContext)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }

        // The size mpv will output: the video's display size (stored size, aspect-corrected).
        guard let (w, h) = lock.withLock({ videoSize }), w > 0, h > 0 else {
            skipFrame()
            return
        }
        // Padded to a size the model has; none holds it (above 1080p): the frame's own size,
        // even (the model works on 2x2 blocks), without upscaling.
        let (width, height) = bucket(for: (w, h)) ?? (w & ~1, h & ~1)
        let frame = (min(w, width), min(h, height))
        do {
            if targets.first?.width != width || targets.first?.height != height || frameSize != frame {
                frameSize = frame
                if targets.first?.width != width || targets.first?.height != height {
                    try makeTargets(width: width, height: height)
                }
                loadModel(width: width, height: height)
            }
        } catch {
            report("video output failed: \(error)")
            skipFrame()
            return
        }

        var info = mpv_render_frame_info()
        _ = withUnsafeMutablePointer(to: &info) { p in
            var param = mpv_render_param(type: MPV_RENDER_PARAM_NEXT_FRAME_INFO, data: UnsafeMutableRawPointer(p))
            return mpv_render_context_get_info(renderContext, param)
        }

        let target = targets[nextTarget]
        nextTarget = (nextTarget + 1) % targets.count
        let t0 = CACurrentMediaTime()
        // mpv sees a frame-sized framebuffer, so it draws 1:1 into the top-left of the target
        var fbo = mpv_opengl_fbo(fbo: Int32(target.fbo), w: Int32(frame.0), h: Int32(frame.1), internal_format: 0)
        var flip: Int32 = 0
        var block: Int32 = 0   // don't wait for the display time: we spend it on the ANE instead
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: &flip),
                mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: &block),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            _ = mpv_render_context_render(renderContext, &params)
        }
        padEdges(target, frame: frame)
        glFinish()   // the IOSurface must be complete before the ANE reads it
        let t1 = CACurrentMediaTime()

        let residual = self.residual(for: target.buffer)
        let t2 = CACurrentMediaTime()
        performance.frame(render: t1 - t0, ane: t2 - t1)

        last = (target.buffer, residual)
        // target_time is in mpv_get_time_ns() units (render.h says _us; mpv 0.41 delivers ns).
        let when = info.target_time > 0 ? Double(info.target_time) / 1e9 + clockOffset : 0
        present(source: target.buffer, residual: residual, at: when)
        mpv_render_context_report_swap(renderContext)
    }

    /// The smallest size the current model was exported for that holds `frame`.
    private func bucket(for frame: (Int, Int)) -> (Int, Int)? {
        if modelSizes?.url != modelURL {
            let sizes = StudentUpscaler.sizes(of: modelURL).compactMap { name -> (Int, Int)? in
                let wh = name.dropFirst().split(separator: "x").compactMap { Int($0) }   // "f1280x720"
                return wh.count == 2 ? (wh[0], wh[1]) : nil
            }
            modelSizes = (modelURL, sizes)
        }
        return modelSizes!.sizes.filter { $0.0 >= frame.0 && $0.1 >= frame.1 }.min { $0.0 * $0.1 < $1.0 * $1.1 }
    }

    /// Fill the target outside the frame with its last column, then its last row (corner
    /// included): no edge for the network to see at the frame's border, as with the GLSL
    /// shaders, which clamp there. Blits within one framebuffer, regions disjoint.
    private func padEdges(_ target: GLTarget, frame: (Int, Int)) {
        let (w, h) = (GLint(frame.0), GLint(frame.1))
        let (pw, ph) = (GLint(target.width), GLint(target.height))
        guard w < pw || h < ph else { return }
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), target.fbo)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), target.fbo)
        if w < pw {
            glBlitFramebuffer(w - 1, 0, w, h, w, 0, pw, h, GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
        }
        if h < ph {
            glBlitFramebuffer(0, h - 1, pw, h, 0, h, pw, ph, GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }

    private func skipFrame() {
        var skip: Int32 = 1
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: &skip),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        _ = mpv_render_context_render(renderContext, &params)
    }

    private func present(source: CVPixelBuffer, residual: CVPixelBuffer, at time: CFTimeInterval) {
        guard let drawable = layer.nextDrawable(), let commandBuffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let size = (drawable.texture.width, drawable.texture.height)
        let pts = lock.withLock { mediaTime(at: time > 0 ? time : CACurrentMediaTime()) }
        do {
            try compositor.encode(source: source, residual: residual, frame: frameSize, into: commandBuffer, target: pass,
                                  targetSize: size) { encoder, rect in
                self.lastRect = rect
                self.overlay?(encoder, rect, CGSize(width: size.0, height: size.1), pts, self.lock.withLock { self.gamma })
            }
        } catch {
            return
        }
        if performance.isEnabled {
            let log = performance
            log.output(rect: lastRect, target: size)
            commandBuffer.addCompletedHandler { cb in log.gpu(cb.gpuEndTime - cb.gpuStartTime) }
            drawable.addPresentedHandler { d in if d.presentedTime > 0 { log.presented(at: d.presentedTime) } }
        }
        if time > CACurrentMediaTime(), time < CACurrentMediaTime() + 0.5 {
            commandBuffer.present(drawable, atTime: time)
        } else {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    private func loadModel(width: Int, height: Int) {
        let (fw, fh) = frameSize
        let padded = (width, height) != frameSize ? (width, height) : nil
        let name = modelURL.deletingPathExtension().lastPathComponent
        do {
            student = try StudentUpscaler(modelURL: modelURL, width: width, height: height)
            performance.model(name, source: frameSize, padded: padded, active: true)
            report("\(fw)×\(fh) → \(2 * fw)×\(2 * fh) on the Neural Engine")
        } catch {
            student = nil
            performance.model(name, source: frameSize, padded: nil, active: false)
            report("no ANE model for \(fw)×\(fh): showing without upscaling")
        }
    }

    /// An all-zero residual: the compositor then outputs plain bilinear 2× (+ highlight clamp).
    private func zeroResidual(width: Int, height: Int) -> CVPixelBuffer {
        if let z = zeroResidual, CVPixelBufferGetWidth(z) == width,
           CVPixelBufferGetHeight(z) == StudentUpscaler.channels * height { return z }
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(kCFAllocatorDefault, width, StudentUpscaler.channels * height,
                            kCVPixelFormatType_OneComponent16Half, attrs as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), 0, CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        zeroResidual = pb
        return pb!
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.onStatus?(message) }
    }
}

/// What the info panel shows about the pipeline: per-frame times over the last seconds, and
/// what is being drawn where. Written from the render thread and Metal's completion threads.
final class PerformanceLog: @unchecked Sendable {

    struct Snapshot {
        var rendered = 0.0, shown = 0.0                   // frames per second
        var render = Stat(), ane = Stat(), gpu = Stat()   // seconds
        var source = (0, 0), target = (0, 0)
        var rect = CGRect.zero
        var model = "", modelActive = false
        var padded: (Int, Int)?                           // the model's input, when larger than source
    }

    struct Stat { var average = 0.0, max = 0.0 }

    private let lock = NSLock()
    private var enabled = false
    private var frames: [(at: Double, render: Double, ane: Double)] = []
    private var gpuTimes: [(at: Double, time: Double)] = []
    private var presents: [Double] = []
    private var current = Snapshot()

    var isEnabled: Bool { lock.withLock { enabled } }

    func setEnabled(_ on: Bool) {
        lock.withLock {
            enabled = on
            frames = []; gpuTimes = []; presents = []
        }
    }

    func frame(render: Double, ane: Double) {
        lock.withLock {
            guard enabled else { return }
            let now = CACurrentMediaTime()
            frames.append((now, render, ane))
            frames.removeAll { now - $0.at > 2 }
        }
    }

    func gpu(_ time: Double) {
        lock.withLock {
            let now = CACurrentMediaTime()
            gpuTimes.append((now, time))
            gpuTimes.removeAll { now - $0.at > 2 }
        }
    }

    func presented(at time: Double) {
        lock.withLock {
            presents.append(time)
            presents.removeAll { time - $0 > 2 }
        }
    }

    func output(rect: CGRect, target: (Int, Int)) { lock.withLock { current.rect = rect; current.target = target } }

    func model(_ name: String, source: (Int, Int), padded: (Int, Int)?, active: Bool) {
        lock.withLock { current.model = name; current.source = source; current.padded = padded; current.modelActive = active }
    }

    /// Rates and times over the last `window` seconds.
    func snapshot(over window: Double = 1) -> Snapshot {
        lock.withLock {
            let now = CACurrentMediaTime()
            var s = current
            let f = frames.filter { now - $0.at <= window }
            let g = gpuTimes.filter { now - $0.at <= window }
            s.rendered = Double(f.count) / window
            s.shown = Double(presents.filter { now - $0 <= window }.count) / window
            func stat(_ v: [Double]) -> Stat { Stat(average: v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count), max: v.max() ?? 0) }
            s.render = stat(f.map(\.render))
            s.ane = stat(f.map(\.ane))
            s.gpu = stat(g.map(\.time))
            return s
        }
    }
}
