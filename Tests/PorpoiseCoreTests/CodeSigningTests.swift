import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport

/// The helper's check that the app asking it is intact on disk, on a real bundle signed (ad hoc) by codesign.
struct CodeSigningTests {
    let scratch: Scratch
    let app: URL
    let requirement = #"identifier "test.porpoise.intact""#

    /// A bundle with a program, a resource and a nested program, as Porpoise has (Sparkle, ffmpeg).
    init() throws {
        scratch = try Scratch("codesigning")
        app = scratch.path("Intact.app")
        _ = try scratch.file("Intact.app/Contents/Info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>test.porpoise.intact</string>
              <key>CFBundleExecutable</key><string>main</string>
            </dict></plist>
            """)
        _ = try scratch.file("Intact.app/Contents/Resources/data.txt", "original")
        for (program, tool) in [("MacOS/main", "/bin/sleep"), ("Helpers/inner", "/usr/bin/true")] {
            let to = app.appendingPathComponent("Contents/\(program)")
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: tool), to: to)
        }
        try sign(app.appendingPathComponent("Contents/Helpers/inner"), identifier: "test.porpoise.inner")
        try sign(app, identifier: nil)
    }

    private func sign(_ url: URL, identifier: String?) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-"] + (identifier.map { ["--identifier", $0] } ?? []) + [url.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0, "codesign failed")
    }

    @Test func anIntactBundlePasses() {
        #expect(CodeSigning.isIntact(at: app, requirement: requirement))
    }

    @Test func anotherIdentityFails() {
        #expect(!CodeSigning.isIntact(at: app, requirement: #"identifier "app.porpoise.Porpoise""#))
        #expect(!CodeSigning.isIntact(at: app, requirement: "not a requirement"))
    }

    @Test func aChangedResourceFails() throws {
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources/data.txt"))
        #expect(!CodeSigning.isIntact(at: app, requirement: requirement))
    }

    /// A swapped framework or helper program, validly signed on its own, still breaks the app's seal.
    @Test func aReplacedNestedProgramFails() throws {
        try sign(app.appendingPathComponent("Contents/Helpers/inner"), identifier: "test.porpoise.intruder")
        #expect(!CodeSigning.isIntact(at: app, requirement: requirement))
    }

    @Test func anAddedFileFails() throws {
        _ = try scratch.file("Intact.app/Contents/Resources/extra.txt", "added")
        #expect(!CodeSigning.isIntact(at: app, requirement: requirement))
    }

    @Test func aRunningProcessIsCheckedThroughItsBundle() throws {
        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/main")
        p.arguments = ["30"]
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        #expect(CodeSigning.isIntact(pid: p.processIdentifier, requirement: requirement))
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources/data.txt"))
        #expect(!CodeSigning.isIntact(pid: p.processIdentifier, requirement: requirement))
    }

    @Test func otherProcessesFail() {
        #expect(!CodeSigning.isIntact(pid: getpid(), requirement: requirement))   // this test, signed otherwise
        #expect(!CodeSigning.isIntact(pid: -1, requirement: requirement))
    }
}
