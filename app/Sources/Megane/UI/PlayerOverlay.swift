import AppKit
import SwiftUI

/// Everything drawn over the video: the control bar, the OSD, and the video area's gestures
/// (hover, double-click for fullscreen, the context menu, file drops). Shared with iPad.
///
/// Controls are the system's own (sliders, borderless and toggle buttons, menus) on a Liquid
/// Glass panel (a material before macOS 26), like QuickTime Player's.
struct PlayerOverlay: View {
    @Bindable var model: PlayerModel

    var body: some View {
        ZStack {
            // the video area: transparent, but takes the pointer and the gestures
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in if case .active = phase { model.activity() } }
                .onTapGesture(count: 2) { model.actions.run("keypress MBTN_LEFT_DBL") }   // mpv: cycle fullscreen
                .onTapGesture { model.activity() }
                .contextMenu { PlayerMenu(model: model) }
                .dropDestination(for: URL.self) { urls, _ in
                    guard !urls.isEmpty else { return false }
                    model.actions.open(urls)
                    return true
                }

            // keeps the window title readable over bright video
            VStack {
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 72)
                Spacer()
            }
            .ignoresSafeArea()
            .opacity(model.controlsVisible && !model.fullscreen ? 1 : 0)
            .allowsHitTesting(false)

            ZStack {
                if let info = model.info {
                    InfoPanel(sections: info)
                        .padding(.top, model.fullscreen ? 16 : 40)
                        .padding(.leading, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }

                if let buffering = model.buffering {
                    BufferingView(state: buffering)
                        .transition(.opacity)
                }

                VStack {
                    if let osd = model.osd {
                        OSDView(osd: osd)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            .padding(.top, model.fullscreen ? 28 : 44)
                    }
                    Spacer()
                    if model.controlsVisible {
                        ControlBar(model: model)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 20)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: model.osd)
                .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)
            }
            .animation(.easeOut(duration: 0.2), value: model.buffering == nil)
        }
        .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Liquid Glass on macOS 26 and later, the HUD material before. Regular glass follows the
    /// system's Clear/Tinted setting and adapts to the video behind each panel on its own (so a
    /// panel over a dark area looks darker than one over a bright area, as system panels do).
    @ViewBuilder func panel<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

/// A HUD message, like the system's volume/brightness bezel.
struct OSDView: View {
    let osd: PlayerModel.OSD

    var body: some View {
        Label {
            Text(osd.text)
        } icon: {
            if let on = PlayerModel.OSD.upscalingState(osd.symbol) {
                GlassesMark(sharp: on).frame(width: 24, height: 17)
            } else {
                Image(systemName: osd.symbol)
            }
        }
            .font(.system(size: 15, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .panel(Capsule())
            .allowsHitTesting(false)
    }
}

/// Waiting for a network stream, like IINA's indicator: a spinner, then how far the cache has
/// filled towards resuming (a bar, once mpv reports it) and how fast data is coming in (once any is).
struct BufferingView: View {
    let state: PlayerModel.Buffering

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text(state.percent.map { "Buffering \($0)%" } ?? "Loading…")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
            if let percent = state.percent {
                ProgressView(value: Double(percent), total: 100)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 140)
            }
            if state.speed > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(state.speed), countStyle: .file) + "/s")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 140)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .panel(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// The bottom bar: the seek bar with times, then volume | transport | options.
struct ControlBar: View {
    @Bindable var model: PlayerModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // natural widths (digits are monospaced): the bar only moves when a digit is added
                Text(PlayerModel.format(model.seekDrag ?? model.time))
                SeekBar(model: model)
                Button { model.showRemaining.toggle() } label: {
                    Text(model.showRemaining ? "-" + PlayerModel.format(model.duration - (model.seekDrag ?? model.time))
                                             : PlayerModel.format(model.duration))
                }
                .help("Show remaining or total time")
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())

            // the same width as the row above: volume starts under the elapsed time,
            // fullscreen ends under the remaining time
            HStack(spacing: 0) {
                volume.frame(maxWidth: .infinity, alignment: .leading)
                transport
                options.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 28)
        }
        .foregroundStyle(.primary)   // white, as AppKit draws the menus' labels
        .buttonStyle(.borderless)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 820)
        .panel(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onHover { model.hoveringControls = $0 }
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Button(action: model.actions.toggleMute) {
                Image(systemName: volumeSymbol).frame(width: 22)
            }
            .help(model.muted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { model.muted ? 0 : model.volume }, set: { model.actions.setVolume($0) }), in: 0...100)
                .controlSize(.mini)
                .frame(width: 90)
        }
    }

    private var transport: some View {
        HStack(spacing: 22) {
            if model.playlistCount > 1 {
                Button { model.actions.run("playlist-prev") } label: { Image(systemName: "backward.end.fill") }
                    .disabled(model.playlistPosition <= 0)
                    .help("Previous file")
            }
            Button { model.actions.run("seek -5") } label: { Image(systemName: "gobackward.5") }
                .help("Back 5 seconds")
            Button(action: model.actions.togglePause) {
                Image(systemName: model.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 22))
                    .frame(width: 28, height: 28)   // the two symbols differ in height
            }
            .help(model.paused ? "Play" : "Pause")
            Button { model.actions.run("seek 5") } label: { Image(systemName: "goforward.5") }
                .help("Forward 5 seconds")
            if model.playlistCount > 1 {
                Button { model.actions.run("playlist-next") } label: { Image(systemName: "forward.end.fill") }
                    .disabled(model.playlistPosition >= model.playlistCount - 1)
                    .help("Next file")
            }
        }
        .disabled(!model.loaded)
    }

    private var options: some View {
        HStack(spacing: 14) {
            upscalingButton

            Menu {
                Picker("Speed", selection: Binding(get: { model.speed }, set: { model.actions.run("set speed \($0)") })) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(String(format: "%g×", (model.speed * 100).rounded() / 100))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .fixedSize()
            .help("Playback speed")

            if model.audioTracks.count > 1 {
                Menu {
                    TrackPicker(title: "Audio", tracks: model.audioTracks, selection: model.selectedAudio,
                                allowsOff: false) { model.actions.selectAudio($0 ?? 0) }
                } label: { Image(systemName: "waveform") }
                    .fixedSize()
                    .help("Audio track")
            }
            if !model.subtitleTracks.isEmpty {
                Menu {
                    TrackPicker(title: "Subtitles", tracks: model.subtitleTracks, selection: model.selectedSubtitle,
                                allowsOff: true, select: model.actions.selectSubtitle)
                } label: {
                    Image(systemName: model.selectedSubtitle == nil || !model.subtitlesVisible
                          ? "captions.bubble" : "captions.bubble.fill")
                }
                .fixedSize()
                .help("Subtitles")
            }

            Button(action: model.actions.toggleFullscreen) {
                Image(systemName: model.fullscreen ? "arrow.down.right.and.arrow.up.left"
                                                   : "arrow.up.left.and.arrow.down.right")
            }
            .help(model.fullscreen ? "Exit Full Screen" : "Enter Full Screen")
        }
    }

    /// The upscaling switch is the mark itself: smooth red glasses while upscaling, pixel-art
    /// glasses while not.
    private var upscalingButton: some View {
        Button { model.actions.setUpscaling(!model.upscaling) } label: {
            UpscalingMark(on: model.upscaling)
        }
        .help("\(model.upscaler) on the Neural Engine: \(model.upscaling ? "on" : "off")")
    }

    private var volumeSymbol: String {
        model.muted ? "speaker.slash.fill"
            : model.volume < 1 ? "speaker.fill"
            : model.volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }
}

/// The system slider over the media's duration, with chapter marks, a time (and chapter) preview
/// under the pointer and, for network streams, what is buffered (lighter, behind the track). Dragging
/// seeks live (keyframes), letting go seeks exactly.
struct SeekBar: View {
    @Bindable var model: PlayerModel
    /// Where the slider's track starts and ends inside its frame (the knob's half-width).
    private let inset: CGFloat = 8

    var body: some View {
        Slider(value: Binding(get: { model.seekDrag ?? model.time },
                              set: { t in model.seekDrag = t; model.actions.seek(t, false) }),
               in: 0...max(model.duration, 1),
               onEditingChanged: editingChanged)
            .controlSize(.small)
            .disabled(model.duration <= 0)
            .background {
                GeometryReader { geo in
                    let track = geo.size.width - 2 * inset
                    ZStack(alignment: .topLeading) {
                        if model.duration > 0 {
                            ForEach(model.cached, id: \.self) { r in
                                let a = min(max(r.lowerBound / model.duration, 0), 1)
                                let b = min(max(r.upperBound / model.duration, 0), 1)
                                Capsule().fill(.white.opacity(0.35))
                                    .frame(width: track * (b - a), height: 4)
                                    .offset(x: inset + track * a, y: geo.size.height / 2 - 2)
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay {
                GeometryReader { geo in
                    let track = geo.size.width - 2 * inset
                    ZStack(alignment: .topLeading) {
                        ForEach(model.chapters.filter { $0.time > 0 && $0.time < model.duration }, id: \.self) { c in
                            Capsule().fill(.white)
                                .frame(width: 2, height: 4)
                                .offset(x: inset + track * c.time / model.duration - 1, y: geo.size.height / 2 + 6)
                        }
                        if let x = model.seekHover, model.duration > 0 {
                            let t = model.duration * min(1, max(0, (x - inset) / track))
                            HStack(spacing: 6) {
                                if let chapter = model.chapters.last(where: { $0.time <= t }) {
                                    Text(chapter.title).lineLimit(1).frame(maxWidth: 220)
                                        .foregroundStyle(.secondary)
                                }
                                Text(PlayerModel.format(t)).monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .panel(Capsule())
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self, of: \.size.width) { model.seekPreviewWidth = $0 }
                            .offset(x: min(max(0, x - model.seekPreviewWidth / 2), geo.size.width - model.seekPreviewWidth), y: -26)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): model.seekHover = p.x
                case .ended: model.seekHover = nil
                }
            }
    }

    private func editingChanged(_ editing: Bool) {
        guard !editing, let t = model.seekDrag else { return }
        model.actions.seek(t, true)
        // hold the knob where it was let go until mpv reports the new position
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            model.seekDrag = nil
        }
    }
}

/// A checkmarked track list for menus (bar and context menu).
struct TrackPicker: View {
    let title: String
    let tracks: [PlayerModel.Track]
    let selection: Int?
    let allowsOff: Bool
    let select: (Int?) -> Void

    var body: some View {
        Picker(title, selection: Binding(get: { selection ?? 0 }, set: { select($0 == 0 ? nil : $0) })) {
            if allowsOff { Text("Off").tag(0) }
            ForEach(tracks) { Text($0.title).tag($0.id) }
        }
        .pickerStyle(.inline)
    }
}

/// The right-click (macOS) / long-press (iPad) menu over the video.
struct PlayerMenu: View {
    let model: PlayerModel

    var body: some View {
        Button(model.paused ? "Play" : "Pause", action: model.actions.togglePause)
        Divider()
        Toggle(model.upscaler, isOn: Binding(get: { model.upscaling }, set: { model.actions.setUpscaling($0) }))
        Menu("Speed") {
            Picker("Speed", selection: Binding(get: { model.speed }, set: { model.actions.run("set speed \($0)") })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
            }
            .pickerStyle(.inline)
        }
        if !model.subtitleTracks.isEmpty {
            Menu("Subtitles") {
                TrackPicker(title: "Subtitles", tracks: model.subtitleTracks, selection: model.selectedSubtitle,
                            allowsOff: true, select: model.actions.selectSubtitle)
            }
        }
        if model.audioTracks.count > 1 {
            Menu("Audio") {
                TrackPicker(title: "Audio", tracks: model.audioTracks, selection: model.selectedAudio,
                            allowsOff: false) { model.actions.selectAudio($0 ?? 0) }
            }
        }
        Divider()
        Button("Take Screenshot") { model.actions.run("screenshot") }
        Button("Float on Top") { model.actions.run("cycle ontop") }
        Button(model.fullscreen ? "Exit Full Screen" : "Enter Full Screen", action: model.actions.toggleFullscreen)
    }
}

/// The upscaling button's label: red while on, and grey like every other accent while the
/// window is inactive.
struct UpscalingMark: View {
    let on: Bool
    @Environment(\.appearsActive) private var active

    var body: some View {
        GlassesMark(sharp: on).frame(width: 24, height: 17)
            .foregroundStyle(on && active ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
    }
}

/// Megane's glasses, tinted like an SF Symbol: smooth (`sharp`, upscaled) or pixel art.
struct GlassesMark: View {
    let sharp: Bool

    var body: some View {
        if let image = sharp ? Self.smooth : Self.pixel {
            Image(nsImage: image).resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: sharp ? "eyeglasses" : "eyeglasses.slash")
        }
    }

    private static let smooth = load("Glasses")
    private static let pixel = load("GlassesPixel")

    /// The app bundle's copy, or the design folder's when run from a build.
    private static func load(_ name: String) -> NSImage? {
        let url = Bundle.main.url(forResource: name, withExtension: "svg")
            ?? URL(fileURLWithPath: #filePath)   // app/Sources/Megane/UI/PlayerOverlay.swift
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("design/\(name).svg")
        let image = NSImage(contentsOf: url)
        image?.isTemplate = true
        return image
    }
}

/// The playback info panel (`i`): measured values only, refreshed once a second.
struct InfoPanel: View {
    let sections: [PlayerModel.InfoSection]

    var body: some View {
        // one grid for every section, so the values line up from top to bottom
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(sections) { section in
                GridRow {
                    Text(section.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, section.id == sections.first?.id ? 0 : 9)
                        .gridCellColumns(2)
                }
                ForEach(section.rows) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.value).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .frame(maxWidth: 460, alignment: .leading)
        .padding(14)
        .panel(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
