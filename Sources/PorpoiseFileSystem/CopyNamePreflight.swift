import Darwin
import Foundation
import PorpoiseCore

/// FAT metadata occupies paired ._ names. Refuse a user-data collision before writing either item.
public enum CopyNamePreflight {
    public static func validateDestination(_ target: URL, source: URL? = nil) throws {
        guard isPackedMetadataVolume(target.deletingLastPathComponent()) else { return }
        try check(
            target,
            generatedSource: source.map { $0.isFileURL && $0.lastPathComponent.hasPrefix("._") && CopyVerification.isGeneratedAppleDouble($0) }
                ?? false)
    }

    public static func validateCopy(
        _ source: URL, to target: URL, siblings: [URL], cancellation: DiskCancellation = DiskCancellation(),
        excluded: (URL) -> Bool = { _ in false }
    ) throws {
        guard isPackedMetadataVolume(target.deletingLastPathComponent()) else { return }
        func context(_ siblings: [URL]) throws -> (names: Set<String>, userSidecars: Set<String>) {
            var names: Set<String> = [], userSidecars: Set<String> = []
            for sibling in siblings {
                try cancellation.check()
                if excluded(sibling) { continue }
                let name = sibling.lastPathComponent
                names.insert(name)
                if name.hasPrefix("._"), !CopyVerification.isGeneratedAppleDouble(sibling) { userSidecars.insert(name) }
            }
            return (names, userSidecars)
        }
        func walk(_ source: URL, _ target: URL, names: Set<String>, userSidecars: Set<String>, displayParent: String) throws {
            try cancellation.check()
            if excluded(source) { return }
            let name = target.lastPathComponent
            let generated = source.lastPathComponent.hasPrefix("._") && CopyVerification.isGeneratedAppleDouble(source)
            if name.hasPrefix("._"), !generated, names.contains(String(name.dropFirst(2))) { throw reserved(name, parent: displayParent) }
            if userSidecars.contains("._" + name) { throw reserved("._" + name, parent: displayParent) }
            try check(target, generatedSource: generated, displayParent: displayParent)
            var info = stat()
            guard lstat(source.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard info.st_mode & S_IFMT == S_IFDIR else { return }
            let all = try CopyVerification.directoryNames(source.path)
            let children = CopyVerification.contentNames(all, at: source).map { source.appendingPathComponent($0) }
            let next = try context(children)
            let childParent = displayParent.isEmpty ? source.lastPathComponent : displayParent + "/" + source.lastPathComponent
            for child in children {
                try walk(
                    child, target.appendingPathComponent(child.lastPathComponent), names: next.names, userSidecars: next.userSidecars,
                    displayParent: childParent)
            }
        }
        let initial = try context(siblings)
        try walk(source, target, names: initial.names, userSidecars: initial.userSidecars, displayParent: "")
    }

    private static func check(_ target: URL, generatedSource: Bool, displayParent: String = "") throws {
        let name = target.lastPathComponent, parent = target.deletingLastPathComponent()
        if name.hasPrefix("._"), !generatedSource, FileJob.itemExists(at: parent.appendingPathComponent(String(name.dropFirst(2)))) {
            throw reserved(name, parent: displayParent)
        }
        let sidecar = parent.appendingPathComponent("._" + name)
        if FileJob.itemExists(at: sidecar), !CopyVerification.isGeneratedAppleDouble(sidecar) {
            throw reserved(sidecar.lastPathComponent, parent: displayParent)
        }
    }
    private static func reserved(_ name: String, parent: String) -> FileOperationError {
        let path = parent.isEmpty ? name : parent + "/" + name
        return .failed(
            "“\(path)” is reserved for file metadata on this drive when its counterpart is present. This also applies to ._ files extracted from archives. Rename the item or choose another location."
        )
    }
    private static func isPackedMetadataVolume(_ folder: URL) -> Bool {
        guard folder.isFileURL else { return false }
        var volume = statfs()
        guard statfs(folder.path, &volume) == 0 else { return false }
        let type = withUnsafeBytes(of: volume.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return type == "msdos" || type == "exfat"
    }
}
