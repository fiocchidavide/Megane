import AppKit
import CMPV
import Metal
import QuartzCore
import SwiftUI

/// The macOS player window: owns mpv, the ANE video pipeline and subtitles, and hosts the
/// shared SwiftUI overlay (``PlayerOverlay``) above the video.
///
/// mpv is the source of truth for playback state; this class observes its properties and
/// mirrors them into ``PlayerModel``, the subtitle renderer and the pipeline. User input goes
/// back to mpv as key presses (so mpv's bindings and ``KeyBindings`` apply) or as commands
/// (menus, controls). Commands the app implements itself arrive back as `script-message`s.
final class PlayerWindowController: NSWindowController, NSWindowDelegate {

    let mpv: MPV
    let pipeline: VideoPipeline
    let model = PlayerModel()
    let preferences: Preferences
    private(set) var bindings: KeyBindings!
    /// `--model`: a model given on the command line (the quality setting doesn't apply).
    let modelOverride: URL?
    private(set) var isLoaded = false

    private let models: [Preferences.Quality: URL]
    private let subtitles = Subtitles()
    private let subtitleOverlay: SubtitleOverlay
    private let videoView: VideoView

    private var path: String?
    private var videoSize: (Int, Int)?
    private var sizedForVideo: (Int, Int)?
    private var tracks: [[String: Any]] = []
    private var chapterTitles: [String] = []
    private var lastStatus: String?
    private var loadedAt = 0.0
    private var deferredOptions: [(String, String)] = []   // applied once the first file is loaded
    private var monitors: [Any] = []
    private var scrollAccumulator = CGPoint.zero
    private var infoTimer: Timer?
    private var systemMonitor = SystemMonitor()
    // network streams: what the buffering indicator shows
    private var isNetwork = false
    private var opening = false         // from start-file until the first frame
    private var pausedForCache = false
    private var seeking = false
    private var bufferPercent: Int?
    private var cacheSpeed = 0
    private var bufferingTask: Task<Void, Never>?

    init(models: [Preferences.Quality: URL], modelOverride: URL?, preferences: Preferences,
         mpvOptions: [(String, String)] = [], upscaling: Bool? = nil) throws {
        self.models = models
        self.modelOverride = modelOverride
        self.preferences = preferences
        mpv = try MPV(options: PlayerOptions.initial)
        preferences.apply(to: mpv)                                           // Settings, after mpv.conf
        // Command line, like mpv's. `idle` waits for the first file: with idle=no and nothing
        // loaded yet (the window opens first), mpv would quit immediately.
        for (name, value) in mpvOptions where name != "idle" { mpv.set(name, value) }
        for (name, value) in PlayerOptions.forced { mpv.set(name, value) }  // what the pipeline needs
        pipeline = try VideoPipeline(mpv: mpv, modelURL: modelOverride ?? models[preferences.quality]!)
        subtitleOverlay = try SubtitleOverlay(device: pipeline.layer.device!)
        videoView = VideoView(layer: pipeline.layer)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.center()
        window.title = "Megane"
        window.setFrameAutosaveName("Player")
        super.init(window: window)
        window.delegate = self
        bindings = KeyBindings(mpv: mpv)
        deferredOptions = mpvOptions.filter { $0.0 == "idle" }
        let on = upscaling ?? preferences.upscaling
        model.upscaling = on
        model.upscaler = upscalerName
        pipeline.setUpscaling(on)
        subtitles.current.visible = preferences.subtitlesVisible
        layOut(in: window)
        wire()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Play `urls`: the first now, the rest queued in the playlist.
    func open(_ urls: [URL]) {
        for (i, url) in urls.enumerated() {
            mpv.command(["loadfile", url.isFileURL ? url.path : url.absoluteString, i == 0 ? "replace" : "append"])
            if url.isFileURL { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        }
    }

    /// Run a command in input.conf syntax (menus, controls).
    func run(_ command: String) {
        mpv.command(string: command)
        model.activity()
    }

    func shutdown() {
        monitors.forEach(NSEvent.removeMonitor)
        pipeline.shutdown()
        mpv.destroy()
    }

    // MARK: - layout

    private func layOut(in window: NSWindow) {
        let content = NSView()
        content.wantsLayer = true
        window.contentView = content
        let overlay = NSHostingView(rootView: PlayerOverlay(model: model))
        for v in [videoView, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                v.topAnchor.constraint(equalTo: content.topAnchor),
                v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    private func wire() {
        videoView.onResize = { [weak self] in self?.pipeline.redraw() }

        // Keys go to mpv from wherever focus is (the overlay's buttons take focus when clicked).
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  !(self.window?.firstResponder is NSTextView) else { return event }
            // leave ⌘-shortcuts to the menu bar
            if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return nil }
            guard let key = MPVKeys.name(for: event) else { return event }
            self.mpv.command(["keypress", key])
            self.model.activity()
            return nil
        }!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, event.window === self.window,
                  let button = [2: "MBTN_MID", 3: "MBTN_BACK", 4: "MBTN_FORWARD"][event.buttonNumber] else { return event }
            self.mpv.command(["keypress", button])
            return nil
        }!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.scroll(event)
            return nil
        }!)

        model.actions = .init(
            togglePause: { [weak self] in self?.mpv.command(["cycle", "pause"]) },
            seek: { [weak self] t, final in
                self?.mpv.commandAsync(["seek", String(t), final ? "absolute+exact" : "absolute+keyframes"])
            },
            selectAudio: { [weak self] id in self?.mpv.set("aid", String(id)) },
            selectSubtitle: { [weak self] id in self?.mpv.set("sid", id.map(String.init) ?? "no") },
            toggleMute: { [weak self] in self?.mpv.command(["cycle", "mute"]) },
            setVolume: { [weak self] v in self?.mpv.set("volume", String(v)) },
            toggleFullscreen: { [weak self] in self?.window?.toggleFullScreen(nil) },
            setUpscaling: { [weak self] on in self?.setUpscaling(on) },
            open: { [weak self] urls in self?.open(urls) },
            run: { [weak self] command in self?.run(command) })
        model.onControlsVisibility = { [weak self] visible in self?.controlsVisibilityChanged(visible) }
        preferences.onQualityChange = { [weak self] quality in
            guard let self, self.modelOverride == nil, let url = self.models[quality] else { return }
            self.pipeline.setModel(url)
            self.model.upscaler = self.upscalerName
            self.model.show(PlayerModel.OSD.upscaling(self.model.upscaling), quality.upscaler)
        }
        preferences.onSubtitlesVisibleChange = { [weak self] visible in
            guard let self, visible != self.subtitles.current.visible else { return }
            self.subtitles.current.visible = visible
            self.model.show(visible ? "captions.bubble.fill" : "captions.bubble", visible ? "Subtitles shown" : "Subtitles hidden")
            self.tracksChanged()
        }

        let overlay = subtitleOverlay
        let subs = subtitles
        pipeline.overlay = { encoder, rect, target, time, gamma in
            subs.render(time: time, videoSize: (Int(rect.width), Int(rect.height))) { images, changed in
                overlay.draw(images, changed: changed, origin: rect.origin, targetSize: target, gamma: gamma, encoder: encoder)
            }
        }
        pipeline.onStatus = { [weak self] message in
            print(message)
            guard let self, message != self.lastStatus else { return }
            self.lastStatus = message
            if !message.contains("Neural Engine") {
                self.model.show("exclamationmark.triangle", message, seconds: 3)
            } else if self.model.upscaling {   // the model loaded: same OSD as turning upscaling on
                self.model.show(PlayerModel.OSD.upscalingOn, "\(self.upscalerName) on")
            }
        }

        mpv.onProperty = { [weak self] name, value in self?.propertyChanged(name, value) }
        mpv.onEvent = { [weak self] event in self?.event(event) }
        mpv.onMessage = { [weak self] args in self?.message(args) }
        mpv.onLog = { [weak self] prefix, text in
            if prefix == "screenshot", text.hasPrefix("Screenshot: ") { self?.model.show("camera", "Screenshot saved") }
        }
        let observed: [(String, MPV.Kind)] = [
            ("video-params", .node), ("playback-time", .double), ("duration", .double), ("pause", .flag),
            ("speed", .double), ("media-title", .string), ("fullscreen", .flag), ("path", .string),
            ("track-list", .node), ("chapter-list", .node), ("chapter", .node), ("volume", .double), ("mute", .flag),
            ("sub-delay", .double), ("sub-scale", .double), ("sub-pos", .double), ("audio-delay", .double),
            ("ontop", .flag), ("loop-file", .string), ("loop-playlist", .string),
            ("ab-loop-a", .string), ("ab-loop-b", .string), ("video-rotate", .node), ("video-zoom", .double),
            ("panscan", .double), ("video-aspect-override", .string), ("deinterlace", .string),
            ("deband", .flag), ("hwdec-current", .string), ("playlist-pos", .node), ("playlist-count", .node),
            ("idle-active", .flag), ("paused-for-cache", .flag), ("seeking", .flag),
            ("cache-buffering-state", .node), ("cache-speed", .node), ("demuxer-cache-state", .node),
        ]
        for (name, kind) in observed { mpv.observe(name, kind) }

        if ProcessInfo.processInfo.environment["MEGANE_DEBUG"] != nil {
            pipeline.performance.setEnabled(true)
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let p = self?.pipeline.performance.snapshot(over: 2), p.rendered > 0 else { return print("debug: no frames") }
                print(String(format: "debug: %.1f fps, mpv render %.2f ms, ANE %.2f ms, compositor %.2f ms (avg)",
                             p.rendered, p.render.average * 1000, p.ane.average * 1000, p.gpu.average * 1000))
            }
        }
    }

    // MARK: - mpv → UI

    /// Changes caused by the user are announced on the OSD; values settling while a file
    /// loads are not.
    private var announcing: Bool { isLoaded && CACurrentMediaTime() - loadedAt > 1 }

    private func propertyChanged(_ name: String, _ value: Any?) {
        func on(_ s: Any?) -> Bool { (s as? String).map { $0 != "no" } ?? (s as? Bool ?? false) }
        func announce(_ symbol: String, _ text: @autoclosure () -> String) {
            if announcing { model.show(symbol, text()) }
        }
        switch name {
        case "video-params":
            guard let p = value as? [String: Any], let w = p["dw"] as? Int, let h = p["dh"] as? Int else { return }
            videoSize = (w, h)
            pipeline.setVideoSize(w, h)
            pipeline.setColorSpace(primaries: p["primaries"] as? String, gamma: p["gamma"] as? String)
            subtitles.current.storage = (w, h)
            sizeWindow(toVideo: w, h)
        case "playback-time":
            guard let t = value as? Double else { return }
            pipeline.setClock(pts: t)
            model.time = t
        case "duration":
            model.duration = value as? Double ?? 0
        case "pause":
            let paused = value as? Bool ?? false
            if ProcessInfo.processInfo.environment["MEGANE_DEBUG"] != nil { print("debug: pause = \(paused)") }
            pipeline.setClock(paused: paused)
            model.pausedChanged(paused)
        case "speed":
            guard let s = value as? Double else { return }
            pipeline.setClock(speed: s)
            model.speed = s
            announce("gauge.with.needle", String(format: "Speed %g×", (s * 100).rounded() / 100))
        case "media-title":
            model.title = (value as? String) ?? ""
            window?.title = model.title.isEmpty ? "Megane" : model.title
        case "fullscreen":
            if let fs = value as? Bool, fs != window?.styleMask.contains(.fullScreen) { window?.toggleFullScreen(nil) }
        case "path":
            path = value as? String
            isNetwork = path?.contains("://") ?? false
            bufferingChanged()
            if let path { subtitles.open(path) }
            if let path, !path.contains("://") { window?.representedURL = URL(fileURLWithPath: path) }
        case "track-list":
            tracks = (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            tracksChanged()
        case "chapter-list":
            let list = (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            chapterTitles = list.enumerated().map { $1["title"] as? String ?? "Chapter \($0 + 1)" }
            model.chapters = zip(list, chapterTitles).compactMap { c, title in
                (c["time"] as? Double).map { PlayerModel.Chapter(time: $0, title: title) }
            }
        case "chapter":
            guard let i = value as? Int, i >= 0, i < chapterTitles.count else { return }
            if preferences.chapterNotifications { announce("list.bullet", chapterTitles[i]) }
        case "volume":
            model.volume = value as? Double ?? model.volume
            announce(volumeSymbol, String(format: "Volume %.0f%%", model.volume))
        case "mute":
            model.muted = value as? Bool ?? false
            announce(volumeSymbol, model.muted ? "Muted" : "Unmuted")
        case "sub-delay":
            subtitles.current.delay = value as? Double ?? 0
            announce("clock.arrow.2.circlepath", String(format: "Subtitle delay %+.0f ms", subtitles.current.delay * 1000))
            pipeline.redraw()
        case "sub-scale":
            subtitles.current.scale = value as? Double ?? 1
            announce("textformat.size", String(format: "Subtitle size %.0f%%", subtitles.current.scale * 100))
            pipeline.redraw()
        case "sub-pos":
            subtitles.current.position = value as? Double ?? 100
            announce("arrow.up.and.down.text.horizontal", String(format: "Subtitle position %.0f%%", subtitles.current.position))
            pipeline.redraw()
        case "audio-delay":
            announce("clock.arrow.2.circlepath", String(format: "Audio delay %+.0f ms", (value as? Double ?? 0) * 1000))
        case "ontop":
            let top = value as? Bool ?? false
            window?.level = top ? .floating : .normal
            announce("pin", top ? "Float on top" : "Float on top off")
        case "loop-file":
            announce("repeat.1", on(value) ? "Loop file" : "Loop file off")
        case "loop-playlist":
            announce("repeat", on(value) ? "Loop playlist" : "Loop playlist off")
        case "ab-loop-a", "ab-loop-b":
            let a = Double(mpv.string("ab-loop-a") ?? ""), b = Double(mpv.string("ab-loop-b") ?? "")
            switch (a, b) {
            case let (a?, b?): announce("repeat", "A-B loop \(PlayerModel.format(a)) – \(PlayerModel.format(b))")
            case let (a?, nil): announce("repeat", "A-B loop from \(PlayerModel.format(a))")
            default: announce("repeat", "A-B loop cleared")
            }
        case "video-rotate":
            announce("rotate.right", "Rotation \(value as? Int ?? 0)°")
        case "video-zoom":
            announce("plus.magnifyingglass", String(format: "Zoom %.2f×", pow(2, value as? Double ?? 0)))
        case "panscan":
            announce("crop", String(format: "Crop %.0f%%", (value as? Double ?? 0) * 100))
        case "video-aspect-override":
            let v = value as? String ?? "no"
            announce("aspectratio", v == "no" || v == "-1" ? "Aspect ratio: default" : "Aspect ratio: \(v)")
        case "deinterlace":
            announce("rectangle.split.3x1", on(value) ? "Deinterlace on" : "Deinterlace off")
        case "deband":
            announce("camera.filters", on(value) ? "Deband on" : "Deband off")
        case "hwdec-current":
            let v = value as? String ?? "no"
            announce("cpu", v == "no" || v.isEmpty ? "Software decoding" : "Hardware decoding (\(v))")
        case "playlist-pos":
            model.playlistPosition = value as? Int ?? -1
        case "playlist-count":
            model.playlistCount = value as? Int ?? 0
        case "idle-active":
            isLoaded = !(value as? Bool ?? true)
            model.loaded = isLoaded
        case "paused-for-cache":
            pausedForCache = value as? Bool ?? false
            bufferingChanged()
        case "seeking":
            seeking = value as? Bool ?? false
            bufferingChanged()
        case "cache-buffering-state":
            bufferPercent = value as? Int
            bufferingChanged()
        case "cache-speed":
            cacheSpeed = value as? Int ?? 0
            bufferingChanged()
        case "demuxer-cache-state":
            let ranges = (value as? [String: Any])?["seekable-ranges"] as? [Any] ?? []
            model.cached = !isNetwork ? [] : ranges.compactMap {
                guard let r = $0 as? [String: Any], let a = r["start"] as? Double, let b = r["end"] as? Double, b > a else { return nil }
                return a...b
            }
        default:
            break
        }
    }

    private var volumeSymbol: String {
        model.muted ? "speaker.slash.fill" : model.volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    /// The tracks of one type ("video", "audio", "sub") for menus.
    func tracks(_ type: String) -> [PlayerModel.Track] {
        func title(_ t: [String: Any]) -> String {
            var parts: [String] = []
            if let title = t["title"] as? String { parts.append(title) }
            if let lang = t["lang"] as? String { parts.append(parts.isEmpty ? lang : "(\(lang))") }
            if parts.isEmpty { parts.append("Track \(t["id"] as? Int ?? 0)") }
            if let codec = t["codec"] as? String { parts.append("— \(codec)") }
            if t["external"] as? Bool == true { parts.append("[external]") }
            return parts.joined(separator: " ")
        }
        return tracks.filter { $0["type"] as? String == type }
            .map { PlayerModel.Track(id: $0["id"] as? Int ?? 0, title: title($0)) }
    }

    /// Mirror mpv's track selection into the model and the subtitle renderer.
    private func tracksChanged() {
        func selected(_ type: String) -> [String: Any]? {
            tracks.first { $0["type"] as? String == type && $0["selected"] as? Bool == true }
        }
        model.audioTracks = tracks("audio")
        model.subtitleTracks = tracks("sub")
        model.selectedAudio = selected("audio")?["id"] as? Int
        let previousSubtitle = model.selectedSubtitle
        let sub = selected("sub")
        model.selectedSubtitle = sub?["id"] as? Int

        // the selected subtitle → a libass track (text) or mpv's own rendering (image)
        var key: Subtitles.TrackKey?
        if let s = sub, let index = s["ff-index"] as? Int {
            let file = (s["external"] as? Bool == true) ? (s["external-filename"] as? String) : path
            if let file {
                subtitles.load(file)
                key = Subtitles.TrackKey(file: file, index: index)
            }
        }
        var settings = subtitles.current
        settings.track = key
        subtitles.current = settings
        model.subtitlesVisible = settings.visible
        let image = key.map(subtitles.isImage) ?? false
        mpv.set("sub-visibility", image && settings.visible ? "yes" : "no")
        if previousSubtitle != model.selectedSubtitle, announcing {
            let name = model.subtitleTracks.first { $0.id == model.selectedSubtitle }?.title
            model.show("captions.bubble", name ?? "Subtitles off")
        }
        pipeline.redraw()
    }

    private func event(_ id: mpv_event_id) {
        switch id {
        case MPV_EVENT_SHUTDOWN: NSApp.terminate(nil)
        case MPV_EVENT_SEEK: model.activity()
        case MPV_EVENT_START_FILE:
            opening = true
            isNetwork = mpv.string("path")?.contains("://") ?? false
            model.cached = []
            bufferingChanged()
        case MPV_EVENT_PLAYBACK_RESTART, MPV_EVENT_END_FILE:
            opening = false
            bufferingChanged()
        case MPV_EVENT_FILE_LOADED:
            loadedAt = CACurrentMediaTime()
            isLoaded = true
            model.loaded = true
            for (name, value) in deferredOptions { mpv.set(name, value) }
            deferredOptions = []
        default: break
        }
    }

    /// The buffering indicator, as IINA shows it: up while a network stream opens, seeks or
    /// waits for its cache. It appears only after a moment, so seeks within the cache don't
    /// flash it, and then follows mpv's fill level and download speed.
    private func bufferingChanged() {
        guard let state = buffering else {
            bufferingTask?.cancel()
            bufferingTask = nil
            model.buffering = nil
            return
        }
        if model.buffering != nil { model.buffering = state; return }
        guard bufferingTask == nil else { return }
        bufferingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.bufferingTask = nil
            self.model.buffering = self.buffering
        }
    }

    /// What the indicator should show now, nil when nothing is being waited for.
    private var buffering: PlayerModel.Buffering? {
        guard isNetwork, opening || pausedForCache || seeking else { return nil }
        return .init(percent: pausedForCache ? bufferPercent : nil, speed: cacheSpeed)
    }

    /// Commands the app implements, bound like any mpv command (``KeyBindings/builtins``).
    private func message(_ args: [String]) {
        guard let name = args.first else { return }
        let arg = args.count > 1 ? args[1] : "toggle"
        func flag(_ current: Bool) -> Bool { arg == "toggle" ? !current : arg != "off" && arg != "no" }
        switch name {
        case "megane-upscaling":
            setUpscaling(flag(model.upscaling))
        case "megane-subtitles":
            preferences.subtitlesVisible = flag(subtitles.current.visible)   // applied by onSubtitlesVisibleChange
        case "megane-window-scale":
            scaleWindow(Double(arg) ?? 1)
        case "megane-show-progress":
            model.activity()
        case "megane-info":
            showInfo(flag(infoTimer != nil))
        default:
            break
        }
    }

    // MARK: - info panel

    /// The playback info panel (`i`): what is playing, how it's drawn, and the measured cost
    /// of each frame. Timings are only recorded while it is shown.
    private func showInfo(_ on: Bool) {
        infoTimer?.invalidate()
        infoTimer = nil
        pipeline.performance.setEnabled(on || ProcessInfo.processInfo.environment["MEGANE_DEBUG"] != nil)
        guard on else { model.info = nil; return }
        _ = systemMonitor.cpuPercent()
        updateInfo()
        infoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateInfo() }
    }

    private func updateInfo() {
        let p = pipeline.performance.snapshot()
        func ms(_ s: PerformanceLog.Stat) -> String { String(format: "%.2f ms  (max %.2f)", s.average * 1000, s.max * 1000) }
        func size(_ w: Int, _ h: Int) -> String { "\(w) × \(h)" }
        func row(_ label: String, _ value: String?) -> PlayerModel.InfoRow? {
            value.flatMap { $0.isEmpty ? nil : PlayerModel.InfoRow(label: label, value: $0) }
        }
        var sections: [PlayerModel.InfoSection] = []

        let params = mpv.node("video-params") as? [String: Any] ?? [:]
        let fps = mpv.double("container-fps") ?? mpv.double("estimated-vf-fps")
        let hwdec = mpv.string("hwdec-current") ?? "no"
        sections.append(.init(title: "Video", rows: [
            row("File", mpv.string("filename")),
            row("Format", [mpv.string("video-format"), (params["w"] as? Int).map { size($0, params["h"] as? Int ?? 0) },
                           fps.map { String(format: "%.3f fps", $0) }].compactMap { $0 }.joined(separator: " · ")),
            row("Decoder", (hwdec == "no" || hwdec.isEmpty ? "software" : hwdec) + ((params["hw-pixelformat"] ?? params["pixelformat"]).map { " · \($0)" } ?? "")),
            row("Color", [params["colormatrix"], params["colorlevels"], params["primaries"], params["gamma"]]
                    .compactMap { $0 as? String }.joined(separator: " · ")),
        ].compactMap { $0 }))

        let rect = p.rect
        let upscaler = !model.upscaling ? "Off (bilinear 2×)"
            : p.modelActive ? "\(p.model) on the Neural Engine" + (p.padded.map { " (padded to \(size($0.0, $0.1)))" } ?? "")
            : p.model.isEmpty ? "—" : "No \(p.model) function for \(size(p.source.0, p.source.1)) (bilinear 2×)"
        let screen = window?.screen
        sections.append(.init(title: "Output", rows: [
            row("Upscaler", upscaler),
            row("Model output", p.source.0 > 0 ? size(p.source.0 * 2, p.source.1 * 2) : nil),
            row("On screen", rect.width > 0 ? size(Int(rect.width), Int(rect.height)) + String(format: " (%.2f× source)", rect.width / CGFloat(max(p.source.0, 1))) : nil),
            row("Drawable", p.target.0 > 0 ? size(p.target.0, p.target.1) : nil),
            row("Display", screen.map { "\($0.localizedName) · \($0.maximumFramesPerSecond) Hz" }),
        ].compactMap { $0 }))

        let dropped = [("decoder", "decoder-frame-drop-count"), ("output", "frame-drop-count"), ("late", "vo-delayed-frame-count")]
            .compactMap { name, prop in mpv.int(prop).map { "\($0) \(name)" } }.joined(separator: " · ")
        sections.append(.init(title: "Frames (last second)", rows: [
            row("Rate", String(format: "%.0f rendered · %.0f shown", p.rendered, p.shown)),
            row("mpv render", ms(p.render)),
            row("Neural Engine", ms(p.ane)),
            row("Compositor (GPU)", ms(p.gpu)),
            row("Dropped", dropped),
            row("A-V sync", mpv.double("avsync").map { String(format: "%+.1f ms", $0 * 1000) }),
        ].compactMap { $0 }))

        let audio = mpv.node("audio-params") as? [String: Any] ?? [:]
        sections.append(.init(title: "System", rows: [
            row("GPU", SystemMonitor.gpuUtilization().map { "\($0)% (whole system)" }),
            row("Megane CPU", systemMonitor.cpuPercent().map { String(format: "%.0f%% of one core", $0) }),
            row("Audio", [mpv.string("audio-codec-name"), (audio["channel-count"] as? Int).map { "\($0) ch" },
                          (audio["samplerate"] as? Int).map { String(format: "%g kHz", Double($0) / 1000) },
                          mpv.string("current-ao")].compactMap { $0 }.joined(separator: " · ")),
        ].compactMap { $0 }))
        model.info = sections
    }

    // MARK: - window

    /// The video at 1:1 output pixels: each source pixel becomes 2×2 on screen.
    private func actualSize(_ w: Int, _ h: Int, on screen: NSScreen) -> NSSize {
        NSSize(width: CGFloat(w) / screen.backingScaleFactor * 2, height: CGFloat(h) / screen.backingScaleFactor * 2)
    }

    /// Fit the window to the video's aspect, at most ~80% of the screen, once per video size.
    private func sizeWindow(toVideo w: Int, _ h: Int) {
        guard let window, sizedForVideo.map({ $0 != (w, h) }) ?? true else { return }
        sizedForVideo = (w, h)
        window.contentAspectRatio = NSSize(width: w, height: h)
        guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
        var size = actualSize(w, h, on: screen)
        let limit = screen.visibleFrame.size
        let fit = min(1, limit.width * 0.8 / size.width, limit.height * 0.8 / size.height)
        size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        window.setContentSize(size)
        window.center()
    }

    /// mpv's `window-scale`: 1 = actual size, limited to the screen; keeps the window centred.
    private func scaleWindow(_ scale: Double) {
        guard let window, let (w, h) = videoSize, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        var size = actualSize(w, h, on: screen)
        let limit = screen.visibleFrame.size
        let fit = min(scale, limit.width / size.width, limit.height / size.height)
        size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        window.setFrame(frame.intersection(screen.visibleFrame).isEmpty ? frame : constrain(frame, to: screen.visibleFrame),
                        display: true, animate: true)
        model.show("macwindow", String(format: "Window %g×", scale))
    }

    private func constrain(_ frame: NSRect, to bounds: NSRect) -> NSRect {
        var f = frame
        f.origin.x = min(max(f.origin.x, bounds.minX), bounds.maxX - f.width)
        f.origin.y = min(max(f.origin.y, bounds.minY), bounds.maxY - f.height)
        return f
    }

    /// The title bar fades with the controls, and the pointer hides over the video.
    private func controlsVisibilityChanged(_ visible: Bool) {
        guard let window else { return }
        if !visible, window.isKeyWindow, window.frame.contains(NSEvent.mouseLocation) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        guard !window.styleMask.contains(.fullScreen),
              let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            titlebar.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: - input

    /// Scroll wheel and trackpad → mpv's WHEEL_* keys (volume, seeking), one per notch or
    /// per ~16 points of trackpad travel.
    private func scroll(_ event: NSEvent) {
        if event.phase == .began { scrollAccumulator = .zero }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 16 : 1
        scrollAccumulator.x += event.scrollingDeltaX
        scrollAccumulator.y += event.scrollingDeltaY
        var mods = ""
        if event.modifierFlags.contains(.shift) { mods += "Shift+" }
        if event.modifierFlags.contains(.control) { mods += "Ctrl+" }
        if event.modifierFlags.contains(.option) { mods += "Alt+" }
        while abs(scrollAccumulator.y) >= step {
            mpv.command(["keypress", mods + (scrollAccumulator.y > 0 ? "WHEEL_UP" : "WHEEL_DOWN")])
            scrollAccumulator.y -= scrollAccumulator.y > 0 ? step : -step
        }
        while abs(scrollAccumulator.x) >= step {
            mpv.command(["keypress", mods + (scrollAccumulator.x > 0 ? "WHEEL_LEFT" : "WHEEL_RIGHT")])
            scrollAccumulator.x -= scrollAccumulator.x > 0 ? step : -step
        }
    }

    private func setUpscaling(_ on: Bool) {
        model.upscaling = on
        pipeline.setUpscaling(on)
        model.show(PlayerModel.OSD.upscaling(on), on ? "\(upscalerName) on" : "\(upscalerName) off")
    }

    /// The upscaler by quality mode; a `--model` given on the command line is neither.
    private var upscalerName: String { modelOverride == nil ? preferences.quality.upscaler : "Upscaling" }

    /// Whether the toggle-style command `command` (normalized, see ``KeyBindings/normalize``)
    /// is on now: drives menu check marks.
    func isOn(_ command: String) -> Bool {
        func aspect(_ s: String) -> Int {
            let parts = s.split(separator: ":").compactMap { Double($0) }
            let v = parts.count == 2 ? parts[0] / parts[1] : Double(s) ?? 0
            return v > 0 ? Int((v * 100).rounded()) : 0
        }
        switch command {
        case "cycle mute": return model.muted
        case "cycle ontop": return mpv.flag("ontop") ?? false
        case "cycle-values loop-file inf no": return (mpv.string("loop-file") ?? "no") != "no"
        case "cycle-values loop-playlist inf no": return (mpv.string("loop-playlist") ?? "no") != "no"
        case "ab-loop": return (mpv.string("ab-loop-a") ?? "no") != "no"
        case "cycle deinterlace": return mpv.string("deinterlace") == "yes"
        case "cycle deband": return mpv.flag("deband") ?? false
        case "cycle-values hwdec no auto": return !["no", ""].contains(mpv.string("hwdec-current") ?? "no")
        case "script-message megane-upscaling toggle": return model.upscaling
        case "script-message megane-subtitles toggle": return subtitles.current.visible
        case "script-message megane-info toggle": return infoTimer != nil
        default:
            if command.hasPrefix("set speed "), let v = Double(command.dropFirst(10)) {
                return abs((mpv.double("speed") ?? 1) - v) < 0.001
            }
            if command.hasPrefix("set video-rotate "), let v = Int(command.dropFirst(17)) {
                return mpv.int("video-rotate") == v
            }
            if command.hasPrefix("set video-aspect-override ") {
                return aspect(String(command.dropFirst(26))) == aspect(mpv.string("video-aspect-override") ?? "no")
            }
            return false
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) { mpv.set("fullscreen", "yes"); model.fullscreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        mpv.set("fullscreen", "no")
        model.fullscreen = false
        window?.standardWindowButton(.closeButton)?.superview?.alphaValue = model.controlsVisible ? 1 : 0
    }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

/// The view hosting the video's CAMetalLayer. Input is handled by the SwiftUI overlay above it.
final class VideoView: NSView {
    var onResize: (() -> Void)?
    private let metalLayer: CAMetalLayer

    init(layer: CAMetalLayer) {
        metalLayer = layer
        super.init(frame: .zero)
        self.layer = metalLayer   // layer-hosting: assign the layer before turning layers on
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); updateDrawableSize() }
    override func viewDidMoveToWindow() { updateDrawableSize() }
    override func viewDidChangeBackingProperties() { updateDrawableSize() }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0, size != metalLayer.drawableSize else { return }
        metalLayer.drawableSize = size
        onResize?()
    }
}
