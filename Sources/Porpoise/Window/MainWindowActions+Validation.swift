import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Menu validation (enabled state, checkmarks and dynamic titles)

extension MainWindowController: NSMenuItemValidation {

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard tabs.indices.contains(current) else { return false }
        // Shortcuts without ⌘ (⌫, ⌥←, ⌥1…) must not steal keys while typing in a field or the terminal.
        // Only key presses are affected: the same items stay usable from an open menu.
        if NSApp.currentEvent?.type == .keyDown, isTypingFocus, !item.keyEquivalent.isEmpty,
            !item.keyEquivalentModifierMask.contains(.command), !KeyEquivalent.isFunctionKey(item.keyEquivalent)
        {
            return false
        }
        let p = view.model.props
        let ops = FileOperationsController.shared
        switch item.action {
        // File / Edit
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
        case #selector(copy(_:)), #selector(copyLocation(_:)):
            return true
        case #selector(properties(_:)), #selector(revealInFinder(_:)):
            return actionTargets.allSatisfy(\.isFileURL)
        case #selector(duplicateItem(_:)):
            return !hasSelection ? writable : selectionIsLocal
        case #selector(shareItems(_:)), #selector(compress(_:)),
            #selector(setTag(_:)), #selector(cloudDownload(_:)), #selector(cloudEvict(_:)):
            return selectionIsLocal
        case #selector(extractHere(_:)):
            return view.model.selectedItems.first.map { $0.url.isFileURL && Self.extractableExtensions.contains($0.fileExtension.lowercased()) }
                ?? false
        case #selector(createFolder(_:)), #selector(createFile(_:)):
            return writable
        case #selector(addToPlaces(_:)):
            return view.model.selectedItems.contains(where: \.isBrowsableFolder) || view.url.isFileURL
        case #selector(restoreFromTrash(_:)):
            return hasSelection
        case #selector(openTerminalHere(_:)):
            return !terminalFolders.isEmpty
        case #selector(openTerminal(_:)):
            return view.url.isFileURL
        case #selector(emptyTrash(_:)):
            return !TrashInfo.isEmpty

        // Split view
        case #selector(copyToOtherView(_:)), #selector(moveToOtherView(_:)): return tab.isSplit
        case #selector(splitToTabs(_:)), #selector(popOutSplit(_:)), #selector(focusOtherView(_:)): return tab.isSplit
        case #selector(focusLeftPane(_:)): return tab.isSplit && tab.activeIsSecondary
        case #selector(focusRightPane(_:)): return tab.isSplit && !tab.activeIsSecondary
        case #selector(toggleSplit(_:)):
            item.title = tab.isSplit ? (tab.activeIsSecondary ? "Close Right View" : "Close Left View") : "Split"
            item.image = Icons.shared.menuIcon(
                tab.isSplit ? (tab.activeIsSecondary ? "view-right-close" : "view-left-close") : "view-split-left-right")
            return true

        // View state (checkmarks)
        case #selector(setViewMode(_:)): item.state = ViewMode.allCases[safe: item.tag] == p.mode ? .on : .off
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
            item.state = [showPlaces, showInformation, showFolders, showTerminal][safe: item.tag] == true ? .on : .off
        case #selector(zoomIn(_:)): return p.zoomLevel(for: p.mode) < ZoomLevels.max
        case #selector(zoomOut(_:)): return p.zoomLevel(for: p.mode) > ZoomLevels.min

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
