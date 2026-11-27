import AppKit
import UniformTypeIdentifiers

/// The menu bar: mpv's functions as native menus.
///
/// Items run the same mpv commands as mpv's default key bindings, and show whatever key is
/// bound to that command now (``KeyBindings``), so the menus double as a live cheat sheet.
/// Keys themselves always go to mpv (except ⌘ shortcuts): see ``KeyEquivalentMenu``.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate, NSMenuItemValidation {

    let menu = KeyEquivalentMenu(title: "Main")
    var player: PlayerWindowController? { didSet { refreshShortcuts() } }
    var openSettings: ((SettingsWindowController.Tab) -> Void)?

    private var commandItems: [NSMenuItem] = []
    private var bindings: KeyBindings? { player?.bindings }

    override init() {
        super.init()
        for m in [appMenu(), fileMenu(), editMenu(), playbackMenu(), videoMenu(), audioMenu(),
                  subtitlesMenu(), windowMenu(), helpMenu()] {
            let item = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
            item.submenu = m
            menu.addItem(item)
        }
    }

    /// Show each command's current key binding next to it.
    func refreshShortcuts() {
        for item in commandItems {
            guard let command = item.representedObject as? String,
                  let shortcut = bindings?.shortcut(for: command) else {
                item.keyEquivalent = ""
                continue
            }
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
    }

    // MARK: - menus

    private func appMenu() -> NSMenu {
        let m = NSMenu(title: "Megane")
        m.addItem(withTitle: "About Megane", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(action("Settings…", #selector(showSettings(_:)), key: ","))
        m.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        m.addItem(services)
        m.addItem(.separator())
        m.addItem(withTitle: "Hide Megane", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = m.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        m.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Megane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return m
    }

    private func fileMenu() -> NSMenu {
        let m = NSMenu(title: "File")
        m.addItem(action("Open…", #selector(openDocument(_:)), key: "o"))
        m.addItem(action("Open URL…", #selector(openURL(_:)), key: "O"))
        m.addItem(dynamic("Open Recent", "recent"))
        m.addItem(.separator())
        m.addItem(action("Add Subtitle File…", #selector(addSubtitleFile(_:))))
        m.addItem(action("Add Audio File…", #selector(addAudioFile(_:))))
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        m.addItem(command("Quit and Remember Position", "quit-watch-later"))
        return m
    }

    private func editMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        m.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        m.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        m.addItem(.separator())
        m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        m.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return m
    }

    private func playbackMenu() -> NSMenu {
        let m = NSMenu(title: "Playback")
        m.addItem(command("Pause", "cycle pause"))
        m.addItem(command("Stop", "stop"))
        m.addItem(.separator())
        m.addItem(command("Forward 5 Seconds", "seek 5"))
        m.addItem(command("Back 5 Seconds", "seek -5"))
        m.addItem(command("Forward 1 Minute", "seek 60"))
        m.addItem(command("Back 1 Minute", "seek -60"))
        m.addItem(command("Forward 10 Minutes", "seek 600"))
        m.addItem(command("Back 10 Minutes", "seek -600"))
        m.addItem(command("Go to Beginning", "seek 0 absolute"))
        m.addItem(command("Undo Seek", "revert-seek"))
        m.addItem(.separator())
        m.addItem(command("Next Frame", "frame-step"))
        m.addItem(command("Previous Frame", "frame-back-step"))
        m.addItem(.separator())
        m.addItem(command("Next Chapter", "add chapter 1"))
        m.addItem(command("Previous Chapter", "add chapter -1"))
        m.addItem(dynamic("Chapters", "chapters"))
        m.addItem(.separator())
        m.addItem(command("Next File", "playlist-next"))
        m.addItem(command("Previous File", "playlist-prev"))
        m.addItem(dynamic("Playlist", "playlist"))
        m.addItem(command("Shuffle Playlist", "playlist-shuffle"))
        m.addItem(.separator())
        m.addItem(submenu("Speed", [
            command("Faster", "multiply speed 1.1"),
            command("Slower", "multiply speed 1/1.1"),
            command("Double Speed", "multiply speed 2.0"),
            command("Half Speed", "multiply speed 0.5"),
            command("Normal Speed", "set speed 1.0"),
            .separator(),
        ] + [0.5, 0.75, 1.25, 1.5, 2.0].map { command(String(format: "%g×", $0), "set speed \($0)") }))
        m.addItem(submenu("Loop", [
            command("A-B Loop", "ab-loop"),
            command("Loop File", "cycle-values loop-file \"inf\" \"no\""),
            command("Loop Playlist", "cycle-values loop-playlist \"inf\" \"no\""),
        ]))
        return m
    }

    private func videoMenu() -> NSMenu {
        let m = NSMenu(title: "Video")
        let fs = m.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        m.addItem(command("Float on Top", "cycle ontop"))
        m.addItem(.separator())
        m.addItem(command("Upscaling", "script-message megane-upscaling toggle"))
        m.addItem(submenu("Upscaling Quality", Preferences.Quality.allCases.map { q in
            let item = action(q.title, #selector(selectQuality(_:)))
            item.representedObject = q.rawValue
            item.toolTip = q.detail
            return item
        }))
        m.addItem(.separator())
        m.addItem(dynamic("Video Track", "video-tracks"))
        m.addItem(submenu("Aspect Ratio", [
            command("Default", "set video-aspect-override no"),
            command("16:9", "set video-aspect-override 16:9"),
            command("4:3", "set video-aspect-override 4:3"),
            command("2.35:1", "set video-aspect-override 2.35:1"),
            .separator(),
            command("Next Aspect Ratio", "cycle-values video-aspect-override \"16:9\" \"4:3\" \"2.35:1\" \"no\""),
        ]))
        m.addItem(submenu("Rotation", [0, 90, 180, 270].map { command("\($0)°", "set video-rotate \($0)") }))
        m.addItem(submenu("Zoom and Crop", [
            command("Zoom In", "add video-zoom 0.1"),
            command("Zoom Out", "add video-zoom -0.1"),
            command("Crop Black Bars", "add panscan +0.1"),
            command("Uncrop", "add panscan -0.1"),
            command("Reset Zoom and Pan", "set video-zoom 0; no-osd set panscan 0; no-osd set video-pan-x 0; no-osd set video-pan-y 0; no-osd set video-align-x 0; no-osd set video-align-y 0"),
        ]))
        m.addItem(command("Deinterlace", "cycle deinterlace"))
        m.addItem(command("Deband", "cycle deband"))
        m.addItem(command("Hardware Decoding", "cycle-values hwdec \"no\" \"auto\""))
        m.addItem(.separator())
        m.addItem(command("Take Screenshot", "screenshot"))
        m.addItem(command("Take Screenshot Without Subtitles", "screenshot video"))
        return m
    }

    private func audioMenu() -> NSMenu {
        let m = NSMenu(title: "Audio")
        m.addItem(dynamic("Audio Track", "audio-tracks"))
        m.addItem(command("Next Audio Track", "cycle audio"))
        m.addItem(.separator())
        m.addItem(command("Volume Up", "add volume 2"))
        m.addItem(command("Volume Down", "add volume -2"))
        m.addItem(command("Mute", "cycle mute"))
        m.addItem(.separator())
        m.addItem(command("Delay Audio by 100 ms", "add audio-delay 0.100"))
        m.addItem(command("Advance Audio by 100 ms", "add audio-delay -0.100"))
        m.addItem(command("Reset Audio Delay", "set audio-delay 0"))
        m.addItem(.separator())
        m.addItem(dynamic("Output Device", "audio-devices"))
        return m
    }

    private func subtitlesMenu() -> NSMenu {
        let m = NSMenu(title: "Subtitles")
        m.addItem(dynamic("Subtitle Track", "sub-tracks"))
        m.addItem(command("Next Subtitle Track", "cycle sub"))
        m.addItem(command("Previous Subtitle Track", "cycle sub down"))
        m.addItem(command("Show Subtitles", "script-message megane-subtitles toggle"))
        m.addItem(.separator())
        m.addItem(command("Delay Subtitles by 100 ms", "add sub-delay +0.1"))
        m.addItem(command("Advance Subtitles by 100 ms", "add sub-delay -0.1"))
        m.addItem(command("Reset Subtitle Delay", "set sub-delay 0"))
        m.addItem(command("Go to Previous Line", "no-osd sub-seek -1"))
        m.addItem(command("Go to Next Line", "no-osd sub-seek 1"))
        m.addItem(.separator())
        m.addItem(command("Larger Text", "add sub-scale +0.1"))
        m.addItem(command("Smaller Text", "add sub-scale -0.1"))
        m.addItem(command("Reset Text Size", "set sub-scale 1"))
        m.addItem(command("Move Up", "add sub-pos -1"))
        m.addItem(command("Move Down", "add sub-pos +1"))
        return m
    }

    private func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        m.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        m.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(command("Half Size", "script-message megane-window-scale 0.5"))
        m.addItem(command("Actual Size", "script-message megane-window-scale 1"))
        m.addItem(command("Double Size", "script-message megane-window-scale 2"))
        m.addItem(.separator())
        m.addItem(command("Playback Info", "script-message megane-info toggle"))
        m.addItem(.separator())
        m.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = m
        return m
    }

    private func helpMenu() -> NSMenu {
        let m = NSMenu(title: "Help")
        m.addItem(action("Keyboard Shortcuts", #selector(showKeyBindings(_:)), key: "/"))
        m.addItem(action("mpv Manual", #selector(openManual(_:))))
        NSApp.helpMenu = m
        return m
    }

    // MARK: - item builders

    private func command(_ title: String, _ command: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        commandItems.append(item)
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        items.forEach(sub.addItem)
        item.submenu = sub
        return item
    }

    /// A submenu filled when it opens (tracks, chapters, playlist, devices, recent files).
    private func dynamic(_ title: String, _ id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.identifier = NSUserInterfaceItemIdentifier(id)
        sub.delegate = self
        item.submenu = sub
        return item
    }

    // MARK: - NSMenuDelegate (dynamic submenus)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let id = menu.identifier?.rawValue else { return }
        if id == "recent" {
            for url in NSDocumentController.shared.recentDocumentURLs {
                let item = action(url.lastPathComponent, #selector(openRecent(_:)))
                item.representedObject = url
                item.image = NSWorkspace.shared.icon(forFile: url.path)
                item.image?.size = NSSize(width: 16, height: 16)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
            return
        }
        guard let mpv = player?.mpv else { return }
        func choice(_ title: String, _ property: String, _ value: String) -> NSMenuItem {
            let item = action(title, #selector(setProperty(_:)))
            item.representedObject = [property, value]
            return item
        }
        switch id {
        case "video-tracks", "audio-tracks", "sub-tracks":
            let (type, property) = id == "video-tracks" ? ("video", "vid") : id == "audio-tracks" ? ("audio", "aid") : ("sub", "sid")
            if type == "sub" { menu.addItem(choice("Off", property, "no")) }
            for t in player?.tracks(type) ?? [] { menu.addItem(choice(t.title, property, String(t.id))) }
        case "chapters":
            let chapters = (mpv.node("chapter-list") as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            for (i, c) in chapters.enumerated() {
                let time = PlayerModel.format(c["time"] as? Double ?? 0)
                menu.addItem(choice("\(c["title"] as? String ?? "Chapter \(i + 1)")\t\(time)", "chapter", String(i)))
            }
        case "playlist":
            let entries = (mpv.node("playlist") as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            for (i, e) in entries.enumerated() {
                let name = e["title"] as? String ?? (e["filename"] as? String).map { ($0 as NSString).lastPathComponent } ?? "?"
                menu.addItem(choice(name, "playlist-pos", String(i)))
            }
        case "audio-devices":
            let devices = (mpv.node("audio-device-list") as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            for d in devices {
                guard let name = d["name"] as? String else { continue }
                menu.addItem(choice(d["description"] as? String ?? name, "audio-device", name))
            }
        default:
            break
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "None", action: nil, keyEquivalent: "").isEnabled = false }
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let player else {
            return [#selector(openDocument(_:)), #selector(openURL(_:)), #selector(openRecent(_:)),
                    #selector(showSettings(_:)), #selector(openManual(_:))].contains(item.action)
        }
        switch item.action {
        case #selector(runCommand(_:)):
            let command = KeyBindings.normalize(item.representedObject as? String ?? "")
            item.state = player.isOn(command) ? .on : .off
            if command == "cycle pause" { item.title = player.model.paused ? "Play" : "Pause" }
            return player.isLoaded || command.hasPrefix("script-message megane-upscaling") || command.hasPrefix("script-message megane-info")
        case #selector(setProperty(_:)):
            guard let pv = item.representedObject as? [String] else { return false }
            item.state = player.mpv.string(pv[0]) == pv[1] ? .on : .off
            return true
        case #selector(selectQuality(_:)):
            item.state = player.preferences.quality.rawValue == item.representedObject as? String ? .on : .off
            return player.modelOverride == nil
        case #selector(addSubtitleFile(_:)), #selector(addAudioFile(_:)):
            return player.isLoaded
        default:
            return true
        }
    }

    // MARK: - actions

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        player?.run(command)
    }

    @objc private func setProperty(_ sender: NSMenuItem) {
        guard let pv = sender.representedObject as? [String] else { return }
        player?.mpv.set(pv[0], pv[1])
    }

    @objc private func selectQuality(_ sender: NSMenuItem) {
        guard let q = (sender.representedObject as? String).flatMap(Preferences.Quality.init) else { return }
        player?.preferences.quality = q
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, UTType(filenameExtension: "mkv") ?? .movie]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        player?.open(panel.urls)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        player?.open([url])
    }

    @objc private func openURL(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "A video file or stream URL (http, https, …)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://"
        if let s = NSPasteboard.general.string(forType: .string), URL(string: s)?.scheme != nil { field.stringValue = s }
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return }
        player?.open([url])
    }

    @objc private func addSubtitleFile(_ sender: Any?) { addFile(["srt", "ass", "ssa", "vtt", "sub", "sup", "idx"], command: "sub-add") }
    @objc private func addAudioFile(_ sender: Any?) { addFile(["mka", "aac", "ac3", "eac3", "flac", "m4a", "mp3", "opus", "dts", "wav"], command: "audio-add") }

    private func addFile(_ extensions: [String], command: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        if let path = player?.mpv.string("path") { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player?.mpv.command([command, url.path])
    }

    @objc private func showSettings(_ sender: Any?) { openSettings?(.general) }
    @objc private func showKeyBindings(_ sender: Any?) { openSettings?(.keys) }

    @objc private func openManual(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://mpv.io/manual/stable/")!)
    }
}

/// The main menu, matching key equivalents only for ⌘ shortcuts. Other keys belong to mpv
/// (the player window sends them as key presses), so a menu showing e.g. "Space" for Pause
/// never takes the key away from mpv's binding, or from a text field in Settings.
final class KeyEquivalentMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        return super.performKeyEquivalent(with: event)
    }
}
