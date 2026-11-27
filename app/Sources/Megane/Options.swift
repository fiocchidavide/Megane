/// mpv options for the player.
///
/// The user's own mpv.conf / input.conf / scripts are loaded (so key bindings and preferences
/// carry over), then ``forced`` overrides what the ANE pipeline depends on.
enum PlayerOptions {

    /// Set before `mpv_initialize`.
    static let initial: [(String, String)] = [
        ("config", "yes"),
        ("input-default-bindings", "yes"),
        ("input-media-keys", "yes"),
        ("vo", "libmpv"),
        ("hwdec", "videotoolbox"),
        ("keep-open", "yes"),
        ("idle", "yes"),
        ("ytdl", "no"),
        ("audio-client-name", "Megane"),
        ("volume-max", "100"),            // mpv's 130 lets the wheel go past 100%; Settings can raise it
        ("screenshot-dir", "~/Desktop"),  // mpv's default is the working directory: "/" from Finder
        ("osc", "no"),                    // the native control bar replaces it
        ("load-osd-console", "no"),
    ]

    /// Set after `mpv_initialize`, i.e. after the user's config, so they always win.
    ///
    /// Frames are rendered 1:1 at the video's own size, so mpv's scalers never run; the
    /// rest keeps mpv from doing GPU work the ANE pipeline would only undo: no dithering
    /// (the frame is the model's input), no debanding or interpolation, and no shaders.
    /// mpv draws neither OSD nor text subtitles: those are drawn at display resolution after
    /// the upscale (``SubtitleRenderer``, ``PlayerWindowController``).
    static let forced: [(String, String)] = [
        ("vo", "libmpv"),
        ("glsl-shaders", ""),
        ("dither-depth", "no"),
        ("deband", "no"),
        ("interpolation", "no"),
        ("video-sync", "audio"),
        ("scale", "bilinear"),
        ("dscale", "bilinear"),
        ("cscale", "bilinear"),
        ("correct-downscaling", "no"),
        ("linear-downscaling", "no"),
        ("sigmoid-upscaling", "no"),
        ("hdr-compute-peak", "no"),
        // the video's own values: the layer is tagged with the video's colour space and macOS
        // converts for the display (``VideoPipeline/setColorSpace``), so mpv mustn't as well
        ("target-prim", "auto"),
        ("target-trc", "auto"),
        ("icc-profile", ""),
        ("icc-profile-auto", "no"),
        ("osd-level", "0"),
        ("osd-bar", "no"),
        ("sub-visibility", "no"),
    ]
}
