import AppKit
import SwiftUI

/// The key binding editor: every binding in effect (mpv's defaults, ~/.config/mpv/input.conf,
/// Megane's own) with what it does; changes are saved to Megane's input.conf and apply at once.
struct KeyBindingsSettings: View {
    let bindings: KeyBindings?
    @Bindable var state: SettingsState

    var body: some View {
        if let bindings {
            editor(bindings)
        } else {
            Text("Key bindings are available once the player has started.")
                .foregroundStyle(.secondary)
                .frame(width: 760, height: 520)
        }
    }

    private func editor(_ bindings: KeyBindings) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SearchField(text: $state.query, prompt: "Search keys, commands and descriptions")
                Toggle("Changed only", isOn: $state.changedOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            .padding(12)

            Table(rows(bindings), selection: $state.selection) {
                TableColumn("Key") { b in
                    Text(KeyBindings.display(b.key))
                        .fontWeight(b.isModified ? .semibold : .regular)
                        .help(b.key)
                }
                .width(min: 70, ideal: 96, max: 160)
                TableColumn("Command") { b in
                    Text(b.command.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(b.command == "ignore" ? .secondary : .primary)
                        .help(b.command)
                }
                .width(min: 160, ideal: 280)
                TableColumn("Description") { b in
                    Text(b.isModified && b.defaultCommand != nil ? "Changed — \(b.comment)" : b.comment)
                        .foregroundStyle(.secondary)
                        .help(b.defaultCommand.map { "Default: \($0)" } ?? "Added")
                }
            }
            .contextMenu(forSelectionType: String.self) { keys in
                if let key = keys.first, let b = binding(key, in: bindings) {
                    Button("Edit…") { edit(b) }
                    Button("Reset to Default") { bindings.reset(key) }.disabled(!b.isModified)
                    Button("Remove") { bindings.remove(key) }
                }
            } primaryAction: { keys in
                if let key = keys.first, let b = binding(key, in: bindings) { edit(b) }
            }

            Divider()
            HStack(spacing: 4) {
                Button { state.startEditing(original: nil, key: "", command: "") } label: {
                    Image(systemName: "plus").frame(width: 20, height: 16)
                }
                .help("Add a key binding")
                Button { if let s = state.selection { bindings.remove(s) } } label: {
                    Image(systemName: "minus").frame(width: 20, height: 16)
                }
                .disabled(state.selection == nil)
                .help("Unbind the selected key")
                Divider().frame(height: 14).padding(.horizontal, 6)
                Button("Edit…") { if let s = state.selection, let b = binding(s, in: bindings) { edit(b) } }
                    .disabled(state.selection == nil)
                    .padding(.trailing, 8)
                Button("Reset") { if let s = state.selection { bindings.reset(s) } }
                    .disabled(state.selection.flatMap { binding($0, in: bindings) }?.isModified != true)
                Spacer()
                Button("Reset All…") { state.confirmResetAll = true }
                    .disabled(!bindings.bindings.contains(where: \.isModified))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(width: 760, height: 520)
        .sheet(isPresented: $state.editorShown) {
            BindingEditor(state: state, bindings: bindings)
        }
        .confirmationDialog("Reset all key bindings to their defaults?", isPresented: $state.confirmResetAll) {
            Button("Reset All", role: .destructive) { bindings.resetAll() }
        }
    }

    private func rows(_ bindings: KeyBindings) -> [KeyBindings.Binding] {
        let q = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        return bindings.bindings.filter { b in
            (!state.changedOnly || b.isModified)
                && (q.isEmpty || [b.key, KeyBindings.display(b.key), b.command, b.comment]
                        .contains { $0.lowercased().contains(q) })
        }
    }

    private func binding(_ key: String, in bindings: KeyBindings) -> KeyBindings.Binding? {
        bindings.bindings.first { $0.key == key }
    }

    private func edit(_ b: KeyBindings.Binding) {
        state.startEditing(original: b.key, key: b.key, command: b.command)
    }
}

/// The sheet for adding or changing one binding: record a key, type the command.
private struct BindingEditor: View {
    @Bindable var state: SettingsState
    let bindings: KeyBindings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                LabeledContent("Key") {
                    KeyRecorder(key: $state.draftKey).frame(width: 200, height: 26)
                }
                TextField("Command", text: $state.draftCommand, prompt: Text("seek 10"))
                    .font(.system(size: 12, design: .monospaced))
                if let conflict {
                    Text("\(KeyBindings.display(state.draftKey)) runs “\(conflict)” now; it will run this command instead.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text("Any mpv input command, e.g. `seek 10`, `cycle mute` or `add volume 5`; several "
                     + "can be joined with `;`. [List of input commands](https://mpv.io/manual/stable/#list-of-input-commands)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { state.editorShown = false }
                    .keyboardShortcut(.cancelAction)
                Button(state.draftOriginal == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.draftKey.isEmpty || state.draftCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
    }

    private var conflict: String? {
        guard !state.draftKey.isEmpty, state.draftKey != state.draftOriginal,
              let b = bindings.bindings.first(where: { $0.key == state.draftKey }), b.command != "ignore" else { return nil }
        return b.command
    }

    private func save() {
        if let original = state.draftOriginal, original != state.draftKey { bindings.remove(original) }
        bindings.set(state.draftKey, state.draftCommand.trimmingCharacters(in: .whitespaces))
        state.selection = state.draftKey
        state.editorShown = false
    }
}

/// A field that records the next key pressed while it has focus, as an mpv key name.
private struct KeyRecorder: NSViewRepresentable {
    @Binding var key: String

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = { key = $0 }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.key = key
        view.onRecord = { key = $0 }
    }
}

final class RecorderView: NSView {
    var key = "" { didSet { if key != oldValue { needsDisplay = true } } }
    var onRecord: ((String) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func becomeFirstResponder() -> Bool { recording = true; return true }
    override func resignFirstResponder() -> Bool { recording = false; return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        guard recording, let name = MPVKeys.name(for: event) else { return super.keyDown(with: event) }
        key = name
        onRecord?(name)
        window?.makeFirstResponder(nil)
    }

    /// ⌘ shortcuts come here before the menu bar sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.stroke()
        let text = recording ? "Type a key…" : key.isEmpty ? "Click to record" : KeyBindings.display(key)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording || key.isEmpty ? .regular : .medium),
            .foregroundColor: recording || key.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

/// The system search field.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            text.wrappedValue = (note.object as? NSSearchField)?.stringValue ?? ""
        }
    }
}

/// The Settings window's view state. (Kept in an object rather than `@State`: SwiftUI's
/// `@State` is a macro whose plugin only ships with Xcode, and Megane builds with the Command
/// Line Tools.)
@MainActor @Observable
final class SettingsState {
    var query = ""
    var changedOnly = false
    var selection: String?
    var confirmResetAll = false
    var confirmResetOptions = false
    var editorShown = false
    var draftOriginal: String?      // the key being edited; nil for a new binding
    var draftKey = ""
    var draftCommand = ""

    func startEditing(original: String?, key: String, command: String) {
        draftOriginal = original
        draftKey = key
        draftCommand = command
        editorShown = true
    }
}
