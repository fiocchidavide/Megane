import Foundation
import Observation

/// Settings, kept in UserDefaults.
///
/// Most are mpv options: shown with mpv's current value (so `~/.config/mpv/mpv.conf` shows
/// through), and once changed in Settings saved and applied at every launch, after mpv.conf.
/// The rest are the app's own (upscaling, subtitles, chapter notifications).
@MainActor @Observable
final class Preferences {

    enum Quality: String, CaseIterable, Identifiable {
        case efficient, exact
        var id: String { rawValue }
        var title: String { self == .efficient ? "Efficient" : "Exact Anime4K" }
        /// What the upscaler is called in messages: Megane's own model, or Anime4K itself.
        var upscaler: String { self == .efficient ? "Megane upscaling" : "Exact Anime4K upscaling" }
        var detail: String {
            self == .efficient
                ? "A small model distilled from Anime4K Mode A. Visually the same, about 1.1 W."
                : "Anime4K Mode A computed exactly on the Neural Engine. About 4.5 W."
        }
    }

    /// The mpv options Settings shows.
    static let managed = [
        "keep-open", "save-position-on-quit", "fs", "hwdec", "deinterlace",
        "screenshot-dir", "screenshot-format",
        "alang", "volume", "volume-max", "audio-device", "audio-pitch-correction",
        "slang", "sub-auto", "sub-scale", "sub-pos",
    ]

    var upscaling: Bool { didSet { defaults.set(upscaling, forKey: "upscaling") } }
    var quality: Quality {
        didSet { defaults.set(quality.rawValue, forKey: "quality"); onQualityChange?(quality) }
    }
    /// Shown or hidden, by `v` or in Settings; remembered for the next launch.
    var subtitlesVisible: Bool {
        didSet { defaults.set(subtitlesVisible, forKey: "subtitlesVisible"); onSubtitlesVisibleChange?(subtitlesVisible) }
    }
    /// Whether the OSD names each chapter as playback enters it.
    var chapterNotifications: Bool { didSet { defaults.set(chapterNotifications, forKey: "chapterNotifications") } }
    /// Extra mpv options, one `name=value` per line; applied at launch.
    var extraOptions: String { didSet { defaults.set(extraOptions, forKey: "extraOptions") } }
    /// Current values of ``managed`` options (strings, as mpv prints them).
    private(set) var values: [String: String] = [:]

    @ObservationIgnored var onQualityChange: ((Quality) -> Void)?
    @ObservationIgnored var onSubtitlesVisibleChange: ((Bool) -> Void)?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var saved: [String: String]
    @ObservationIgnored private weak var mpv: MPV?

    init() {
        defaults.register(defaults: ["upscaling": true, "subtitlesVisible": true, "chapterNotifications": false])
        upscaling = defaults.bool(forKey: "upscaling")
        quality = Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .efficient
        subtitlesVisible = defaults.bool(forKey: "subtitlesVisible")
        chapterNotifications = defaults.bool(forKey: "chapterNotifications")
        extraOptions = defaults.string(forKey: "extraOptions") ?? ""
        saved = defaults.dictionary(forKey: "mpvOptions") as? [String: String] ?? [:]
    }

    /// Apply the saved options (call after mpv has read mpv.conf).
    func apply(to mpv: MPV) {
        self.mpv = mpv
        for (name, value) in saved { mpv.set(name, value) }
        for line in extraOptions.split(separator: "\n") {
            var l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { continue }
            if l.hasPrefix("--") { l.removeFirst(2) }
            let parts = l.split(separator: "=", maxSplits: 1).map(String.init)
            mpv.set(parts[0], parts.count > 1 ? parts[1] : "yes")
        }
        refresh()
    }

    /// Re-read the shown options from mpv (they can change while playing, e.g. the volume).
    func refresh() {
        guard let mpv else { return }
        for name in Self.managed {
            let v = mpv.string(name) ?? ""
            values[name] = Double(v).map { String(format: "%g", $0) } ?? v   // "130.000000" → "130"
        }
    }

    func value(_ name: String) -> String { values[name] ?? "" }

    /// An mpv property as a value tree (e.g. lists for pickers).
    func mpvNode(_ name: String) -> Any? { mpv?.node(name) }

    func set(_ name: String, _ value: String) {
        values[name] = value
        saved[name] = value
        defaults.set(saved, forKey: "mpvOptions")
        mpv?.set(name, value)
    }

    /// Forget every option changed in Settings (mpv.conf and mpv's defaults apply again at
    /// the next launch).
    func resetOptions() {
        saved = [:]
        defaults.removeObject(forKey: "mpvOptions")
    }
}
