import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct TemplateStoreTests {
    @Test func savingPersonalEditsPreservesIdentityAndOtherTemplates() throws {
        let s = try Scratch(); let store = TemplateStore(directory: s.path("Templates"))
        var edited = FileTemplate(title: "Notes", filename: "Notes.txt", contents: Data("before".utf8))
        let other = FileTemplate(title: "Notes", filename: "Other.txt", contents: Data("other".utf8))
        try store.save(edited); try store.save(other)
        edited.contents = Data("after".utf8); edited.title = "Renamed"
        try store.save(edited)
        let loaded = try store.personal()
        #expect(loaded.count == 2 && loaded.contains(edited) && loaded.contains(other))
    }
    @Test func malformedOrFutureArchivesAreRejectedWithoutCreatingTemplates() throws {
        let s = try Scratch(); let store = TemplateStore(directory: s.path("Templates"))
        var record = FileTemplate(title: "Unsafe", filename: "../escape", contents: Data())
        try JSONEncoder().encode(record).write(to: s.path("bad.json"))
        #expect(throws: (any Error).self) { try store.importTemplate(s.path("bad.json")) }
        record.filename = "safe.txt"
        try store.export(record, to: s.path("future.json"))
        let encoded = try Data(contentsOf: s.path("future.json"))
        let object = try JSONSerialization.jsonObject(with: encoded)
        var archive = try #require(object as? [String: Any])
        archive["version"] = 99
        try JSONSerialization.data(withJSONObject: archive).write(to: s.path("future.json"))
        #expect(throws: (any Error).self) { try store.importTemplate(s.path("future.json")) }
        #expect(try store.personal().isEmpty)
    }
    @Test func importsExportsAndPersistsPersonalTemplates() throws {
        let s = try Scratch(); let store = TemplateStore(directory: s.path("Templates"))
        let source = try s.file("résumé.txt", "Hello {user}, {name}!")
        let template = try store.importTemplate(source)
        #expect(try store.personal() == [template])
        try store.export(template, to: s.path("export.json"))
        let imported = try store.importTemplate(s.path("export.json"))
        #expect(imported.id != template.id)
        #expect(imported.contents == template.contents)
        #expect(try store.personal().count == 2)
        #expect(try TemplateStore(directory: s.path("Templates")).personal().count == 2)
    }
    @Test func counterPreviewAndCreateNeverOverwrite() throws {
        let s = try Scratch(); let store = TemplateStore(directory: s.path("Templates")); let folder = try s.folder("new")
        try s.file("new/Note-001.txt", "keep")
        let template = FileTemplate(title: "Note", filename: "Note-{counter:03}.txt", contents: Data("{name}".utf8))
        let context = TemplateContext(name: "Note")
        let preview = try store.preview(template, pattern: template.filename, folder: folder, context: context)
        #expect(preview.name == "Note-002.txt" && preview.counter == 2)
        let created = try store.create(template, pattern: template.filename, folder: folder, context: context)
        #expect(created.lastPathComponent == preview.name)
        #expect(s.read("new/Note-001.txt") == "keep")
        #expect(s.read("new/Note-002.txt") == "Note-002")
        #expect(throws: (any Error).self) { try store.create(template, pattern: "Note-001.txt", folder: folder, context: context) }
        #expect(throws: (any Error).self) { try store.create(template, pattern: "../escape", folder: folder, context: context) }
        _ = try store.preview(template, pattern: template.filename, folder: folder, context: TemplateContext(name: "x", counter: Int.max))
    }
    @Test func boundedImportsRejectLinksAndSpecialFiles() throws {
        let s = try Scratch(); let store = TemplateStore(directory: s.path("Templates"))
        let source = try s.file("source.txt", "text")
        let link = try s.symlink("link.txt", to: source.path)
        #expect(throws: (any Error).self) { try store.importTemplate(link) }
        let fifo = s.path("pipe.txt"); try #require(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try store.importTemplate(fifo) }
        let large = try s.file("large.txt", size: 17 * 1024 * 1024)
        #expect(throws: (any Error).self) { try store.importTemplate(large) }
    }
}
