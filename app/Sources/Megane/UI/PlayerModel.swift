import CoreGraphics
import Foundation
import Observation

/// Playback state for the UI, mirrored from mpv, plus the actions the UI can take.
///
/// Platform-neutral (no AppKit/UIKit): the macOS window and a future iPad view controller
/// both drive the same SwiftUI overlay through this model.
@MainActor @Observable
final class PlayerModel {

    struct Track: Identifiable, Hashable {
        let id: Int
        let title: String
    }

    struct Chapter: Hashable {
        let time: Double
        let title: String
    }

    /// The playback info panel: titled sections of label/value rows.
    struct InfoSection: Identifiable {
        var id: String { title }
        let title: String
        let rows: [InfoRow]
    }

    struct InfoRow: Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }

    /// Waiting for a network stream: it is opening, or its cache ran dry.
    struct Buffering: Equatable {
        var percent: Int?   // how far the cache has filled towards resuming (mpv's cache-buffering-state)
        var speed: Int      // bytes per second coming in
    }

    struct OSD: Equatable {
        /// `symbol`s for Megane's glasses instead of an SF Symbol: upscaling on or off.
        static let upscalingOn = "megane.upscaling.on"
        static let upscalingOff = "megane.upscaling.off"
        static func upscaling(_ on: Bool) -> String { on ? upscalingOn : upscalingOff }
        /// Whether `symbol` is one of the glasses, and which.
        static func upscalingState(_ symbol: String) -> Bool? {
            symbol == upscalingOn ? true : symbol == upscalingOff ? false : nil
        }
        let symbol: String
        let text: String
        let id = UUID()
    }

    /// What the UI can ask the player to do; wired to mpv by the platform controller.
    struct Actions {
        var togglePause: () -> Void = {}
        var seek: (_ seconds: Double, _ final: Bool) -> Void = { _, _ in }
        var selectAudio: (Int) -> Void = { _ in }
        var selectSubtitle: (Int?) -> Void = { _ in }    // nil = off
        var toggleMute: () -> Void = {}
        var setVolume: (Double) -> Void = { _ in }
        var toggleFullscreen: () -> Void = {}
        var setUpscaling: (Bool) -> Void = { _ in }
        var open: ([URL]) -> Void = { _ in }   // several make a playlist
        /// Any mpv command in input.conf syntax.
        var run: (String) -> Void = { _ in }
    }

    var actions = Actions()

    // playback
    var title = ""
    var paused = true
    var time = 0.0
    var duration = 0.0
    var chapters: [Chapter] = []
    var volume = 100.0
    var muted = false
    var audioTracks: [Track] = []
    var subtitleTracks: [Track] = []
    var selectedAudio: Int?
    var selectedSubtitle: Int?
    var upscaling = true
    var upscaler = "Megane upscaling"   // its name in the current quality mode
    var fullscreen = false
    var speed = 1.0
    var playlistPosition = -1
    var playlistCount = 0
    var loaded = false
    var subtitlesVisible = true
    /// Shown while not nil (``PlayerWindowController`` refreshes it once a second).
    var info: [InfoSection]?
    /// Network streams: the stretches mpv has buffered (seconds), drawn on the seek bar.
    var cached: [ClosedRange<Double>] = []
    /// Shown while not nil.
    var buffering: Buffering?

    // UI
    var showRemaining = true
    var seekHover: CGFloat?     // pointer x over the seek bar (time preview)
    var seekPreviewWidth: CGFloat = 48   // that preview's measured width, to keep it inside the bar
    var seekDrag: Double?       // time being dragged to
    private(set) var controlsVisible = true
    var hoveringControls = false { didSet { if hoveringControls { showControls() } else { scheduleHide() } } }
    private(set) var osd: OSD?
    /// Called when the controls hide or show (macOS hides the cursor with them in fullscreen).
    var onControlsVisibility: ((Bool) -> Void)?

    private var hideTask: Task<Void, Never>?
    private var osdTask: Task<Void, Never>?

    /// Mouse moved, tapped, or a seek happened: show the controls, then hide them again after
    /// a moment of inactivity (never while paused or while the pointer is over them).
    func activity() {
        showControls()
        scheduleHide()
    }

    func pausedChanged(_ p: Bool) {
        paused = p
        if p { showControls() } else { scheduleHide() }
    }

    func show(_ symbol: String, _ text: String, seconds: Double = 1.5) {
        osd = OSD(symbol: symbol, text: text)
        osdTask?.cancel()
        osdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.osd = nil
        }
    }

    private func showControls() {
        hideTask?.cancel()
        guard !controlsVisible else { return }
        controlsVisible = true
        onControlsVisibility?(true)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, !self.paused, !self.hoveringControls, self.controlsVisible else { return }
            self.controlsVisible = false
            self.onControlsVisibility?(false)
        }
    }

    static func format(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
