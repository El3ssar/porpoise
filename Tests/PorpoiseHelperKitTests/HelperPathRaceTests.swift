import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseHelperKit

/// Unprivileged fixtures exercise the exact syscall engine; no XPC connection, installed helper or root is used.
@Suite struct HelperPathRaceTests {
    private func run(_ arguments: [String], at boundary: @escaping (HelperBoundary) -> Void = { _ in }) -> String? {
        var operation = HelperFileOperations(boundary: boundary)
        return operation.run(arguments)
    }
    private func privateFolders(_ scratch: Scratch) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: scratch.url, includingPropertiesForKeys: nil))?.filter {
            $0.lastPathComponent.hasPrefix(".porpoise-helper-")
        } ?? []
    }

    @Test(arguments: [HelperBoundary.Phase.beforeParentOpen, .afterParentOpen])
    func aParentReplacedByALinkCannotRedirectAChange(_ phase: HelperBoundary.Phase) throws {
        let s = try Scratch()
        try s.file("parent/item", "original"); try s.file("outside/item", "outside")
        let path = s.path("parent/item").path
        var swapped = false
        let problem = run(["/bin/chmod", "-h", "--", "777", path]) { event in
            guard event.phase == phase, !swapped else { return }; swapped = true
            try! FileManager.default.moveItem(at: s.path("parent"), to: s.path("saved"))
            try! FileManager.default.createSymbolicLink(at: s.path("parent"), withDestinationURL: s.path("outside"))
        }
        #expect(swapped && problem != nil)
        #expect(s.read("saved/item") == "original" && s.read("outside/item") == "outside")
        #expect((try FileManager.default.attributesOfItem(atPath: s.path("outside/item").path)[.posixPermissions] as? NSNumber)?.intValue != 0o777)
    }

    @Test(arguments: ["chmod", "unlock", "remove", "copy", "move"])
    func aLeafSwappedAfterOpenIsRefused(_ action: String) throws {
        let s = try Scratch()
        let path = try s.file("item", "original").path
        try s.file("outside", "outside")
        let args: [String]
        switch action {
        case "chmod": args = ["/bin/chmod", "-h", "--", "777", path]
        case "unlock": args = ["/usr/bin/chflags", "-R", "nouchg,noschg", path]
        case "remove": args = ["/bin/rm", "-rf", "--", path]
        case "copy": args = ["/bin/cp", "-pR", "--", path, s.path("output").path]
        default: args = ["/bin/mv", "--", path, s.path("output").path]
        }
        var swapped = false
        let problem = run(args) { event in
            guard event.phase == .afterLeafOpen, event.path == path, !swapped else { return }; swapped = true
            try! FileManager.default.moveItem(at: s.path("item"), to: s.path("saved"))
            try! FileManager.default.createSymbolicLink(at: s.path("item"), withDestinationURL: s.path("outside"))
        }
        #expect(swapped && problem != nil)
        #expect(s.read("saved") == "original" && s.read("outside") == "outside")
        #expect(!FileManager.default.fileExists(atPath: s.path("output").path))
        #expect(privateFolders(s).isEmpty)
    }

    @Test(arguments: [false, true])
    func replacementInsideTheCaptureGapIsRestored(_ link: Bool) throws {
        let s = try Scratch()
        let path = try s.file("item", "original").path
        try s.file("outside", "outside")
        let problem = run(["/bin/rm", "-rf", "--", path]) { event in
            guard event.phase == .beforeCapture, event.path == path else { return }
            try! FileManager.default.moveItem(at: s.path("item"), to: s.path("saved"))
            if link {
                try! FileManager.default.createSymbolicLink(at: s.path("item"), withDestinationURL: s.path("outside"))
            } else {
                try! Data("replacement".utf8).write(to: s.path("item"))
            }
        }
        #expect(problem != nil)
        #expect(s.read("saved") == "original" && s.read("outside") == "outside")
        if link {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == s.path("outside").path)
        } else {
            #expect(s.read("item") == "replacement")
        }
        #expect(privateFolders(s).isEmpty)
    }

    @Test func aRollbackCollisionRetainsBothNewGenerations() throws {
        let s = try Scratch()
        let path = try s.file("item", "original").path
        let problem = run(["/bin/rm", "-rf", "--", path]) { event in
            guard event.path == path else { return }
            if event.phase == .beforeCapture {
                try! FileManager.default.moveItem(at: s.path("item"), to: s.path("saved"))
                try! Data("captured replacement".utf8).write(to: s.path("item"))
            } else if event.phase == .afterCapture {
                try! Data("new winner".utf8).write(to: s.path("item"))
            }
        }
        #expect(problem?.contains("kept for recovery") == true)
        #expect(s.read("saved") == "original" && s.read("item") == "new winner")
        let retained = try #require(privateFolders(s).first)
        #expect(try String(contentsOf: retained.appendingPathComponent("item"), encoding: .utf8) == "captured replacement")
        let record = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: retained.appendingPathComponent("recovery.json"))) as? [String: Any])
        #expect(record["originalPath"] as? String == path)
        #expect(record["originalName"] as? String == "item")
        #expect(record["parentIdentity"] is [String: Any] && record["originalIdentity"] is [String: Any])
    }

    @Test(arguments: ["copy", "move", "mkdir", "link"])
    func exclusivePublicationPreservesAConcurrentWinner(_ action: String) throws {
        let s = try Scratch()
        let source = try s.file("source", "original").path, target = s.path("target").path
        let args: [String]
        switch action {
        case "copy": args = ["/bin/cp", "-pR", "--", source, target]
        case "move": args = ["/bin/mv", "--", source, target]
        case "mkdir": args = ["/bin/mkdir", "--", target]
        default: args = ["/bin/ln", "-s", "--", source, target]
        }
        let problem = run(args) { event in
            if event.phase == .beforePublish { try! Data("winner".utf8).write(to: s.path("target")) }
        }
        #expect(problem != nil)
        #expect(s.read("target") == "winner" && s.read("source") == "original")
        #expect(privateFolders(s).isEmpty)
    }

    @Test(arguments: [false, true])
    func aNewSourceNameAfterCaptureIsNeverRemoved(_ move: Bool) throws {
        let s = try Scratch()
        let source = try s.file("source", "original").path
        let args = move ? ["/bin/mv", "--", source, s.path("target").path] : ["/bin/rm", "-rf", "--", source]
        let problem = run(args) { event in
            if event.phase == .afterCapture, event.path == source { try! Data("replacement".utf8).write(to: s.path("source")) }
        }
        #expect(problem == nil)
        #expect(s.read("source") == "replacement")
        if move { #expect(s.read("target") == "original") }
        #expect(privateFolders(s).isEmpty)
    }

    @Test func recursiveRemovalCannotFollowAChildSwap() throws {
        let s = try Scratch()
        try s.file("tree/a", "original"); try s.file("outside/secret", "outside")
        var swapped = false
        let problem = run(["/bin/rm", "-rf", "--", s.path("tree").path]) { event in
            guard event.phase == .beforeCapture, event.path.hasSuffix("/a"), !swapped else { return }; swapped = true
            try! FileManager.default.moveItem(atPath: event.path, toPath: s.path("saved").path)
            try! FileManager.default.createSymbolicLink(atPath: event.path, withDestinationPath: s.path("outside").path)
        }
        #expect(swapped && problem != nil)
        #expect(s.read("saved") == "original" && s.read("outside/secret") == "outside")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.path("tree/a").path) == s.path("outside").path)
        #expect(privateFolders(s).isEmpty)
    }

    @Test func copyPreservesARegularTreeAndPhysicalLinks() throws {
        let s = try Scratch()
        try s.file("source/inner/a", "data"); try s.file("outside", "outside")
        try s.symlink("source/link", to: s.path("outside").path)
        #expect(run(["/bin/cp", "-pR", "--", s.path("source").path, s.path("copy").path]) == nil)
        #expect(s.read("copy/inner/a") == "data")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.path("copy/link").path) == s.path("outside").path)
        #expect(s.read("outside") == "outside")
        #expect(run(["/bin/rm", "-rf", "--", s.path("copy").path]) == nil)
        #expect(!FileManager.default.fileExists(atPath: s.path("copy").path))
        #expect(privateFolders(s).isEmpty)
    }

    @Test func permissionChangesRefuseHardlinkAliases() throws {
        let s = try Scratch()
        let file = try s.file("file", "data")
        try FileManager.default.linkItem(at: file, to: s.path("alias"))
        #expect(run(["/bin/chmod", "-h", "--", "777", file.path]) != nil)
        #expect(run(["/usr/bin/chflags", "-R", "nouchg,noschg", file.path]) != nil)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue != 0o777)
        #expect(run(["/bin/rm", "-rf", "--", file.path]) == nil)
        #expect(s.read("alias") == "data")
    }

    @Test func aDestinationFolderIsNeverEnteredAndSelfCopiesAreRefused() throws {
        let s = try Scratch()
        try s.file("source/a", "original"); try s.file("target/keep", "winner")
        #expect(run(["/bin/mv", "--", s.path("source").path, s.path("target").path]) != nil)
        #expect(run(["/bin/cp", "-pR", "--", s.path("source").path, s.path("source/nested").path]) != nil)
        #expect(s.read("target/keep") == "winner" && s.read("source/a") == "original")
        #expect(privateFolders(s).isEmpty)
    }
    @Test func aCrossVolumeMoveFailsClosedAndRestoresTheOldDestination() throws {
        let s = try Scratch()
        let source = try s.file("source", "original"), target = try s.file("target", "old target")
        var operation = HelperFileOperations(move: { _, _, _, _, _ in
            errno = EXDEV; return -1
        })
        let problem = operation.run(["/bin/mv", "--", source.path, target.path])
        #expect(problem?.contains("across volumes atomically") == true)
        #expect(s.read("source") == "original" && s.read("target") == "old target")
        #expect(privateFolders(s).isEmpty)
    }

    @Test func copyingALockedFilePreservesItsLockAndData() throws {
        let s = try Scratch()
        let source = try s.file("source", "locked data"), target = s.path("target")
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(source.path, 0); _ = chflags(target.path, 0) }
        #expect(run(["/bin/cp", "-pR", "--", source.path, target.path]) == nil)
        #expect(s.read("target") == "locked data")
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.immutable] as? Bool) == true)
        #expect(privateFolders(s).isEmpty)
    }

    @Test func replacementAndNoClobberHaveExplicitSemantics() throws {
        let s = try Scratch()
        let source = try s.file("source", "original"), target = try s.file("target", "old target")
        #expect(run(["/bin/mv", "-n", "--", source.path, target.path]) == nil)
        #expect(s.read("source") == "original" && s.read("target") == "old target")
        #expect(run(["/bin/cp", "-pR", "--", source.path, target.path]) == nil)
        #expect(s.read("source") == "original" && s.read("target") == "original")
        #expect(run(["/bin/mv", "--", source.path, target.path]) == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path) && s.read("target") == "original")
        #expect(privateFolders(s).isEmpty)
    }

    @Test func aFailedCopyRetainsTheOldTargetAndCleansItsPartialOutput() throws {
        let s = try Scratch()
        try s.file("source/a", "first"); let unreadable = try s.file("source/z", "secret")
        try s.file("target", "old target")
        #expect(chmod(unreadable.path, 0) == 0)
        defer { _ = chmod(unreadable.path, 0o600) }
        #expect(run(["/bin/cp", "-pR", "--", s.path("source").path, s.path("target").path]) != nil)
        #expect(s.read("target") == "old target" && s.read("source/a") == "first")
        #expect(privateFolders(s).isEmpty)
    }

    @Test func aParentSwappedImmediatelyBeforePublicationIsRefused() throws {
        let s = try Scratch()
        let source = try s.file("source", "original")
        try s.folder("parent"); try s.file("outside/keep", "outside")
        let problem = run(["/bin/cp", "--", source.path, s.path("parent/target").path]) { event in
            if event.phase == .beforePublish {
                try! FileManager.default.moveItem(at: s.path("parent"), to: s.path("saved"))
                try! FileManager.default.createSymbolicLink(at: s.path("parent"), withDestinationURL: s.path("outside"))
            }
        }
        #expect(problem != nil)
        #expect(s.read("outside/keep") == "outside" && s.read("source") == "original")
        #expect(!FileManager.default.fileExists(atPath: s.path("outside/target").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.path("saved").path) == [])
    }

    @Test func recoveryInformationExistsBeforeAValidatedCaptureCanBeUsed() throws {
        let s = try Scratch()
        let source = try s.file("source", "original")
        var recorded = false
        let problem = run(["/bin/mv", "--", source.path, s.path("target").path]) { event in
            if event.phase == .afterCapture {
                let folder = privateFolders(s).first!
                let record =
                    try! JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("recovery.json"))) as! [String: Any]
                recorded = record["originalPath"] as? String == source.path
                let permissions = try! FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as! NSNumber
                #expect(permissions.intValue == 0o700)
            }
        }
        #expect(problem == nil)
        #expect(recorded && s.read("target") == "original")
        #expect(privateFolders(s).isEmpty)
    }

}
