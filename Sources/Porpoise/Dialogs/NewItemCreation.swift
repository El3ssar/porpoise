import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// Immutable work handed off by the name sheet. No view, file enumeration or UI-thread dependency.
struct NewItemCreation: Sendable {
    let kind: NewItemKind
    let folder: URL
    let name: String
    let target: String
    var url: URL { folder.appendingPathComponent(name) }
    var linkTarget: String { (target as NSString).expandingTildeInPath }

    private func contents() throws -> Data {
        if kind == .htmlFile { return NewItemKind.htmlTemplate }
        if kind == .urlLink {
            return try PropertyListSerialization.data(fromPropertyList: ["URL": target], format: .xml, options: 0)
        }
        return Data()
    }

    func create() throws -> URL {
        switch kind {
        case .folder: return try FileActions.makeFolder(named: name, in: folder)
        case .link:
            guard FileName.isValid(name, for: .local), !target.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw FileOperationError.failed("Enter a valid link name and target.")
            }
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: linkTarget)
            return url
        default: return try FileActions.makeFile(named: name, in: folder, contents: contents())
        }
    }

    struct Authorization: Sendable {
        let commands: [[String]]
        let contentsFile: URL?
        let expectedContents: Data?
        /// A no-replace move can succeed without moving. Retain this evidence until its consumption is checked.
        let publicationStage: URL?

        func verifyPublication(at destination: URL) throws {
            if let publicationStage, FileJob.itemExists(at: publicationStage) {
                throw FileOperationError.failed(
                    "No new item was created at “\(destination.path)”. The name may have appeared meanwhile. "
                        + "Your temporary copy was kept at “\(publicationStage.path)” for review.")
            }
            if let expectedContents, try Data(contentsOf: destination) != expectedContents {
                throw FileOperationError.failed(
                    "The new item at “\(destination.path)” changed before creation finished. It was not registered for Undo.")
            }
        }
    }

    func prepareAuthorization() throws -> Authorization {
        let data = try contents()
        let file: URL?
        if kind == .folder || kind == .link {
            file = nil
        } else {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-new-" + UUID().uuidString)
            try data.write(to: temporary, options: .withoutOverwriting)
            file = temporary
        }
        let commands = Self.administratorCommands(kind, at: url, in: folder, linkTarget: linkTarget, contents: file)
        let stage = commands.first.flatMap { command in command.first == "/bin/cp" ? command.last.map { URL(fileURLWithPath: $0) } : nil }
        return Authorization(
            commands: commands, contentsFile: file, expectedContents: file == nil ? nil : data, publicationStage: stage)
    }

    static func administratorCommands(_ kind: NewItemKind, at dst: URL, in folder: URL, linkTarget: String, contents: URL?) -> [[String]] {
        switch kind {
        case .folder:
            // The requested leaf is ALWAYS mkdir'd, even if it appeared while the sheet was open.
            // Existing ancestors can be reused, but an existing leaf must never receive creation Undo.
            var missing = [dst]
            var parent = dst.deletingLastPathComponent()
            while parent.path.count > folder.path.count, !FileManager.default.fileExists(atPath: parent.path) {
                missing.insert(parent, at: 0)
                parent = parent.deletingLastPathComponent()
            }
            return missing.map { ["/bin/mkdir", "--", $0.path] }
        case .link: return [["/bin/ln", "-s", "--", linkTarget, dst.path]]
        default:
            guard let contents else { return [] }
            let staged = dst.deletingLastPathComponent().appendingPathComponent(".porpoise-new-\(UUID().uuidString)").path
            // Never erase the source of a skipped mv -n before the caller checks whether it was consumed.
            return [["/bin/cp", "--", contents.path, staged], ["/bin/mv", "-n", "--", staged, dst.path]]
        }
    }
}
