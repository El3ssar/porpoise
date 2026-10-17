import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct FilePathNotificationTests {
    @Test func changesUseTheSameParentIdentityBeforeAndAfterDeletion() throws {
        let s = try Scratch(), file = try s.file("real/file", "x"), alias = s.path("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: s.path("real"))
        let parent = FilePath.canonical(s.path("real").path)
        let paths = Locked<Set<String>>([])
        let observer = NotificationCenter.default.addObserver(forName: FileOperationsController.foldersChanged, object: nil, queue: nil) { note in
            guard let changed = note.userInfo?["paths"] as? Set<String>, changed.contains(parent) else { return }
            paths.change { $0 = changed }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        FileOperationsController.notifyChanged([alias.appendingPathComponent("file")])
        let before = paths.value
        try FileManager.default.removeItem(at: file)
        FileOperationsController.notifyChanged([alias.appendingPathComponent("file")])
        #expect(paths.value == before)
        #expect(before.contains(parent))
    }
}
