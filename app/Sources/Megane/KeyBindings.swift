import AppKit
import Observation

/// Key bindings, edited in Settings and shown as menu shortcuts.
///
/// mpv stays the binding engine: every key press goes to mpv (`keypress`), so its default
/// bindings, `~/.config/mpv/input.conf` and multi-key sequences all work as in plain mpv. On
/// top of that come Megane's own defaults (``builtins``: commands the app handles, sent back as
/// `script-message megane-…`) and then the user's changes, kept in Megane's own input.conf
/// (``fileURL``) and applied with mpv's `keybind` command, which outranks the defaults.
@MainActor @Observable
final class KeyBindings {

    struct Binding: Identifiable, Hashable {
        var id: String { key }
        let key: String              // mpv key name, e.g. "Shift+RIGHT", "SPACE", "g-p"
        let command: String
        let comment: String
        let defaultCommand: String?  // nil: added by the user
        var isModified: Bool { command != defaultCommand }
    }

    /// Megane's replacements for mpv defaults that can't work through a libmpv video output
    /// (window size, the OSD bar) or that the app implements itself (subtitles are drawn by
    /// the app; upscaling is the app's).
    static let builtins: [(key: String, command: String, comment: String)] = [
        ("v", "script-message megane-subtitles toggle", "hide or show the subtitles"),
        ("Ctrl+1", "script-message megane-upscaling on", "turn upscaling on"),
        ("Ctrl+0", "script-message megane-upscaling off", "turn upscaling off"),
        ("Alt+0", "script-message megane-window-scale 0.5", "halve the window size"),
        ("Alt+1", "script-message megane-window-scale 1", "reset the window size"),
        ("Alt+2", "script-message megane-window-scale 2", "double the window size"),
        ("o", "script-message megane-show-progress", "show playback progress"),
        ("i", "script-message megane-info toggle", "show or hide playback information"),
        ("I", "script-message megane-info toggle", "show or hide playback information"),
        ("P", "script-message megane-show-progress", "show playback progress"),
    ]

    /// Mouse bindings the app keeps for itself (click, the context menu, dragging), hidden
    /// from the editor. Double-click, the side buttons and the scroll wheel do go to mpv.
    static let appMouse: Set<String> = ["MBTN_LEFT", "MBTN_RIGHT", "Ctrl+MBTN_LEFT"]

    static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Megane/input.conf")

    private(set) var bindings: [Binding] = []
    /// Called after any change (the menu bar refreshes its shortcuts).
    var onChange: (() -> Void)?

    @ObservationIgnored private let mpv: MPV
    @ObservationIgnored private var defaults: [String: (command: String, comment: String)] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var overrides: [(key: String, command: String)] = []

    init(mpv: MPV) {
        self.mpv = mpv
        // A key the user bound in their own mpv input.conf keeps that binding: the builtins
        // only replace mpv's defaults (weak bindings).
        let userKeys = Set((mpv.node("input-bindings") as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            .filter { $0["section"] as? String == "default" && $0["is_weak"] as? Bool != true }
            .compactMap { $0["key"] as? String })
        let builtins = Self.builtins.filter { !userKeys.contains($0.key) }
        for b in builtins { keybind(b.key, b.command) }
        // What's in effect now (mpv's defaults, the user's mpv input.conf, the builtins) is
        // the default each binding resets to.
        for (key, command, comment) in Self.effective(mpv) where defaults[key] == nil {
            defaults[key] = (command, comment)
            order.append(key)
        }
        for b in builtins { defaults[b.key] = (b.command, b.comment) }
        overrides = Self.read()
        for o in overrides { keybind(o.key, o.command) }
        rebuild()
    }

    // MARK: - editing

    func set(_ key: String, _ command: String) {
        overrides.removeAll { $0.key == key }
        if defaults[key]?.command != command { overrides.append((key, command)) }
        keybind(key, command)
        if !order.contains(key) { order.append(key) }
        commit()
    }

    /// Unbind `key` (it does nothing, even if mpv has a default for it).
    func remove(_ key: String) {
        if defaults[key] == nil {
            overrides.removeAll { $0.key == key }
            order.removeAll { $0 == key }
            keybind(key, "ignore")
            commit()
        } else {
            set(key, "ignore")
        }
    }

    func reset(_ key: String) {
        overrides.removeAll { $0.key == key }
        if let d = defaults[key] { keybind(key, d.command) } else { remove(key); return }
        commit()
    }

    func resetAll() {
        for o in overrides { keybind(o.key, defaults[o.key]?.command ?? "ignore") }
        overrides = []
        order.removeAll { defaults[$0] == nil }
        commit()
    }

    // MARK: - menu shortcuts

    /// The shortcut to show for a menu item running `command`, if a key is bound to it.
    func shortcut(for command: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        let target = Self.normalize(command)
        let candidates = bindings.filter { Self.normalize($0.command) == target }
            .compactMap { Self.menuKey(for: $0.key) }
        return candidates.first { $0.key == " " } ?? candidates.first
    }

    /// mpv's key syntax → an NSMenuItem key equivalent. Nil for mouse buttons, the keypad,
    /// multi-key sequences and other keys a menu can't show.
    static func menuKey(for name: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        if name.count > 1, name.contains("-"), !name.hasSuffix("-") { return nil }   // "g-p"
        var parts = name.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "Alt++" splits into ["Alt", "", ""]: the key itself is "+"
        if parts.count >= 3, parts.suffix(2) == ["", ""] { parts.removeLast(2); parts.append("+") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for m in parts {
            switch m.lowercased() {
            case "shift": modifiers.insert(.shift)
            case "ctrl": modifiers.insert(.control)
            case "alt": modifiers.insert(.option)
            case "meta": modifiers.insert(.command)
            default: return nil
            }
        }
        let special: [String: Int] = [
            "LEFT": NSLeftArrowFunctionKey, "RIGHT": NSRightArrowFunctionKey, "UP": NSUpArrowFunctionKey,
            "DOWN": NSDownArrowFunctionKey, "HOME": NSHomeFunctionKey, "END": NSEndFunctionKey,
            "PGUP": NSPageUpFunctionKey, "PGDWN": NSPageDownFunctionKey, "DEL": NSDeleteFunctionKey,
            "F1": NSF1FunctionKey, "F2": NSF2FunctionKey, "F3": NSF3FunctionKey, "F4": NSF4FunctionKey,
            "F5": NSF5FunctionKey, "F6": NSF6FunctionKey, "F7": NSF7FunctionKey, "F8": NSF8FunctionKey,
            "F9": NSF9FunctionKey, "F10": NSF10FunctionKey, "F11": NSF11FunctionKey, "F12": NSF12FunctionKey,
        ]
        let named = ["SPACE": " ", "ENTER": "\r", "ESC": "\u{1b}", "TAB": "\t", "BS": "\u{8}", "SHARP": "#"]
        if let code = special[last.uppercased()] {
            return (String(Character(UnicodeScalar(code)!)), modifiers)
        }
        if let c = named[last.uppercased()] { return (c, modifiers) }
        guard last.count == 1 else { return nil }   // KP_*, MBTN_*, WHEEL_*, media keys
        // An uppercase letter already implies Shift in a key equivalent.
        if let ch = last.first, ch.isLetter, ch.isUppercase { modifiers.remove(.shift) }
        return (last, modifiers)
    }

    /// mpv key name → what macOS menus would show, e.g. "Shift+RIGHT" → "⇧→".
    static func display(_ name: String) -> String {
        let mouse = ["MBTN_LEFT_DBL": "Double-Click", "MBTN_MID": "Middle Click", "MBTN_BACK": "Mouse Back",
                     "MBTN_FORWARD": "Mouse Forward", "WHEEL_UP": "Scroll Up", "WHEEL_DOWN": "Scroll Down",
                     "WHEEL_LEFT": "Scroll Left", "WHEEL_RIGHT": "Scroll Right"]
        if let base = name.split(separator: "+").last.map(String.init), let m = mouse[base] {
            let prefix = name.dropLast(base.count).replacingOccurrences(of: "Ctrl+", with: "⌃")
                .replacingOccurrences(of: "Alt+", with: "⌥").replacingOccurrences(of: "Shift+", with: "⇧")
                .replacingOccurrences(of: "Meta+", with: "⌘")
            return prefix + m
        }
        guard let (key, mods) = menuKey(for: name) else { return name }
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        let glyphs: [String: String] = [
            " ": "Space", "\r": "↩", "\u{1b}": "⎋", "\t": "⇥", "\u{8}": "⌫",
            String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): "←",
            String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): "→",
            String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): "↑",
            String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): "↓",
            String(Character(UnicodeScalar(NSHomeFunctionKey)!)): "↖",
            String(Character(UnicodeScalar(NSEndFunctionKey)!)): "↘",
            String(Character(UnicodeScalar(NSPageUpFunctionKey)!)): "⇞",
            String(Character(UnicodeScalar(NSPageDownFunctionKey)!)): "⇟",
            String(Character(UnicodeScalar(NSDeleteFunctionKey)!)): "⌦",
        ]
        if let g = glyphs[key] { return s + g }
        if key.unicodeScalars.first.map({ $0.value >= 0xF704 && $0.value <= 0xF70F }) == true {
            return s + name.split(separator: "+").last.map(String.init)!   // F1…F12
        }
        return s + (key.first?.isLetter == true && key.first?.isUppercase == true ? "⇧" + key : key.uppercased())
    }

    static func normalize(_ command: String) -> String {
        command.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    // MARK: - private

    private func keybind(_ key: String, _ command: String) {
        mpv.command(["keybind", key, command])
    }

    private func commit() {
        write()
        rebuild()
        onChange?()
    }

    private func rebuild() {
        let changed = Dictionary(overrides.map { ($0.key, $0.command) }, uniquingKeysWith: { _, b in b })
        bindings = order.compactMap { key in
            guard !Self.appMouse.contains(key) else { return nil }
            let d = defaults[key]
            guard let command = changed[key] ?? d?.command else { return nil }
            return Binding(key: key, command: command, comment: d?.comment ?? "", defaultCommand: d?.command)
        }
    }

    /// The binding in effect for each key of mpv's default section, in mpv's order.
    private static func effective(_ mpv: MPV) -> [(String, String, String)] {
        let all = (mpv.node("input-bindings") as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            .filter { $0["section"] as? String == "default" }
        var best: [String: [String: Any]] = [:]
        var keys: [String] = []
        func rank(_ b: [String: Any]) -> (Int, Int) {
            (b["is_weak"] as? Bool == true ? 0 : 1, b["priority"] as? Int ?? 0)
        }
        for b in all {
            guard let key = b["key"] as? String else { continue }
            if let current = best[key] {
                if rank(b) >= rank(current) { best[key] = b }
            } else {
                best[key] = b
                keys.append(key)
            }
        }
        return keys.map { ($0, best[$0]?["cmd"] as? String ?? "", best[$0]?["comment"] as? String ?? "") }
    }

    private static func read() -> [(key: String, command: String)] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#"),
                  let space = l.firstIndex(where: \.isWhitespace) else { return nil }
            return (String(l[..<space]), l[space...].trimmingCharacters(in: .whitespaces))
        }
    }

    private func write() {
        var text = "# Megane key bindings: changes from mpv's defaults, edited in Settings ▸ Key Bindings.\n"
        text += "# Same syntax as mpv's input.conf (KEY COMMAND); `ignore` unbinds a key.\n"
        for o in overrides { text += "\(o.key) \(o.command)\n" }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }
}
