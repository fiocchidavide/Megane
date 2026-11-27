import CFFmpeg
import CLibass
import Foundation

/// Text subtitles rendered by libass at display resolution, after the upscale.
///
/// mpv's video output is 1:1 at the source size and feeds the network, so mpv must not draw
/// subtitles into it. Instead, like mpv does internally, every text subtitle stream of a file
/// (ASS/SSA, SRT, WebVTT, ...) is decoded with FFmpeg into a libass track, together with the
/// fonts embedded in the file. mpv still owns track *selection* (`sid`, slang, j/J) and the
/// subtitle settings; ``PlayerWindowController`` mirrors them here.
///
/// Image subtitles (PGS, VobSub) can't go through libass; for those ``isImage(track:)`` is true
/// and mpv draws them itself.
///
/// Only the playing file's subtitles are kept: ``open(_:)`` frees the previous file's tracks and
/// fonts and stops its reader, which otherwise reads to the end of the file (over the network,
/// for a stream).
final class Subtitles: @unchecked Sendable {

    struct TrackKey: Hashable { let file: String; let index: Int }

    struct Settings {
        var track: TrackKey?
        var visible = true
        var delay = 0.0          // sub-delay, seconds
        var scale = 1.0          // sub-scale
        var position = 100.0     // sub-pos, 100 = bottom
        var storage = (w: 0, h: 0)   // the video's own size (for libass's scaling of borders etc.)
    }

    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private let lock = NSLock()
    private var tracks: [TrackKey: UnsafeMutablePointer<ASS_Track>] = [:]
    private var imageTracks: Set<TrackKey> = []
    private var loading: Set<String> = []       // files being read or read: the playing one + external subs
    private var fontsReady: Set<String> = []    // files whose embedded fonts are in
    private var settings = Settings()
    private var frame: (w: Int, h: Int, storageW: Int, storageH: Int) = (0, 0, 0, 0)

    init() {
        library = ass_library_init()
        renderer = ass_renderer_init(library)
        ass_set_message_cb(library, nil, nil)
    }

    deinit {
        for t in tracks.values { ass_free_track(t) }
        ass_renderer_done(renderer)
        ass_library_done(library)
    }

    var current: Settings {
        get { lock.withLock { settings } }
        set { lock.withLock { settings = newValue } }
    }

    func isImage(_ key: TrackKey) -> Bool { lock.withLock { imageTracks.contains(key) } }

    /// A new file is playing: drop everything of the previous one, then start reading `file`.
    func open(_ file: String) {
        lock.withLock {
            guard loading != [file] else { return }
            for (key, track) in tracks where key.file != file { ass_free_track(track); tracks[key] = nil }
            imageTracks = imageTracks.filter { $0.file == file }
            loading = []          // readers of other files see this and stop
            fontsReady = []
            ass_clear_fonts(library)
        }
        load(file)
    }

    /// Decode all text subtitle streams of `file` in the background (idempotent per file).
    /// Fonts come first (MKV attachments live in the header), so styled text renders as soon
    /// as the first events arrive; events stream in as the file is read.
    func load(_ file: String) {
        let started = lock.withLock { loading.insert(file).inserted }
        guard started else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.read(file) }
    }

    /// Render the visible subtitles for media time `t` into a list of images in display
    /// pixels, relative to the video rectangle. `changed` is false if identical to last call.
    func render(time t: Double, videoSize: (w: Int, h: Int),
                _ body: (UnsafeMutablePointer<ASS_Image>?, _ changed: Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard settings.visible, let key = settings.track, let track = tracks[key], fontsReady.contains(key.file),
              videoSize.w > 0, videoSize.h > 0 else { return body(nil, true) }
        let storage = settings.storage
        if frame != (videoSize.w, videoSize.h, storage.w, storage.h) {
            frame = (videoSize.w, videoSize.h, storage.w, storage.h)
            ass_set_frame_size(renderer, Int32(videoSize.w), Int32(videoSize.h))
            ass_set_storage_size(renderer, Int32(storage.w), Int32(storage.h))
        }
        ass_set_font_scale(renderer, settings.scale)
        ass_set_line_position(renderer, 100 - settings.position)
        var changed: Int32 = 0
        let ms = Int64(((t - settings.delay) * 1000).rounded())
        let images = ass_render_frame(renderer, track, ms, &changed)
        body(images, changed != 0)
    }

    // MARK: - decoding (background)

    private func wanted(_ file: String) -> Bool { lock.withLock { loading.contains(file) } }

    private func read(_ file: String) {
        // FFmpeg polls this while it blocks (opening, reading a stream): stop once unwanted
        let token = ReadToken { [weak self] in !(self?.wanted(file) ?? false) }
        var fmt = avformat_alloc_context()
        fmt?.pointee.interrupt_callback = AVIOInterruptCB(callback: { opaque in
            Unmanaged<ReadToken>.fromOpaque(opaque!).takeUnretainedValue().cancelled() ? 1 : 0
        }, opaque: Unmanaged.passUnretained(token).toOpaque())
        defer { withExtendedLifetime(token) {} }
        guard avformat_open_input(&fmt, file, nil, nil) >= 0, let fmt else { return }
        defer { var f: UnsafeMutablePointer<AVFormatContext>? = fmt; avformat_close_input(&f) }

        // 1. embedded fonts, then font lookup (memory fonts must be added before ass_set_fonts)
        var decoders: [Int: UnsafeMutablePointer<AVCodecContext>] = [:]
        for i in 0..<Int(fmt.pointee.nb_streams) {
            let st = fmt.pointee.streams[i]!
            let par = st.pointee.codecpar.pointee
            st.pointee.discard = AVDISCARD_ALL
            if par.codec_type == AVMEDIA_TYPE_ATTACHMENT, let data = par.extradata, par.extradata_size > 0,
               Self.isFont(st) {
                let name = av_dict_get(st.pointee.metadata, "filename", nil, 0).map { String(cString: $0.pointee.value) } ?? "font"
                lock.withLock {
                    guard loading.contains(file) else { return }
                    data.withMemoryRebound(to: CChar.self, capacity: Int(par.extradata_size)) {
                        ass_add_font(library, name, $0, par.extradata_size)
                    }
                }
            } else if par.codec_type == AVMEDIA_TYPE_SUBTITLE {
                let key = TrackKey(file: file, index: i)
                let desc = avcodec_descriptor_get(par.codec_id)
                if let desc, desc.pointee.props & AV_CODEC_PROP_TEXT_SUB == 0 {
                    _ = lock.withLock { imageTracks.insert(key) }
                    continue
                }
                guard let codec = avcodec_find_decoder(par.codec_id), let ctx = avcodec_alloc_context3(codec) else { continue }
                avcodec_parameters_to_context(ctx, st.pointee.codecpar)
                ctx.pointee.pkt_timebase = st.pointee.time_base
                guard avcodec_open2(ctx, codec, nil) >= 0 else { var c: UnsafeMutablePointer<AVCodecContext>? = ctx; avcodec_free_context(&c); continue }
                let added = lock.withLock {
                    guard loading.contains(file) else { return false }
                    let track = ass_new_track(library)!
                    if let header = ctx.pointee.subtitle_header, ctx.pointee.subtitle_header_size > 0 {
                        header.withMemoryRebound(to: CChar.self, capacity: Int(ctx.pointee.subtitle_header_size)) {
                            ass_process_codec_private(track, $0, ctx.pointee.subtitle_header_size)
                        }
                    }
                    tracks[key] = track
                    return true
                }
                guard added else { var c: UnsafeMutablePointer<AVCodecContext>? = ctx; avcodec_free_context(&c); continue }
                st.pointee.discard = AVDISCARD_DEFAULT
                decoders[i] = ctx
            }
        }
        lock.withLock {
            guard loading.contains(file) else { return }
            ass_set_fonts(renderer, nil, "sans-serif", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
            fontsReady.insert(file)
        }
        defer { for c in decoders.values { var p: UnsafeMutablePointer<AVCodecContext>? = c; avcodec_free_context(&p) } }
        guard !decoders.isEmpty else { return }

        // 2. every subtitle packet in the file → libass events
        guard let pkt = av_packet_alloc() else { return }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
        var sub = AVSubtitle()
        while av_read_frame(fmt, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            let i = Int(pkt.pointee.stream_index)
            let key = TrackKey(file: file, index: i)
            guard let ctx = decoders[i], lock.withLock({ tracks[key] != nil }) else { continue }
            var got: Int32 = 0
            guard avcodec_decode_subtitle2(ctx, &sub, &got, pkt) >= 0, got != 0 else { continue }
            defer { avsubtitle_free(&sub) }
            let tb = fmt.pointee.streams[i]!.pointee.time_base
            let unit = Double(tb.num) / Double(tb.den) * 1000
            let start = pkt.pointee.pts == Int64.min ? 0 : Int64(Double(pkt.pointee.pts) * unit)
            var duration = Int64(Double(pkt.pointee.duration) * unit)
            if duration <= 0 { duration = Int64(sub.end_display_time) - Int64(sub.start_display_time) }
            if duration <= 0 { duration = 5000 }
            lock.withLock {
                guard let track = tracks[key] else { return }   // freed by open() meanwhile
                for r in 0..<Int(sub.num_rects) {
                    guard let rect = sub.rects[r], rect.pointee.type == SUBTITLE_ASS, let ass = rect.pointee.ass else { continue }
                    ass_process_chunk(track, ass, Int32(strlen(ass)), start, duration)
                }
            }
        }
    }

    private static func isFont(_ st: UnsafeMutablePointer<AVStream>) -> Bool {
        let mime = av_dict_get(st.pointee.metadata, "mimetype", nil, 0).map { String(cString: $0.pointee.value).lowercased() } ?? ""
        let name = av_dict_get(st.pointee.metadata, "filename", nil, 0).map { String(cString: $0.pointee.value).lowercased() } ?? ""
        return mime.contains("font") || mime.contains("truetype") || mime.contains("opentype")
            || [".ttf", ".otf", ".ttc"].contains { name.hasSuffix($0) }
    }
}

/// The cancellation check handed to FFmpeg's interrupt callback (a C function: no captures).
private final class ReadToken {
    let cancelled: () -> Bool
    init(_ cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
}
