import CMPV
import Foundation

/// A thin Swift wrapper over the libmpv client API.
///
/// mpv does everything except putting pixels on screen: demuxing (MKV and the rest),
/// hardware decoding, audio output and A/V sync, seeking, track selection, chapters, and
/// key bindings (including the user's mpv.conf / input.conf). Video comes out through the
/// render API (``VideoPipeline``); events and property changes are delivered on the main queue.
final class MPV: @unchecked Sendable {

    enum Error: Swift.Error, CustomStringConvertible {
        case create, initialize(String), option(String, String)
        var description: String {
            switch self {
            case .create: return "mpv_create failed"
            case .initialize(let e): return "mpv_initialize failed: \(e)"
            case .option(let name, let e): return "mpv option \(name): \(e)"
            }
        }
    }

    let handle: OpaquePointer
    /// Property changes (name, value) and file/shutdown events, on the main queue.
    var onProperty: ((String, Any?) -> Void)?
    var onEvent: ((mpv_event_id) -> Void)?
    /// `script-message` arguments: how key bindings and menus reach the app's own commands.
    var onMessage: (([String]) -> Void)?
    /// Info-level log lines (prefix, text), e.g. to notice a screenshot being written.
    var onLog: ((String, String) -> Void)?

    init(options: [(String, String)]) throws {
        guard let h = mpv_create() else { throw Error.create }
        handle = h
        for (name, value) in options {
            let rc = mpv_set_option_string(h, name, value)
            if rc < 0 { throw Error.option(name, String(cString: mpv_error_string(rc))) }
        }
        let rc = mpv_initialize(h)
        if rc < 0 { throw Error.initialize(String(cString: mpv_error_string(rc))) }
        mpv_request_log_messages(h, "info")

        mpv_set_wakeup_callback(h, { ctx in
            let mpv = Unmanaged<MPV>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { mpv.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func destroy() {
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_terminate_destroy(handle)
    }

    // MARK: commands and properties

    @discardableResult
    func command(_ args: [String]) -> Int32 {
        var cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        return cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                mpv_command(handle, $0)
            }
        }
    }

    func commandAsync(_ args: [String]) {
        var cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        _ = cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                mpv_command_async(handle, 0, $0)
            }
        }
    }

    /// A command in input.conf syntax, e.g. `seek 5` or `cycle-values loop-file "inf" "no"`.
    @discardableResult
    func command(string: String) -> Int32 { mpv_command_string(handle, string) }

    @discardableResult
    func set(_ name: String, _ value: String) -> Int32 { mpv_set_property_string(handle, name, value) }

    func string(_ name: String) -> String? {
        guard let s = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(s) }
        return String(cString: s)
    }

    func double(_ name: String) -> Double? {
        var v = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    func int(_ name: String) -> Int? {
        var v: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &v) >= 0 ? Int(v) : nil
    }

    func flag(_ name: String) -> Bool? {
        var v: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &v) >= 0 ? v != 0 : nil
    }

    /// The property as a Swift value tree (dictionaries, arrays, strings, numbers).
    func node(_ name: String) -> Any? {
        var n = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &n) >= 0 else { return nil }
        defer { mpv_free_node_contents(&n) }
        return Self.convert(n)
    }

    enum Kind { case double, flag, string, node }

    func observe(_ name: String, _ kind: Kind) {
        let format: mpv_format
        switch kind {
        case .double: format = MPV_FORMAT_DOUBLE
        case .flag: format = MPV_FORMAT_FLAG
        case .string: format = MPV_FORMAT_STRING
        case .node: format = MPV_FORMAT_NODE
        }
        mpv_observe_property(handle, 0, name, format)
    }

    // MARK: events

    private func drainEvents() {
        while true {
            guard let ev = mpv_wait_event(handle, 0)?.pointee, ev.event_id != MPV_EVENT_NONE else { return }
            switch ev.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                let p = ev.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                onProperty?(String(cString: p.name), Self.value(p))
            case MPV_EVENT_LOG_MESSAGE:
                let m = ev.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                let prefix = String(cString: m.prefix), text = String(cString: m.text)
                if m.log_level.rawValue <= MPV_LOG_LEVEL_WARN.rawValue {
                    FileHandle.standardError.write(Data("[mpv/\(prefix)] \(text)".utf8))
                }
                onLog?(prefix, text)
            case MPV_EVENT_CLIENT_MESSAGE:
                let m = ev.data.assumingMemoryBound(to: mpv_event_client_message.self).pointee
                onMessage?((0..<Int(m.num_args)).map { String(cString: m.args[$0]!) })
            default:
                onEvent?(ev.event_id)
            }
        }
    }

    private static func value(_ p: mpv_event_property) -> Any? {
        guard let data = p.data else { return nil }
        switch p.format {
        case MPV_FORMAT_DOUBLE: return data.assumingMemoryBound(to: Double.self).pointee
        case MPV_FORMAT_FLAG: return data.assumingMemoryBound(to: Int32.self).pointee != 0
        case MPV_FORMAT_STRING:
            return data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee.map { String(cString: $0) }
        case MPV_FORMAT_NODE: return convert(data.assumingMemoryBound(to: mpv_node.self).pointee)
        default: return nil
        }
    }

    private static func convert(_ n: mpv_node) -> Any? {
        switch n.format {
        case MPV_FORMAT_STRING: return String(cString: n.u.string)
        case MPV_FORMAT_FLAG: return n.u.flag != 0
        case MPV_FORMAT_INT64: return Int(n.u.int64)
        case MPV_FORMAT_DOUBLE: return n.u.double_
        case MPV_FORMAT_NODE_ARRAY:
            let list = n.u.list.pointee
            return (0..<Int(list.num)).map { convert(list.values[$0]) as Any }
        case MPV_FORMAT_NODE_MAP:
            let list = n.u.list.pointee
            var d: [String: Any] = [:]
            for i in 0..<Int(list.num) { d[String(cString: list.keys[i]!)] = convert(list.values[i]) }
            return d
        default: return nil
        }
    }
}
