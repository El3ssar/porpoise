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
        "desktop": DebugBridge.desktopCommand,
    ]

    /// desktop <file>: Desktop Mode as JSON: whether it is on, its folder, the names it lists, its surfaces and status,
    /// the selected names, and where each item's icon is on the main display (screen points, origin at the top left, as
    /// CGEvent uses).
    func desktopCommand(_ arg: String) {
        let controller = DesktopModeController.shared.windowController
        let height = NSScreen.screens.first?.frame.height ?? 0
        let grid = controller?.grids.first { $0.window?.screen == NSScreen.screens.first }
        let icons: [[Double]] = (grid?.model.rows.indices ?? 0..<0).compactMap { index in
            guard let grid, let window = grid.window else { return nil }
            let rect = window.convertToScreen(grid.convert(grid.iconRect(index), to: nil))
            return [rect.midX, height - rect.midY].map(Double.init)
        }
        let report: [String: Any] = [
            "icons": icons,
            "selected": controller?.model.map { model in model.rows.map(\.item).filter { model.selection.contains($0.url) }.map(\.name) } ?? [],
            "enabled": DesktopModeController.shared.isEnabled, "setting": Settings.shared.desktopModeEnabled,
            "location": controller?.model?.location.path ?? "", "loading": controller?.model?.isLoading ?? false,
            "rows": controller?.model?.rows.map(\.item.name) ?? [], "surfaces": controller?.desktopWindows.count ?? 0,
            "status": controller?.statusText ?? DesktopModeController.shared.statusLine.1,
            "menuBarIcon": controller?.statusItem != nil || DesktopModeController.shared.pausedStatusItem != nil,
            "conflicts": DesktopModeController.shared.environment.conflicts.map(\.rawValue),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: arg))
        }
    }

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
            let clip = scroll.contentView
            let requested = NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(requested).origin)
            scroll.reflectScrolledClipView(clip)
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
