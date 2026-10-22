// Compiled only into test and local builds (PORPOISE_TEST_HOOKS): a release has no debug bridge.
#if PORPOISE_TEST_HOOKS

import AppKit
import PorpoiseCore
import PorpoiseServices

extension DebugBridge {
    /// Settings: values, pages, appearance and toolbar.
    static let settingsCommands: [String: Command] = [
        "shortcutsimport": DebugBridge.shortcutsimportCommand,
        "toolbarlayout": DebugBridge.toolbarlayoutCommand,
        "appmgmt": DebugBridge.appmgmtCommand,
        "set": DebugBridge.setCommand,
        "appearanceexport": DebugBridge.appearanceexportCommand,
        "appearanceimport": DebugBridge.appearanceimportCommand,
        "settingssize": DebugBridge.settingssizeCommand,
        "settingsscroll": DebugBridge.settingsscrollCommand,
        "settings": DebugBridge.settingsCommand,
        "contrast": DebugBridge.contrastCommand,
    ]

    /// contrast on|off|system: Increase Contrast as the theme sees it, without changing the Mac's setting.
    func contrastCommand(_ arg: String) {
        switch arg {
        case "on": Theme.systemIncreasesContrast = { true }
        case "off": Theme.systemIncreasesContrast = { false }
        default: Theme.systemIncreasesContrast = { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
        }
        Theme.lookChanged()
    }

    func shortcutsimportCommand(_ arg: String) {
        let paths = arg.components(separatedBy: "|")
        guard paths.count == 2 else { return }
        let report: String
        do {
            MenuCommandRegistry.shared.refresh();
            try Settings.shared.importKeyboardShortcuts(
                Data(contentsOf: URL(fileURLWithPath: paths[0])), actions: MenuCommandRegistry.shared.commands.map(\.definition));
            report = "ok"
        } catch { report = error.localizedDescription }
        try? report.write(toFile: paths[1], atomically: true, encoding: .utf8)
    }

    func toolbarlayoutCommand(_ arg: String) {
        let commands = arg.split(separator: ",").compactMap { ToolbarCommand(rawValue: String($0)) }
        if let editor = NSApp.windows.first(where: { $0.windowController is ToolbarCustomizationWindow })?.toolbar {
            editor.itemIdentifiers = commands.map(\.toolbarIdentifier)
        } else {
            Settings.shared.toolbarCommands = commands
        }
    }

    func appmgmtCommand(_ arg: String) {
        SystemIntegration.requestAppManagement {
            try? "\(PrivacyAccess.appManagementState)".write(toFile: arg, atomically: true, encoding: .utf8)
        }
    }

    /// set <key> <json value>
    func setCommand(_ arg: String) {
        let kv = arg.split(separator: " ", maxSplits: 1).map(String.init)
        if kv.count == 2, let v = try? JSONSerialization.jsonObject(with: Data(kv[1].utf8), options: .fragmentsAllowed) {
            Settings.store.set(v, forKey: kv[0])
            NotificationCenter.default.post(name: Settings.changed, object: kv[0])
        }
    }

    func appearanceexportCommand(_ arg: String) {
        try? Settings.shared.exportAppearance().write(to: URL(fileURLWithPath: arg))
    }

    func appearanceimportCommand(_ arg: String) {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: arg)) { try? Settings.shared.importAppearance(data) }
    }

    func settingssizeCommand(_ arg: String) {
        let dimensions = arg.split(separator: " ").compactMap { Double($0) }
        if dimensions.count == 2 { settingsWindow?.setContentSize(NSSize(width: dimensions[0], height: dimensions[1])) }
    }

    func settingsscrollCommand(_ arg: String) {
        if let y = Double(arg), let tabs = settingsWindow?.contentViewController as? NSTabViewController,
            let scroll = tabs.tabViewItems[safe: tabs.selectedTabViewItemIndex]?.viewController?.view as? NSScrollView
        {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// settings [index | page title]: opens Settings (on the page shown last), or on that page.
    func settingsCommand(_ arg: String) {
        AppDelegate.shared.showSettings(nil)
        guard let tabs = settingsWindow?.contentViewController as? NSTabViewController else { return }
        if let i = Int(arg) {
            tabs.selectedTabViewItemIndex = i
        } else if let i = tabs.tabViewItems.firstIndex(where: { $0.label == arg }) {
            tabs.selectedTabViewItemIndex = i
        }
    }
}

#endif
