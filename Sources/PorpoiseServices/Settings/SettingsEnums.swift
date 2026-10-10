import Foundation

public enum StatusBarMode: String, CaseIterable { case small, fullWidth, disabled }
public enum TabStyle: String, CaseIterable { case autoSize, fixedSize, fullWidth }
public enum CloseSplitChoice: String, CaseIterable { case active, inactive, right }
public enum FolderSizeMode: String, CaseIterable { case itemCount, contentSize, none }
public enum DateStyle: String, CaseIterable { case relative, absolute }
public enum PermissionStyle: String, CaseIterable { case symbolic, numeric, combined }
public enum StartupLocation: String, CaseIterable { case lastSession, home }
public enum ExecutableAction: String, CaseIterable { case ask, open, run }
public enum BackgroundDoubleClick: String, CaseIterable {
    case nothing, selectAll, goUp, newFolder, toggleHidden, openTerminal
    public var title: String {
        switch self {
        case .nothing: return "Nothing"
        case .selectAll: return "Select All"
        case .goUp: return "Go Up"
        case .newFolder: return "Create New Folder"
        case .toggleHidden: return "Show/Hide Hidden Files"
        case .openTerminal: return "Open Terminal Here"
        }
    }
}

/// Context menu entries that can be switched on/off (Dolphin's Context Menu settings page).
public enum ContextMenuEntry: String, CaseIterable {
    case addToPlaces, copyLocation, duplicate, openInNewTab, openInNewWindow, openInSplit, openTerminal, otherView,
        sortBy, viewMode, deleteAlongsideTrash, copyMoveTo, compress, tags, share, quickLook, revealInFinder
    public var title: String {
        switch self {
        case .addToPlaces: return "Add to Places"
        case .copyLocation: return "Copy Location"
        case .duplicate: return "Duplicate Here"
        case .openInNewTab: return "Open in New Tab"
        case .openInNewWindow: return "Open in New Window"
        case .openInSplit: return "Open in Split View"
        case .openTerminal: return "Open Terminal Here"
        case .otherView: return "Copy/Move to Other View"
        case .sortBy: return "Sort By"
        case .viewMode: return "View Mode"
        case .deleteAlongsideTrash: return "Delete (next to Move to Trash)"
        case .copyMoveTo: return "“Copy To” and “Move To” commands"
        case .compress: return "Compress / Extract"
        case .tags: return "Tags"
        case .share: return "Share…"
        case .quickLook: return "Quick Look"
        case .revealInFinder: return "Reveal in Finder"
        }
    }
    /// Dolphin defaults: everything on except Delete-alongside and Copy To/Move To.
    /// Off unless switched on: Delete beside Move to Trash, Copy To/Move To, and Reveal in Finder (Porpoise is the
    /// file manager; Finder is one click away for whoever wants it).
    var defaultOn: Bool { ![.deleteAlongsideTrash, .copyMoveTo, .revealInFinder].contains(self) }
}
