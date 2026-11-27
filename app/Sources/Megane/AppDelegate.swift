import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let models: [Preferences.Quality: URL]
    private let modelOverride: URL?
    private var initialFiles: [URL]
    private let mpvOptions: [(String, String)]
    private let upscaling: Bool?
    private let preferences = Preferences()
    private let menuBar = MenuBar()
    private var player: PlayerWindowController?
    private var settings: SettingsWindowController?

    init(models: [Preferences.Quality: URL], modelOverride: URL?, initialFiles: [URL],
         mpvOptions: [(String, String)], upscaling: Bool?) {
        self.models = models
        self.modelOverride = modelOverride
        self.initialFiles = initialFiles
        self.mpvOptions = mpvOptions
        self.upscaling = upscaling
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = menuBar.menu
        menuBar.openSettings = { [weak self] tab in self?.showSettings(tab) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            player = try PlayerWindowController(models: models, modelOverride: modelOverride, preferences: preferences,
                                                mpvOptions: mpvOptions, upscaling: upscaling)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not start the player"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        menuBar.player = player
        player?.bindings.onChange = { [weak self] in self?.menuBar.refreshShortcuts() }
        player?.showWindow(nil)
        NSApp.activate()
        if initialFiles.isEmpty { menuBar.openDocument(nil) } else { player?.open(initialFiles) }
    }

    /// Finder: Open With, double-click, drops on the Dock icon (several files become a playlist).
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        // a file opened from Finder answers the Open panel shown at launch
        if NSApp.modalWindow is NSOpenPanel { NSApp.abortModal() }
        if let player { player.open(urls) } else { initialFiles = urls }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        player?.shutdown()
    }

    private func showSettings(_ tab: SettingsWindowController.Tab) {
        if settings == nil { settings = SettingsWindowController(preferences: preferences, bindings: player?.bindings) }
        settings?.show(tab)
    }
}
