import AppKit
import SwiftUI

extension Preferences {
    /// An mpv option as a SwiftUI binding (strings as mpv prints them).
    func option(_ name: String) -> Binding<String> {
        Binding(get: { self.value(name) }, set: { self.set(name, $0) })
    }

    /// A yes/no mpv option.
    func flag(_ name: String) -> Binding<Bool> {
        Binding(get: { !["no", "", "0"].contains(self.value(name)) }, set: { self.set(name, $0 ? "yes" : "no") })
    }

    /// A numeric mpv option.
    func number(_ name: String) -> Binding<Double> {
        Binding(get: { Double(self.value(name)) ?? 0 }, set: { self.set(name, String(format: "%g", $0)) })
    }
}

/// A picker over fixed choices that also shows a value set elsewhere (mpv.conf), unchanged.
private struct OptionPicker: View {
    let title: String
    @Binding var value: String
    let choices: [(value: String, title: String)]

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
            if !choices.contains(where: { $0.value == value }) { Text(value.isEmpty ? "Default" : value).tag(value) }
        }
    }
}

struct GeneralSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Upscale when Megane opens", isOn: $preferences.upscaling)
                Picker("Quality", selection: $preferences.quality) {
                    ForEach(Preferences.Quality.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Upscaling")
            } footer: {
                Text(preferences.quality.detail).foregroundStyle(.secondary)
            }
            Section("Playback") {
                Toggle("Resume videos where you left off", isOn: preferences.flag("save-position-on-quit"))
                Toggle("Stay on the last frame at the end", isOn: preferences.flag("keep-open"))
                Toggle("Open videos in full screen", isOn: preferences.flag("fs"))
                Toggle("Show chapter names", isOn: $preferences.chapterNotifications)
                OptionPicker(title: "Decoding", value: preferences.option("hwdec"), choices: [
                    ("videotoolbox", "Hardware (VideoToolbox)"), ("auto", "Hardware when possible"), ("no", "Software"),
                ])
                OptionPicker(title: "Deinterlace", value: preferences.option("deinterlace"), choices: [
                    ("no", "Off"), ("auto", "Automatic"), ("yes", "Always"),
                ])
            }
            Section("Screenshots") {
                LabeledContent("Save to") {
                    HStack {
                        Text(displayPath(preferences.value("screenshot-dir")))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseScreenshotFolder)
                    }
                }
                OptionPicker(title: "Format", value: preferences.option("screenshot-format"), choices: [
                    ("png", "PNG"), ("jpg", "JPEG"), ("webp", "WebP"), ("jxl", "JPEG XL"),
                ])
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 540)
    }

    private func chooseScreenshotFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.set("screenshot-dir", url.path)
    }
}

struct AudioSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                TextField("Preferred languages", text: preferences.option("alang"), prompt: Text("jpn,ja"))
            } footer: {
                Text("Audio tracks in these languages are picked first. Language codes, separated by commas.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: preferences.number("volume"), in: 0...100)
                        Text(String(format: "%.0f%%", Double(preferences.value("volume")) ?? 100))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                OptionPicker(title: "Maximum volume", value: preferences.option("volume-max"), choices: [
                    ("100", "100%"), ("130", "130%"), ("150", "150%"), ("200", "200%"),
                ])
                OptionPicker(title: "Output device", value: preferences.option("audio-device"),
                             choices: preferences.audioDevices())
                Toggle("Keep the pitch when changing speed", isOn: preferences.flag("audio-pitch-correction"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 340)
    }
}

struct SubtitleSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Show subtitles", isOn: $preferences.subtitlesVisible)
                TextField("Preferred languages", text: preferences.option("slang"), prompt: Text("eng,en"))
            } footer: {
                Text("Subtitle tracks in these languages are picked first. Language codes, separated by commas.")
                    .foregroundStyle(.secondary)
            }
            Section {
                OptionPicker(title: "Load subtitle files", value: preferences.option("sub-auto"), choices: [
                    ("no", "Never"), ("exact", "With the same name as the video"),
                    ("fuzzy", "Containing the video's name"), ("all", "All in the video's folder"),
                ])
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: preferences.number("sub-scale"), in: 0.5...2, step: 0.05)
                        Text(String(format: "%.0f%%", (Double(preferences.value("sub-scale")) ?? 1) * 100))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Position") {
                    HStack {
                        Slider(value: preferences.number("sub-pos"), in: 50...100, step: 1)
                        Text(String(format: "%.0f%%", Double(preferences.value("sub-pos")) ?? 100))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 380)
    }
}

struct AdvancedSettings: View {
    @Bindable var preferences: Preferences
    @Bindable var state: SettingsState

    var body: some View {
        Form {
            Section {
                TextEditor(text: $preferences.extraOptions)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 140)
            } header: {
                Text("mpv Options")
            } footer: {
                Text("One option per line, as in mpv.conf (name=value). Applied when Megane opens, after "
                     + "~/.config/mpv/mpv.conf and the settings above; options the upscaler depends on "
                     + "(video output, shaders, scaling) are fixed.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("mpv configuration") {
                    Button("Show in Finder") { reveal(Self.mpvConfigFolder) }
                }
                LabeledContent("Key bindings and support files") {
                    Button("Show in Finder") { reveal(KeyBindings.fileURL.deletingLastPathComponent()) }
                }
                LabeledContent("Settings") {
                    Button("Reset…") { state.confirmResetOptions = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 440)
        .confirmationDialog("Reset the mpv options changed in Settings?", isPresented: $state.confirmResetOptions) {
            Button("Reset", role: .destructive) { preferences.resetOptions() }
        } message: {
            Text("mpv.conf and mpv's defaults apply again the next time Megane opens.")
        }
    }

    static let mpvConfigFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mpv")

    private func reveal(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

extension Preferences {
    /// mpv's audio outputs as (name, description) choices.
    func audioDevices() -> [(value: String, title: String)] {
        (mpvNode("audio-device-list") as? [Any] ?? []).compactMap { $0 as? [String: Any] }.compactMap { d in
            guard let name = d["name"] as? String else { return nil }
            return (name, d["description"] as? String ?? name)
        }
    }
}

private func displayPath(_ path: String) -> String {
    path.isEmpty ? "Current folder" : (path as NSString).abbreviatingWithTildeInPath
}
