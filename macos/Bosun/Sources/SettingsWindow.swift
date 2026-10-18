import AppKit
import SwiftUI

/// The Settings window's tabs, in toolbar order.
enum SettingsTab: String, CaseIterable {
    case general, appearance, fonts, notifications

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .fonts: "Fonts"
        case .notifications: "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .fonts: "textformat"
        case .notifications: "bell.badge"
        }
    }
}

/// Bosun → Settings: a preferences window with a tab per group in its toolbar, sized to each tab's content.
/// The last tab shown is the one it opens on.
@MainActor
final class SettingsWindowController: NSObject {
    let window: NSWindow
    private let tabs: SettingsTabs
    private static let lastTabKey = "settingsTab"

    init(themePair: ThemePairModel, editor: EditorModel) {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        func add(_ tab: SettingsTab, _ view: some View) {
            let vc = NSHostingController(rootView: view)
            vc.sizingOptions = [.preferredContentSize]
            vc.title = tab.title
            let item = NSTabViewItem(viewController: vc)
            item.label = tab.title
            item.identifier = tab.rawValue
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        add(.general, GeneralSettings(editor: editor))
        add(.appearance, AppearanceSettings(themePair: themePair))
        add(.fonts, FontSettings(ghosttyFamily: GhosttyRuntime.shared.configFontFamily, ghosttySize: GhosttyRuntime.shared.configFontSize))
        add(.notifications, NotificationSettings())
        self.tabs = tabs
        window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init()
        tabs.onSelect = { [weak self] in self?.remember() }
        let last = UserDefaults.standard.string(forKey: Self.lastTabKey).flatMap(SettingsTab.init) ?? .general
        show(last)
    }

    /// The tab on screen.
    var selected: SettingsTab {
        SettingsTab.allCases.indices.contains(tabs.selectedTabViewItemIndex) ? SettingsTab.allCases[tabs.selectedTabViewItemIndex] : .general
    }

    func show(_ tab: SettingsTab) {
        guard let i = SettingsTab.allCases.firstIndex(of: tab) else { return }
        tabs.selectedTabViewItemIndex = i
        window.title = tab.title
        if !testMode { UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey) }
    }

    /// Called by the tab controller's own switch (a toolbar click): remember it.
    func remember() {
        window.title = selected.title
        if !testMode { UserDefaults.standard.set(selected.rawValue, forKey: Self.lastTabKey) }
    }
}

/// The tab controller, telling the window controller when a toolbar click changes the tab.
private final class SettingsTabs: NSTabViewController {
    var onSelect: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?()
    }
}

/// A tab's content: a grouped form at the window's width, as tall as it needs.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

struct GeneralSettings: View {
    @ObservedObject var editor: EditorModel
    @AppStorage("focusFollowsMouse") private var focusFollowsMouse = true
    @AppStorage("poolSize") private var poolSize = AppSettings.defaultPoolSize

    var body: some View {
        SettingsPane {
            Section("Panes") {
                Toggle("Focus follows the mouse between panes", isOn: $focusFollowsMouse)
                Caption("With two or more panes, moving the pointer into a pane makes it active. Off: click to activate.")
                LabeledContent("Warm terminals kept attached") {
                    Stepper("\(poolSize)", value: $poolSize, in: AppSettings.poolSizeRange)
                }
                Caption("One per pane, including the ones on screen, so recently shown rows switch back in one frame. About 14 MB each.")
            }
            EditorSection(model: editor)
        }
    }
}

struct AppearanceSettings: View {
    @ObservedObject var themePair: ThemePairModel

    var body: some View {
        SettingsPane { ThemePairSection(model: themePair) }
    }
}

struct FontSettings: View {
    let ghosttyFamily: String?
    let ghosttySize: Double?

    var body: some View {
        SettingsPane { FontsSection(ghosttyFamily: ghosttyFamily, ghosttySize: ghosttySize) }
    }
}

struct NotificationSettings: View {
    @AppStorage(AppSettings.Key.notifyWhenWaiting) private var notifyWhenWaiting = true
    @AppStorage(AppSettings.Key.notifyWhenDone) private var notifyWhenDone = true
    @AppStorage(AppSettings.Key.showDockBadge) private var showDockBadge = true

    var body: some View {
        SettingsPane {
            Section("Notifications") {
                Toggle("Notify when an agent is waiting for you", isOn: $notifyWhenWaiting)
                Toggle("Notify when an agent finishes its turn", isOn: $notifyWhenDone)
                Caption("Only for sessions you can't see: Bosun isn't the active app, its window is minimized or on another Space, or the session isn't in the row on screen.")
            }
            Section("Dock") {
                Toggle("Show the number waiting on the Dock icon", isOn: $showDockBadge)
            }
        }
    }
}
