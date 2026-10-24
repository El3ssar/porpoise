import Darwin
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
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
    /// W-236 (W-235 D15): looking for a free counter renders names only; the contents once, for the name found; a
    /// folder already read isn't read again; and the first free number is the one taken.
    @Test func aFreeCounterIsFoundByNameOnly() throws {
        let scratch = try Scratch()
        for i in 1...2000 { FileManager.default.createFile(atPath: scratch.path(String(format: "Note %04d.txt", i)).path, contents: nil) }
        let body = String(repeating: "{name} ", count: 1000) + String(repeating: "x", count: 4 << 20)
        let template = FileTemplate(title: "Note", filename: "Note.txt", contents: Data(body.utf8))
        let store = TemplateStore(directory: scratch.path("Templates"))
        let render = store.renderTemplate
        var renders = 0
        store.renderTemplate = { template, pattern, context in
            renders += 1
            return try render(template, pattern, context)
        }
        let found = try store.preview(template, pattern: "Note {counter:04}.txt", folder: scratch.url, context: TemplateContext(name: "x"))
        #expect(found.name == "Note 2001.txt" && found.counter == 2001, "\(found.name)")
        #expect(String(decoding: found.contents.prefix(10), as: UTF8.self) == "Note 2001 ")
        #expect(renders == 1, "contents are expanded only after the free name is found")
        // Names already read: the folder isn't listed again (a name missing from them is taken as free).
        let given = try store.preview(
            template, pattern: "Note {counter:04}.txt", folder: scratch.path("missing"), context: TemplateContext(name: "x"),
            existing: ["Note 0001.txt", "Note 0002.txt", "Note 0003.txt", "Note 0004.txt", "Note 0005.txt"])
        // The first free number: 6 (counting on from a counter already moved gave 7).
        #expect(given.name == "Note 0006.txt")
        #expect(renders == 2)
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
