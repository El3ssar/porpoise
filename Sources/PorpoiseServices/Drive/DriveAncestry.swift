import Foundation
import PorpoiseCore

/// Where a folder known only by its id (a pasted link, gdrive://account/folder/<id>) really is: its parents walked
/// up to My Drive's root, a shared drive, or the highest folder shared with this account. Its folders get the same
/// locations a listing gives them, so the breadcrumb, Properties and the Folders tree all name the same places.
enum DriveAncestry {
    enum Result: Equatable {
        /// The folders above the item, outermost first, starting at its row (My Drive, Shared with me, Shared drives).
        case found([URL])
        /// This file has to be read first (the item, a parent, or "root" for My Drive's id).
        case missing(String)
    }

    /// `file` reads what's known; `unreachable` are parents this account can't read (the folder above a shared one).
    static func resolve(_ id: String, account: UUID, file: (String) -> DriveFile?, unreachable: Set<String>) -> Result {
        guard var current = file(id) else { return .missing(id) }
        var path = [current]  // from the top to the item
        var seen: Set<String> = [id]
        while true {
            let row: DriveLocation.Collection?
            if let drive = current.driveId, current.id == drive {
                row = .sharedDrives  // a shared drive's own folder sits in the Shared drives row
            } else if let parent = current.parents?.first, !unreachable.contains(parent) {
                guard let root = file("root") else { return .missing("root") }
                if parent == root.id {
                    row = .myDrive
                } else {
                    guard let next = file(parent) else { return .missing(parent) }
                    guard seen.insert(parent).inserted, path.count < 64 else { return .found([]) }  // a cycle: nothing guessed
                    current = next
                    path.insert(next, at: 0)
                    row = nil
                }
            } else {
                row = .sharedWithMe  // nothing above it can be read: it was shared with this account
            }
            if let row {
                var location = DriveLocation(accountID: account, collection: row)
                var urls = [location.url]
                for folder in path {
                    location = folder.childLocation(in: location)
                    urls.append(location.url)
                }
                return .found(Array(urls.dropLast()))
            }
        }
    }
}
