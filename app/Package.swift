// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Megane",
    platforms: [.macOS(.v15)],  // MLModelConfiguration.functionName (multifunction models)
    products: [
        .library(name: "MeganeKit", targets: ["MeganeKit"]),
        .executable(name: "megane-cli", targets: ["MeganeCLI"]),
        .executable(name: "megane", targets: ["Megane"]),
    ],
    targets: [
        // Core pipeline: Core ML (ANE) upscaler + Metal compositor + AVFoundation reader.
        .target(name: "MeganeKit"),
        // Thin CLI: `bench`, `still`, and a minimal AVFoundation `play`.
        .executableTarget(
            name: "MeganeCLI",
            dependencies: ["MeganeKit"]
        ),

        // C libraries from Homebrew (`brew install mpv`, which pulls in libass and ffmpeg).
        .systemLibrary(name: "CMPV", pkgConfig: "mpv", providers: [.brew(["mpv"])]),
        .systemLibrary(name: "CLibass", pkgConfig: "libass", providers: [.brew(["libass"])]),
        .systemLibrary(name: "CFFmpeg", pkgConfig: "libavformat", providers: [.brew(["ffmpeg"])]),

        // The player: libmpv (decode, audio, sync, seeking, tracks, input) → ANE upscale →
        // Metal, with subtitles drawn by libass at display resolution after the upscale.
        .executableTarget(
            name: "Megane",
            dependencies: ["MeganeKit", "CMPV", "CLibass", "CFFmpeg"],
            cSettings: [.define("GL_SILENCE_DEPRECATION")],
            swiftSettings: [.unsafeFlags(["-Xcc", "-DGL_SILENCE_DEPRECATION"])],
            linkerSettings: [.linkedFramework("OpenGL")]
        ),
    ]
)
