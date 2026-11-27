import AppKit

/// Translates AppKit key events to mpv key names (as in input.conf), so mpv's own default
/// bindings and the user's input.conf apply unchanged via the `keypress` command.
enum MPVKeys {
    private static let special: [UInt16: String] = [
        49: "SPACE", 36: "ENTER", 76: "KP_ENTER", 53: "ESC", 48: "TAB", 51: "BS", 117: "DEL",
        123: "LEFT", 124: "RIGHT", 125: "DOWN", 126: "UP",
        115: "HOME", 119: "END", 116: "PGUP", 121: "PGDWN", 114: "INS",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    /// Characters that have their own names in mpv's key syntax.
    private static let named: [String: String] = ["#": "SHARP", " ": "SPACE"]

    static func name(for event: NSEvent) -> String? {
        let flags = event.modifierFlags
        var mods = ""
        if flags.contains(.control) { mods += "Ctrl+" }
        if flags.contains(.option) { mods += "Alt+" }
        if flags.contains(.command) { mods += "Meta+" }

        if let key = special[event.keyCode] {
            return (flags.contains(.shift) ? "Shift+" : "") + mods + key
        }
        // Printable keys: shift is already part of the character ("j" vs "J"). With other
        // modifiers, use the unmodified character (Alt+j, not Alt+∆).
        let chars = mods.isEmpty ? event.characters : event.charactersIgnoringModifiers
        guard let c = chars, !c.isEmpty, c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return nil
        }
        return mods + (named[c] ?? c)
    }
}
