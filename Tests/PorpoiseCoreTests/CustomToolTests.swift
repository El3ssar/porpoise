import Foundation
import PorpoiseCore
import Testing

struct CustomToolTests {
    private let folder = URL(fileURLWithPath: "/demo/active {prompt}", isDirectory: true)
    private func item(_ name: String, directory: Bool = false, symlink: Bool = false) -> FileItem {
        FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: directory, isSymlink: symlink)
    }
    @Test func selectionIsLiteralArgvAndSubstitutionIsOnePass() throws {
        let names = ["a b.txt", "single'quote", "double\"quote", "line\nbreak", "日本語 🐬", "$(touch nope)", "`touch nope`", "-n", "{folder}"]
        let context = CustomToolContext(folder: folder, otherFolder: URL(fileURLWithPath: "/demo/other"), items: names.map { item($0) })
        var tool = CustomTool(
            name: "Test", executable: "/usr/bin/printf", arguments: ["%s\n", "{selection}", "prefix={folder}", "{otherFolder}", "{prompt}"])
        tool.prompt = "Value"
        let invocation = try tool.invocation(in: context, value: "{folder}; $(touch nope)")
        #expect(
            invocation.arguments == ["%s\n"] + names.map { folder.appendingPathComponent($0).path } + [
                "prefix=" + folder.path, "/demo/other", "{folder}; $(touch nope)",
            ])
        #expect(invocation.folder == folder)
    }
    @Test func matchingIsAllItemsAndFiltersAreOr() throws {
        var tool = CustomTool(name: "Images or text", executable: "/usr/bin/true", arguments: [])
        tool.extensions = ["TXT"]; tool.types = ["public.image"]; tool.targets = .files
        func reason(_ items: [FileItem]) -> String? { tool.unavailableReason(in: CustomToolContext(folder: folder, items: items)) }
        #expect(reason([item("hello.txt"), item("photo.png")]) == nil)
        #expect(reason([item("hello.txt"), item("archive.zip")]) != nil)
        #expect(reason([item("folder.txt", directory: true)]) != nil)
        #expect(reason([item("link.txt", symlink: true)]) == nil)
        #expect(reason([]) != nil)
        tool.selection = .one
        #expect(reason([item("a.txt")]) == nil)
        #expect(reason([item("a.txt"), item("b.txt")]) != nil)
        tool.selection = .folder; tool.targets = .folders; tool.extensions = []; tool.types = []
        #expect(reason([]) == nil)
        tool.targets = .files; #expect(reason([]) != nil)
    }
    @Test func remoteAndMissingSplitAreRejected() throws {
        let remote = URL(string: "sftp://example.invalid/demo")!
        var tool = CustomTool(name: "Test", executable: "/usr/bin/true", arguments: [])
        #expect(tool.unavailableReason(in: CustomToolContext(folder: remote, items: [item("a")])) != nil)
        #expect(tool.unavailableReason(in: CustomToolContext(folder: folder, items: [FileItem(url: remote, name: "a", isDirectory: false)])) != nil)
        tool.arguments = ["{otherFolder}"]
        for other in [nil, remote] {
            #expect(tool.unavailableReason(in: CustomToolContext(folder: folder, otherFolder: other, items: [item("a")])) != nil)
        }
    }
    @Test func validationLimitsAndPromptCancellation() throws {
        let context = CustomToolContext(folder: folder, items: [item("a")])
        for argument in ["prefix{selection}", "{unknown}", "{folder", "x\0"] {
            let tool = CustomTool(name: "Test", executable: "/usr/bin/true", arguments: [argument])
            #expect(throws: (any Error).self) { try tool.validate() }
        }
        var tool = CustomTool(name: "Prompt", executable: "/usr/bin/true", arguments: ["{prompt}"])
        #expect(throws: (any Error).self) { try tool.validate() }
        tool.prompt = "Value"; #expect(throws: (any Error).self) { try tool.invocation(in: context) }
        #expect(try tool.invocation(in: context, value: "").arguments == [""])
        #expect(throws: (any Error).self) { try tool.invocation(in: context, value: "\0") }
        tool.executable = "true"; #expect(throws: (any Error).self) { try tool.validate() }
        var large = CustomTool(name: "Huge", executable: "/bin/echo", arguments: ["{selection}"])
        let many = CustomToolContext(folder: folder, items: (0..<1000).map { item(String(repeating: "x", count: 200) + "\($0)") })
        #expect(many.needsConfirmation)
        #expect(throws: (any Error).self) { try large.invocation(in: many) }
        large.selection = .folder; #expect(throws: (any Error).self) { try large.validate() }
    }
    @Test func shellSourceCannotContainPlaceholders() throws {
        for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
            for flag in ["-c", "-lc", "--command"] {
                let tool = CustomTool(name: "Unsafe source", executable: shell, arguments: [flag, "ls {folder}"])
                #expect(throws: (any Error).self) { try tool.validate() }
            }
        }
        let tool = CustomTool(name: "Safe positional data", executable: "/bin/sh", arguments: ["-c", "printf '%s\\n' \"$@\"", "tool", "{selection}"])
        try tool.validate()
    }
    @Test func documentIsVersionedAtomicAndHasSafeExamples() throws {
        let examples = CustomToolDocument.examples
        let document = CustomToolDocument(tools: examples)
        #expect(try CustomToolDocument.decode(document.encoded()) == document)
        var duplicate = document; duplicate.tools.append(examples[0])
        #expect(throws: (any Error).self) { try duplicate.validate() }
        var future = document; future.version = 99
        #expect(throws: (any Error).self) { try CustomToolDocument.decode(JSONEncoder().encode(future)) }
        #expect(throws: (any Error).self) { try CustomToolDocument.decode(Data(repeating: 32, count: 2 * 1024 * 1024 + 1)) }
        var keys = document; keys.tools[0].shortcut = KeyboardShortcut(key: "t", modifiers: .command); keys.tools[1].shortcut = keys.tools[0].shortcut
        #expect(throws: (any Error).self) { try keys.validate() }
        for tool in examples { try tool.validate() }
    }
}
