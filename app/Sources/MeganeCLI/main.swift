import MeganeKit
import CoreML
import Foundation

// Minimal hand-rolled CLI (no external deps, so the package builds offline).
//
//   megane-cli info   --model <path>
//   megane-cli bench  --model <path> [--width W --height H] [--frames N] [--video FILE]
//   megane-cli play   --model <path> [--fullscreen] [--passthrough] [--start S] [--duration S] <video-file>
//   megane-cli still  --model <path> --image in.png --out out.png [--pad WxH]

/// Flags that never take a value (so `--fullscreen video.mp4` keeps the video positional).
let booleanFlags: Set<String> = ["fullscreen", "passthrough"]

func parseOptions(_ args: [String]) -> (flags: [String: String], positional: [String]) {
    var flags: [String: String] = [:]
    var positional: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            if !booleanFlags.contains(key) && i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                flags[key] = args[i + 1]
                i += 2
            } else {
                flags[key] = "true"
                i += 1
            }
        } else {
            positional.append(arg)
            i += 1
        }
    }
    return (flags, positional)
}

/// `--compute`, or nil when not given (each model type then picks its own default).
func computeUnits(from flags: [String: String]) -> MLComputeUnits? {
    switch flags["compute"]?.lowercased() {
    case nil: return nil
    case "cpu": return .cpuOnly
    case "gpu": return .cpuAndGPU
    case "ane", "neural": return .cpuAndNeuralEngine
    default: return .all
    }
}

extension MLComputeUnits {
    var name: String {
        switch self {
        case .cpuOnly: return "CPU"
        case .cpuAndGPU: return "GPU"
        case .cpuAndNeuralEngine: return "ANE"
        default: return "all"
        }
    }
}

func usage() -> Never {
    let text = """
    megane-cli — modernized, ANE-optimized Anime4K "Mode A" upscaler

    USAGE:
      megane-cli info  --model <path.mlpackage>
      megane-cli bench --model <path> [--frames 120] [--width 1920 --height 1080] [--video FILE] [--compute ane|gpu|cpu|all]
      megane-cli play  --model <path> [--fullscreen] [--passthrough] [--start S] [--duration S] <video-file>
      megane-cli still --model <student.mlpackage> --image in.png --out out.png [--pad WxH]

    Notes:
      • The model's input size is fixed at export time; bench --width/--height must match it
        (or omit them to use the model's own input size).
      • play opens a window and upscales frames live. A student model (distilled from Anime4K) runs on the
        Neural Engine for any exported source size; --duration quits after S seconds.
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { usage() }
let (flags, positional) = parseOptions(Array(argv.dropFirst()))

guard let modelPath = flags["model"] else {
    FileHandle.standardError.write(Data("error: --model <path> is required\n".utf8))
    usage()
}
let modelURL = URL(fileURLWithPath: modelPath)

do {
    switch command {
    case "info":
        try runInfo(modelURL: modelURL, computeUnits: computeUnits(from: flags) ?? .all)
    case "still":
        try runStill(modelURL: modelURL, flags: flags)
    case "bench":
        try runBench(modelURL: modelURL, flags: flags)
    case "play":
        guard let video = positional.first else {
            FileHandle.standardError.write(Data("error: play needs a <video-file>\n".utf8))
            usage()
        }
        try runPlay(modelURL: modelURL, videoURL: URL(fileURLWithPath: video),
                    computeUnits: computeUnits(from: flags), flags: flags)
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
