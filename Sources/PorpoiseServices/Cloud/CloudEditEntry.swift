import Foundation
import PorpoiseCore

/// How an item being edited in another app shows on its row and in Activity.
public enum CloudEditMark: Equatable, Sendable {
    /// Open in another app: its saves go to its cloud account.
    case editing
    case saving
    /// Just saved (shown for a moment, then back to editing).
    case saved
    /// Saved here, not in the cloud yet (offline, signed out, refused): kept, and sent again by itself.
    case unsent(String)
    /// Changed in the cloud while it was edited here: both versions are kept until the user chooses.
    case conflict

    /// The badge on the item's icon.
    public var symbol: String {
        switch self {
        case .editing: return "pencil.circle.fill"
        case .saving: return "arrow.up.circle.fill"
        case .saved: return "checkmark.circle.fill"
        case .unsent: return "icloud.slash.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        }
    }

    /// After the name, and in the status bar.
    public func note(_ service: String) -> String {
        switch self {
        case .editing: return "Editing · changes save to \(service)"
        case .saving: return "Saving to \(service)…"
        case .saved: return "Saved to \(service)"
        case .unsent: return "Not in \(service) yet · kept on this Mac"
        case .conflict: return "Changed in \(service) meanwhile · review in Activity"
        }
    }

    /// Worth the user's attention (drawn in the warning color).
    public var needsAttention: Bool {
        switch self {
        case .conflict, .unsent: return true
        default: return false
        }
    }
}

/// One cloud file being edited in another app, as Activity lists it.
public struct CloudEditEntry: Equatable, Sendable {
    public let id: UUID
    public let account: UUID
    /// The cloud file the copy's saves go to (after Keep Both, the new one next to the original).
    public var fileID: String
    public var name: String
    /// The copy the other app edits.
    public var localURL: URL
    /// The cloud version, downloaded when it changed meanwhile.
    public var conflictURL: URL?
    public var mark: CloudEditMark
    public var lastSaved: Date?
    /// Where the file is in its cloud account (the folder it was opened from).
    public var location: URL
    public var provider: CloudProvider = .googleDrive
    /// The cloud revision the copy started from or last sent; a newer one in the folder means the copy is out of date.
    public var revision: String?

    /// "Editing “Report.pdf”" and the like.
    public var title: String {
        switch mark {
        case .conflict: return "“\(name)” changed in \(provider.title) while you edited it"
        case .unsent: return "1 unsent edit to “\(name)”"
        default: return "Editing “\(name)”"
        }
    }

    /// The line under the title.
    public var detail: String {
        switch mark {
        case .editing:
            return lastSaved.map { "Changes save to \(provider.title) · last saved \($0.formatted(date: .omitted, time: .shortened))" }
                ?? "Changes you save in the other app go to \(provider.title)"
        case .saving: return "Saving to \(provider.title)…"
        case .saved: return "Saved to \(provider.title)"
        case .unsent(let why): return "\(why) Your changes are kept on this Mac and sent when they can be."
        case .conflict: return "Both versions are kept. Keep both as separate files, compare them, or make yours the current version."
        }
    }
}
