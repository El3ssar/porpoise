import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Menu validation (enabled state, checkmarks and dynamic titles)

extension MainWindowController: NSMenuItemValidation {

    /// Commands that change files: from the keyboard they act only while the files have focus, never while typing
    /// (⌘⌫ deletes to the line's start in a field, ⌘D and ⌘E mean something else in the terminal).
    static let changesFiles: Set<Selector> = [
        #selector(moveToTrash(_:)), #selector(deleteItem(_:)), #selector(duplicateItem(_:)), #selector(makeAlias(_:)),
        #selector(newFolderWithSelection(_:)), #selector(ejectVolume(_:)),
    ]

    /// The key `event` belongs to the field being typed in rather than to `item`'s shortcut.
    static func typingKeeps(_ item: NSMenuItem, _ event: NSEvent) -> Bool {
        let key = item.keyEquivalent
        guard KeyEquivalent.matches(key, typed: event.charactersIgnoringModifiers) else { return false }
        if KeyEquivalent.movesInText(key) { return true }
        if let action = item.action, changesFiles.contains(action) { return true }
        return !item.keyEquivalentModifierMask.contains(.command) && !KeyEquivalent.isFunctionKey(key)
    }

    /// The key press being handled (the debug bridge substitutes the one it delivers).
    static var currentKeyEvent: () -> NSEvent? = { NSApp.currentEvent }

    /// `event` is Return and `item`'s shortcut is Return without ⌘, ⌃ or ⌥.
    static func isBareReturn(_ item: NSMenuItem, _ event: NSEvent) -> Bool {
        item.keyEquivalent == "\r" && item.keyEquivalentModifierMask.intersection([.command, .control, .option]).isEmpty
            && event.charactersIgnoringModifiers == "\r"
    }

    /// The menu bar's item for a key press, as its key equivalents stand now (the key set's, the user's bindings, the
    /// custom tools').
    static func menuItem(for event: NSEvent) -> NSMenuItem? {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let submenu = item.submenu {
                    if submenu !== NSApp.servicesMenu, let found = find(submenu) { return found }
                    continue
                }
                if item.action != nil, item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == mods,
                    KeyEquivalent.matches(item.keyEquivalent, typed: event.charactersIgnoringModifiers)
                {
                    return item
                }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    /// Runs the menu item bound to a key press without ⌘, ⌃ or fn (Return, ⌥↩ Get Info, ⌥1 Tab 1…), as the menu bar
    /// would: AppKit offers the menu bar only keys with ⌘, ⌃ or a function key (F2, ⌦, the arrows), and these would
    /// otherwise reach the focused view alone. The item runs
    /// on the first responder that takes its action, if that enables it (so keys stay with a field being typed in);
    /// commands that change files only while the files have focus. False when no item takes the key.
    func performMenuKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control]).isEmpty,
            let item = Self.menuItem(for: event), let action = item.action, let window
        else { return false }
        if Self.changesFiles.contains(action), !(window.firstResponder is ItemListView) { return false }
        var responder = window.firstResponder
        while let r = responder, !r.responds(to: action) { responder = r.nextResponder }
        guard let target = item.target ?? responder ?? (NSApp.responds(to: action) ? NSApp : nil) else { return false }
        let enabled =
            (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item)
            ?? item.isEnabled
        guard enabled else { return false }
        return Self.sendMenuAction(action, target, item)
    }

    /// How `performMenuKey` runs an item (tests record it instead).
    static var sendMenuAction: (Selector, Any, NSMenuItem) -> Bool = { NSApp.sendAction($0, to: $1, from: $2) }

    static let noSplitInColumns = "Column view shows one pane. Choose another view to split the window."

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard tabs.indices.contains(current) else { return false }
        if view.showsAirDrop, let action = item.action,
            [
                #selector(cut(_:)), #selector(copy(_:)), #selector(copyLocation(_:)), #selector(renameItem(_:)),
                #selector(moveToTrash(_:)), #selector(deleteItem(_:)), #selector(toggleSelectionMode(_:)),
                #selector(showSearch(_:)), #selector(showFilterBar(_:)), #selector(setViewMode(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
            ].contains(action)
        {
            return false
        }
        // Shortcuts without ⌘ (⌫, ⌥←, ⌥1…), and any on a key that moves the insertion point (⌘← Back, ⌘↑ Up), must not
        // steal keys while typing in a field or the terminal.
        // Only key presses are affected: the same items stay usable from an open menu.
        // Only for the key actually pressed: the command palette asks about every item while ⌘⇧P is the event.
        if let event = Self.currentKeyEvent(), event.type == .keyDown, isTypingFocus, Self.typingKeeps(item, event) { return false }
        // Return without ⌘ (Rename, with the Mac keys) belongs to the file list, and only with something selected. Elsewhere
        // it opens a place, presses a sheet's default button or ends an edit.
        if let event = Self.currentKeyEvent(), event.type == .keyDown, Self.isBareReturn(item, event),
            event.window !== window || !(window?.firstResponder is ItemListView) || !hasSelection
        {
            return false
        }
        if item.action == #selector(runCustomTool(_:)) {
            guard let raw = item.representedObject as? String, let id = UUID(uuidString: raw),
                let tool = Settings.shared.customTools.first(where: { $0.id == id })
            else { return false }
            item.toolTip = customToolAvailability.reason(for: tool, in: self) { [weak self, weak item] in
                guard let self, let item else { return }
                item.toolTip = self.customToolAvailability.preparedReason(for: tool.id)
                item.isEnabled = item.toolTip == nil
            }
            // A first key press must not disappear while the cache warms. Execution rechecks the entire captured
            // selection off-main before any prompt or process; menus keep their pending disabled state.
            if customToolAvailability.isPreparing, Self.currentKeyEvent()?.type == .keyDown {
                let count = view.model.selection.count
                return view.url.isFileURL
                    && (tool.selection == .folder || tool.selection == .one && count == 1 || tool.selection == .many && count > 0)
                    && (!tool.arguments.contains("{otherFolder}") || tab.inactive?.url.isFileURL == true)
            }
            return item.toolTip == nil
        }
        let p = view.model.props
        let ops = FileOperationsController.shared
        if let r = validateCloudItem(item) { return r }
        switch item.action {
        case #selector(toggleLinkedBrowsing(_:)):
            item.state = tab.linkedRoots == nil ? .off : .on; return true
        // File / Edit
        case #selector(compareFiles(_:)):
            return view.url.isFileURL && view.model.selectedItems.count <= 2
                && view.model.selectedItems.allSatisfy { !$0.isBrowsableFolder && $0.url.isFileURL }
        case #selector(undoFileOperation(_:)):
            if let text = typingUndoManager { item.title = text.undoMenuItemTitle; return text.canUndo }
            if isTypingFocus { item.title = "Undo"; return false }
            item.title = ops.undoTitle ?? "Undo"
            return ops.canUndo
        case #selector(redoFileOperation(_:)):
            if let text = typingUndoManager { item.title = text.redoMenuItemTitle; return text.canRedo }
            if isTypingFocus { item.title = "Redo"; return false }
            item.title = ops.redoTitle ?? "Redo"
            return ops.canRedo
        case #selector(paste(_:)):
            if item.representedObject as? String != Self.pasteIntoFolder { item.title = ops.pasteTitle }
            return writable && !ops.clipboardURLs.isEmpty
        case #selector(cut(_:)), #selector(renameItem(_:)):
            // With nothing selected these open selection mode (Dolphin), like Copy.
            return !hasSelection || selectionIsManageable
        case #selector(moveToTrash(_:)), #selector(deleteItem(_:)):
            // With nothing selected these open selection mode too (Dolphin).
            return !hasSelection || selectionIsManageable
        case #selector(removeAppAndLeftovers(_:)):
            return selectedURLs.contains(where: FileOperationsController.isApplication)
        case #selector(copy(_:)), #selector(copyLocation(_:)):
            return true
        case #selector(properties(_:)):
            // Google Drive items have their own Properties (owner, sharing, your access).
            return actionTargets.allSatisfy { $0.isFileURL || PlacesModel.isCloud($0) }
        case #selector(showChecksums(_:)), #selector(showDiskUsage(_:)), #selector(showDuplicates(_:)),
            #selector(revealInFinder(_:)):
            return actionTargets.allSatisfy(\.isFileURL)
        case #selector(duplicateItem(_:)):
            return !hasSelection ? writable : selectionIsLocal
        case #selector(shareItems(_:)), #selector(airDropItems(_:)):
            return SharingPreparation.supports(selectedURLs)
        case #selector(compress(_:)),
            #selector(setTag(_:)):
            return selectionIsLocal
        case #selector(cloudDownload(_:)), #selector(cloudEvict(_:)):
            return validateCloud(item)
        case #selector(extractHere(_:)):
            return view.model.selectedItems.first.map { $0.url.isFileURL && Self.extractableExtensions.contains($0.fileExtension.lowercased()) }
                ?? false
        case #selector(createFromTemplate(_:)):
            return writable && view.url.isFileURL
        case #selector(createFolder(_:)), #selector(createFile(_:)):
            return writable
        case #selector(addToPlaces(_:)):
            return view.model.selectedItems.contains(where: \.isBrowsableFolder) || view.url.isFileURL || PlacesModel.isCloud(view.url)
        case #selector(restoreFromTrash(_:)):
            return hasSelection && view.model.kind == .trash
        // The context menu's items carry their folder; from the menu bar and the palette they act on the selection.
        case #selector(ctxOpenInNewTab(_:)), #selector(ctxOpenInNewWindow(_:)), #selector(ctxOpenInSplit(_:)):
            return item.representedObject is URL || selectedFolder != nil
        case #selector(openTerminalHere(_:)):
            return !terminalFolders.isEmpty
        case #selector(openTerminal(_:)):
            return view.url.isFileURL
        case #selector(emptyTrash(_:)):
            return !TrashInfo.isEmpty

        // Split view
        case #selector(copyToOtherView(_:)), #selector(moveToOtherView(_:)):
            return tab.isSplit && !view.showsAirDrop && tab.inactive?.showsAirDrop != true
        case #selector(splitToTabs(_:)), #selector(popOutSplit(_:)), #selector(focusOtherView(_:)): return tab.isSplit
        case #selector(focusLeftPane(_:)): return tab.isSplit && tab.activeIsSecondary
        case #selector(focusRightPane(_:)): return tab.isSplit && !tab.activeIsSecondary
        case #selector(toggleSplit(_:)):
            item.title = tab.isSplit ? (tab.activeIsSecondary ? "Close Right View" : "Close Left View") : "Split"
            item.image = Icons.shared.menuIcon(
                tab.isSplit ? (tab.activeIsSecondary ? "view-right-close" : "view-left-close") : "view-split-left-right")
            item.toolTip = tab.isSplit || tab.canSplit ? nil : Self.noSplitInColumns
            return tab.isSplit || tab.canSplit
        case #selector(ctxOpenInSplit(_:)):
            item.toolTip = tab.isSplit || tab.canSplit ? nil : Self.noSplitInColumns
            return tab.isSplit || tab.canSplit

        // View state (checkmarks)
        case #selector(setViewMode(_:)): item.state = ViewMode.allCases[safe: item.tag] == p.mode ? .on : .off
        case #selector(togglePreviewColumn(_:)):
            item.state = Settings.shared.columnsShowPreview ? .on : .off
            return view.showsColumns
        case #selector(togglePreviews(_:)): item.state = p.previews ? .on : .off
        case #selector(toggleHiddenFiles(_:)): item.state = p.showHidden ? .on : .off
        case #selector(toggleFoldersFirst(_:)): item.state = p.foldersFirst ? .on : .off
        case #selector(toggleHiddenLast(_:)): item.state = p.hiddenLast ? .on : .off
        case #selector(sortBy(_:)): item.state = (item.representedObject as? String) == p.sortRole.rawValue ? .on : .off
        case #selector(setSortAscending(_:)):
            item.title = p.sortRole.orderLabels.ascending
            item.state = p.sortOrder == .ascending ? .on : .off
        case #selector(setSortDescending(_:)):
            item.title = p.sortRole.orderLabels.descending
            item.state = p.sortOrder == .descending ? .on : .off
        case #selector(groupBy(_:)):
            let raw = item.representedObject as? String
            if raw == "same" {
                item.state = p.groupSameAsSort ? .on : .off
            } else if raw == nil {
                item.state = (p.groupRole == nil && !p.groupSameAsSort) ? .on : .off
            } else {
                item.state = (!p.groupSameAsSort && p.groupRole?.rawValue == raw) ? .on : .off
            }
        case #selector(toggleAdditionalRole(_:)):
            item.state = p.roles(for: p.mode).contains { $0.rawValue == item.representedObject as? String } ? .on : .off
        case #selector(togglePanel(_:)):
            item.state = [showPlaces, showInformation, showFolders, showTerminal, showShelf][safe: item.tag] == true ? .on : .off
        case #selector(zoomIn(_:)): return view.zoomLevel < ZoomLevels.max
        case #selector(zoomOut(_:)): return view.zoomLevel > ZoomLevels.min

        // Go / Tabs
        case #selector(goBack(_:)): return view.history.canGoBack
        case #selector(goForward(_:)): return view.history.canGoForward
        case #selector(goUp(_:)): return view.canGoUp
        case #selector(undoCloseTab(_:)): return !closedTabs.isEmpty
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return tabs.count > 1

        default: if let r = validateFinderItem(item) { return r }
        }
        return true
    }
}
