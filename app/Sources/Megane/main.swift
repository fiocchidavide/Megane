import AppKit
import Foundation

// megane [--model <model.mlpackage>] [--no-upscale] [--<mpv-option>=<value> ...] [file ...]
//
// Other `--name=value` (or `--flag`) arguments are mpv options, as on mpv's command line
// (e.g. --start=5:00 --sid=2 --volume=50). Several files make a playlist; a file can also be a
// URL mpv streams (http://…, e.g. from webtorrent). Without a file, an Open panel appears; files
// can also be dropped on the window or opened with File ▸ Open.

/// Installed (Megane.app): the bundle's copy. Run from the build folder: the repo's app/Models.
func bundledModel(_ name: String) -> URL {
    Bundle.main.url(forResource: name, withExtension: "mlpackage", subdirectory: "Models")
        ?? URL(fileURLWithPath: #filePath)                    // app/Sources/Megane/main.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Models/\(name).mlpackage")
}

let models: [Preferences.Quality: URL] = [.efficient: bundledModel("Student_M"), .exact: bundledModel("Anime4K_A")]

var args = Array(CommandLine.arguments.dropFirst())
var modelOverride: URL?
if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
    modelOverride = URL(fileURLWithPath: args[i + 1])
    args.removeSubrange(i...(i + 1))
}
let upscaling: Bool? = args.contains("--no-upscale") ? false : nil
args.removeAll { $0 == "--no-upscale" }
var mpvOptions: [(String, String)] = []
for arg in args where arg.hasPrefix("--") {
    let parts = arg.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    mpvOptions.append((parts[0], parts.count > 1 ? parts[1] : "yes"))
}
let files = args.filter { !$0.hasPrefix("--") }.map { arg in
    arg.contains("://") ? URL(string: arg) ?? URL(fileURLWithPath: arg) : URL(fileURLWithPath: arg)
}

// Arguments are handled above. Left on, AppKit also "opens" any argument it doesn't read as a
// `-key value` defaults pair, through application(_:openFiles:), as a path: a URL after an odd
// number of options became <cwd>/http:/… and replaced the stream.
UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(models: models, modelOverride: modelOverride, initialFiles: files,
                           mpvOptions: mpvOptions, upscaling: upscaling)
app.delegate = delegate
app.run()
