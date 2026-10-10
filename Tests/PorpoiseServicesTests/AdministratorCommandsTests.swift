import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport
@testable import PorpoiseServices

/// The commands Porpoise would run as administrator. Only built and inspected here: nothing runs with privileges.
@Suite struct AdministratorCommandsTests {
    let hostile = ["-rf", "a b", "line\nbreak", "it's", "$(touch pwned)", "\"quoted\"", "back\\slash", "*", "🐬"]

    @Test func deleteClearsLocksThenRemoves() {
        let u = URL(fileURLWithPath: "/Volumes/Data/-rf")
        let plan = FileOperationsController.administratorCommands(.delete, [u], targets: [:], to: nil)
        #expect(plan.commands == [["/usr/bin/chflags", "-R", "nouchg,noschg", "/Volumes/Data/-rf"],
                                  ["/bin/rm", "-rf", "--", "/Volumes/Data/-rf"]])
        #expect(plan.results.isEmpty && plan.skipped.isEmpty)
    }

    @Test func copyMoveAndLinkGoToTheirTargets() throws {
        let s = try Scratch()
        let a = URL(fileURLWithPath: "/Users/other/a.txt"), b = URL(fileURLWithPath: "/Users/other/b.txt")
        let renamed = s.path("b (1).txt")
        let targets = [b: renamed]
        let copy = FileOperationsController.administratorCommands(.copy, [a, b], targets: targets, to: s.url)
        #expect(copy.commands == [["/bin/cp", "-pR", "--", a.path, s.path("a.txt").path], ["/bin/cp", "-pR", "--", b.path, renamed.path]])
        #expect(copy.results == [s.path("a.txt"), renamed])
        let move = FileOperationsController.administratorCommands(.move, [a], targets: [:], to: s.url)
        #expect(move.commands == [["/bin/mv", "--", a.path, s.path("a.txt").path]])
        let link = FileOperationsController.administratorCommands(.link, [a], targets: [:], to: s.url)
        #expect(link.commands == [["/bin/ln", "-s", "--", a.path, s.path("a.txt").path]])
    }

    @Test func anExistingFolderAtTheTargetIsLeftAlone() throws {
        // mv and cp would put the item inside it instead of replacing it.
        let s = try Scratch()
        try s.folder("photos")
        try s.file("note")
        let src = [URL(fileURLWithPath: "/x/photos"), URL(fileURLWithPath: "/x/note")]
        let copy = FileOperationsController.administratorCommands(.copy, src, targets: [:], to: s.url)
        #expect(copy.commands == [["/bin/cp", "-pR", "--", "/x/note", s.path("note").path]])
        #expect(copy.skipped == ["“photos” already exists in “\(s.url.lastPathComponent)”."])
        // A link never replaces anything.
        let link = FileOperationsController.administratorCommands(.link, [src[1]], targets: [:], to: s.url)
        #expect(link.commands.isEmpty && link.skipped.count == 1)
    }

    @Test func trashGetsFreeNamesEvenForItemsNamedAlike() {
        let name = "porpoise-test-\(UUID().uuidString).txt"
        let urls = [URL(fileURLWithPath: "/one/\(name)"), URL(fileURLWithPath: "/two/\(name)"), URL(fileURLWithPath: "/three/\(name)")]
        let plan = FileOperationsController.administratorCommands(.trash, urls, targets: [:], to: nil)
        let base = (name as NSString).deletingPathExtension
        let expected = [name, "\(base) 2.txt", "\(base) 3.txt"].map { TrashInfo.folder.appendingPathComponent($0) }
        #expect(plan.trashed.map(\.inTrash) == expected)
        #expect(plan.trashed.map(\.original) == urls)
        #expect(plan.commands == zip(urls, expected).map { ["/bin/mv", "--", $0.path, $1.path] })
    }

    @Test func freeTrashNamesWithoutAnExtension() {
        var reserved: Set<String> = ["porpoise-test-folder", "porpoise-test-folder 2"]
        let u = FileOperationsController.freeTrashURL(for: URL(fileURLWithPath: "/x/porpoise-test-folder"), reserving: &reserved)
        #expect(u.lastPathComponent == "porpoise-test-folder 3")
        #expect(reserved.contains("porpoise-test-folder 3"))
    }

    @Test func renameIsOneMoveThatNeverOverwrites() {
        let cmds = FileOperationsController.renameCommands(URL(fileURLWithPath: "/x/old"), to: URL(fileURLWithPath: "/x/-new"))
        #expect(cmds == [["/bin/mv", "-n", "--", "/x/old", "/x/-new"]])
    }

    @Test func aCaseOnlyRenameGoesThroughATemporaryName() throws {
        let cmds = FileOperationsController.renameCommands(URL(fileURLWithPath: "/x/readme"), to: URL(fileURLWithPath: "/x/README"))
        try #require(cmds.count == 2)
        let tmp = cmds[0][4]
        #expect(tmp.hasPrefix("/x/.porpoise-rename-"))
        #expect(cmds == [["/bin/mv", "-n", "--", "/x/readme", tmp], ["/bin/mv", "-n", "--", tmp, "/x/README"]])
    }

    @Test func eachCommandRunsInItsOwnSubshellAndLockClearingMayFail() {
        let script = FileOperationsController.administratorScript([["/usr/bin/chflags", "nouchg", "/a"], ["/bin/rm", "--", "/a"]])
        #expect(script == #"do shell script "( '/usr/bin/chflags' 'nouchg' '/a' 2>/dev/null; true ) && ( '/bin/rm' '--' '/a' )" with administrator privileges"#)
    }

    /// The script's shell line, run without privileges through `printf`, gives back every hostile name as one
    /// argument, unchanged: nothing is split, expanded or executed.
    @Test func hostileNamesStaySingleArgumentsThroughAppleScriptAndTheShell() throws {
        let s = try Scratch()
        let script = FileOperationsController.administratorScript([["/usr/bin/printf", "<%s>"] + hostile])
        let suffix = " with administrator privileges"
        try #require(script.hasSuffix(suffix))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", String(script.dropLast(suffix.count))]
        p.currentDirectoryURL = s.url
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        // do shell script turns line endings into returns.
        let printed = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n").dropLast()
        #expect(printed == hostile.map { "<\($0)>" }.joined())
        #expect(s.listing().isEmpty)   // $(touch pwned) did not run
    }
}
