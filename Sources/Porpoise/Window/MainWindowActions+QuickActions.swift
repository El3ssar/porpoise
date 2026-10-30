import AppKit
import PorpoiseCore
import PorpoiseServices

struct QuickActionInvocation {
    let action: FinderQuickAction
    let items: [FileItem]
}

extension MainWindowController {
    func quickActionMenu(for item: FileItem?, in container: ViewContainer) -> NSMenu? {
        guard (item?.url ?? container.url).isFileURL else { return nil }
        let menu = NSMenu(title: "Quick Actions")
        menu.autoenablesItems = false
        let loading = NSMenuItem(title: "Loading Quick Actions…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        menu.addItem(loading)
        let rows = container.model.rows, selection = container.model.selection, folder = container.url
        let service = quickActions
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak menu, weak container] in
            let items: [FileItem]
            if let item {
                items = selection.contains(item.url) ? rows.compactMap { selection.contains($0.item.url) ? $0.item : nil } : [item]
            } else {
                items = [FileItem(url: folder, name: folder.lastPathComponent, isDirectory: true)]
            }
            let actions = service.actions(for: items), reason = FinderQuickActions.unavailableReason(for: items)
            // Menu tracking uses a common run loop mode. Update the menu in that mode.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    guard let self, let menu, container != nil else { return }
                    menu.removeAllItems()
                    for action in actions {
                        let entry = NSMenuItem(title: action.name, action: #selector(self.runQuickAction(_:)), keyEquivalent: "")
                        entry.target = self
                        entry.image = self.quickActionIcon(action)
                        entry.representedObject = QuickActionInvocation(action: action, items: items)
                        entry.isEnabled = reason == nil
                        entry.toolTip = reason
                        menu.addItem(entry)
                    }
                    if actions.isEmpty {
                        let empty = NSMenuItem(title: "No Quick Actions", action: nil, keyEquivalent: "")
                        empty.isEnabled = false
                        menu.addItem(empty)
                    }
                    menu.addItem(.separator())
                    let customize = NSMenuItem(title: "Customize…", action: #selector(self.customizeQuickActions(_:)), keyEquivalent: "")
                    customize.target = self
                    menu.addItem(customize)
                }
            }
        }
        return menu
    }

    private func quickActionIcon(_ action: FinderQuickAction) -> NSImage? {
        let image =
            action.iconData.flatMap { NSImage(data: $0) } ?? NSImage(named: NSImage.Name(action.iconName)) ?? NSImage(named: "NSActionTemplate")
        guard let image, var icon = image.copy() as? NSImage else { return nil }
        if action.iconData == nil, action.iconName.hasPrefix("NSTouchBar"),
            let glyph = Self.quickActionGlyph(image)
        {
            icon = NSImage(cgImage: glyph, size: NSSize(width: glyph.width, height: glyph.height))
            icon.isTemplate = image.isTemplate
        }
        guard icon.size.width > 0, icon.size.height > 0 else { return nil }
        let scale = 16 / max(icon.size.width, icon.size.height)
        icon.size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
        if action.iconData != nil { icon.isTemplate = action.iconName.hasSuffix("Template") }
        return icon
    }

    private static func quickActionGlyph(_ image: NSImage) -> CGImage? {
        // Request a larger bitmap. Keep the glyph clear on Retina displays.
        var proposed = NSRect(x: 0, y: 0, width: image.size.width * 4, height: image.size.height * 4)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bounds: CGRect? = pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return nil }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where bytes[(y * width + x) * 4 + 3] != 0 {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        // Touch Bar images have blank padding. Keep the visible glyph at the menu icon size.
        return bounds.flatMap { source.cropping(to: $0) }
    }

    static let quickActionsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.finder-quick-actions")!

    static var openQuickActionsSettings: (URL) -> Bool = { NSWorkspace.shared.open($0) }

    @objc func customizeQuickActions(_ sender: Any?) {
        if !Self.openQuickActionsSettings(Self.quickActionsSettingsURL) { reportError("Could not open Quick Actions settings.") }
    }

    @objc func runQuickAction(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? QuickActionInvocation else { return }
        let container = view, service = quickActions
        container.statusBar.showMessage("Running “\(invocation.action.name)”…")
        Task { @MainActor [weak self, weak container] in
            do {
                try await service.run(invocation.action, on: invocation.items)
                container?.statusBar.showMessage("Finished “\(invocation.action.name)”.")
            } catch {
                self?.reportError("\(invocation.action.name): \(error.localizedDescription)", in: container)
            }
            FileOperationsController.notifyChanged(invocation.items.map(\.url))
        }
    }
}
