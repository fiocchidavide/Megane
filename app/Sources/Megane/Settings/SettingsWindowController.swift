import AppKit
import SwiftUI

/// Settings: a toolbar-tabbed window (General, Audio, Subtitles, Key Bindings, Advanced) of
/// SwiftUI forms. Changes apply immediately.
@MainActor
final class SettingsWindowController: NSWindowController {

    enum Tab: String, CaseIterable {
        case general, audio, subtitles, keys, advanced

        var title: String {
            switch self {
            case .general: return "General"
            case .audio: return "Audio"
            case .subtitles: return "Subtitles"
            case .keys: return "Key Bindings"
            case .advanced: return "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .audio: return "speaker.wave.2"
            case .subtitles: return "captions.bubble"
            case .keys: return "keyboard"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    private let preferences: Preferences
    private let state = SettingsState()
    private let tabs = ResizingTabViewController()

    init(preferences: Preferences, bindings: KeyBindings?) {
        self.preferences = preferences
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for tab in Tab.allCases {
            let view: AnyView
            switch tab {
            case .general: view = AnyView(GeneralSettings(preferences: preferences))
            case .audio: view = AnyView(AudioSettings(preferences: preferences))
            case .subtitles: view = AnyView(SubtitleSettings(preferences: preferences))
            case .keys: view = AnyView(KeyBindingsSettings(bindings: bindings, state: state))
            case .advanced: view = AnyView(AdvancedSettings(preferences: preferences, state: state))
            }
            let controller = NSHostingController(rootView: view)
            controller.title = tab.title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: Tab) {
        preferences.refresh()
        tabs.selectedTabViewItemIndex = Tab.allCases.firstIndex(of: tab) ?? 0
        tabs.fitWindow()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Resizes the window to each tab's content, keeping its top edge in place, as System
/// Settings-style preference windows do.
final class ResizingTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow()
    }

    func fitWindow() {
        guard let window = view.window,
              let content = tabView.selectedTabViewItem?.viewController?.view else { return }
        let size = content.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height,
                               width: frame.width, height: frame.height), display: true, animate: window.isVisible)
    }
}
