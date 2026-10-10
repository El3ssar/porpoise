import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport
@testable import PorpoiseServices

/// ADBProvider without a phone: adb is a `RecordingTool`, so these check the commands a device would run and how
/// its replies are read.
@Suite struct ADBProviderTests {
    let adb: RecordingTool
    let provider: ADBProvider

    init() throws {
        adb = try RecordingTool()
        provider = ADBProvider(serial: "R58N123", adb: adb.path)
    }

    private func url(_ path: String) -> URL { URL(string: "adb://R58N123" + path)! }

    /// The script passed to `adb -s SERIAL shell`.
    private var shellScripts: [String] {
        adb.calls.compactMap { c in c.args.prefix(3) == ["-s", "R58N123", "shell"] ? c.args.last : nil }
    }

    static let toybox = """
        total 24
        drwxrwx--x  4 root sdcard_rw 3452 2024-05-01 10:12 .
        drwxrwx--x  4 root sdcard_rw 3452 2024-05-01 10:12 ..
        drwxrws---  2 u0_a1 media_rw 3452 2025-02-03 08:00 DCIM
        -rw-rw----  1 u0_a1 media_rw 2048 2025-02-03 08:01 it's a photo.jpg

        """

    @Test func theRootIsSharedStorage() throws {
        try adb.reply(Self.toybox)
        let items = try provider.list(url("/"))
        #expect(shellScripts == ["ls -la '/sdcard/'"])
        #expect(items.map(\.name) == ["DCIM", "it's a photo.jpg"])
        #expect(items[0].url.absoluteString == "adb://R58N123/sdcard/DCIM/")
        #expect(items[1].size == 2048 && items[1].modificationDate != nil)
    }

    @Test func pathsAreQuotedForTheDeviceShell() throws {
        try adb.reply("")
        _ = try provider.list(url("/sdcard/it's%20$(reboot)"))
        try provider.makeFolder(url("/sdcard/new%20%60x%60"))
        try provider.delete([url("/sdcard/a%20b"), url("/sdcard/-rf")])
        try provider.copy([url("/sdcard/a")], into: url("/sdcard/b%20c"))
        try provider.move([url("/sdcard/a"), url("/sdcard/d")], into: url("/sdcard/e"))
        #expect(shellScripts == [
            "ls -la '/sdcard/it'\\''s $(reboot)/'",
            "mkdir -p '/sdcard/new `x`'",
            "rm -rf '/sdcard/a b' '/sdcard/-rf'",
            "cp -r '/sdcard/a' '/sdcard/b c'/",
            "mv '/sdcard/a' '/sdcard/d' '/sdcard/e'/",
        ])
    }

    @Test func renameChecksTheTargetOnTheDevice() throws {
        try adb.reply("")
        try provider.rename(url("/sdcard/old.txt"), to: "new it's.txt")
        #expect(shellScripts == ["if [ -e '/sdcard/new it'\\''s.txt' ]; then echo __PORPOISE_EXISTS__; "
                                 + "else mv '/sdcard/old.txt' '/sdcard/new it'\\''s.txt'; fi"])
        // Older adb doesn't pass exit codes on: the marker in the output is what tells.
        try adb.reply("__PORPOISE_EXISTS__\n")
        #expect { try provider.rename(url("/sdcard/old.txt"), to: "taken.txt") } throws: {
            $0.localizedDescription.contains("already exists")
        }
    }

    @Test func refusesTopFoldersAndUnsafeNamesWithoutRunningAnything() {
        for top in ["/", "/sdcard", "/sdcard/", ""] {
            #expect(throws: (any Error).self) { try provider.delete([url(top)]) }
        }
        for name in ["..", "a/b", "x\r\ny"] {
            #expect(throws: (any Error).self) { try provider.rename(url("/sdcard/a"), to: name) }
        }
        #expect(adb.calls.isEmpty)
    }

    @Test func pushesIntoTheFolder() throws {
        let local = try Scratch()
        let file = try local.file("-photo [1].jpg", "x")
        try adb.reply("")
        try provider.upload(file, into: url("/sdcard/DCIM"))
        #expect(adb.calls.first?.args == ["-s", "R58N123", "push", file.path, "/sdcard/DCIM/"])
    }

    @Test func failuresBecomeErrors() throws {
        try adb.reply("", status: 1)
        #expect { try provider.makeFolder(url("/sdcard/x")) } throws: { $0.localizedDescription == "adb failed (1)" }
        try adb.reply("ls: /data: Permission denied\n")
        #expect { try provider.list(url("/data")) } throws: { $0.localizedDescription == "Permission denied" }
    }

    @Test func titleIsTheModelAskedOnce() throws {
        try adb.reply("List of devices attached\nR58N123 device usb:1-1 product:x model:Galaxy_S21 device:o1s\n")
        provider.titleTimeout = 30   // a busy test run can be slow to start the stand-in adb
        #expect(provider.rootTitle(url("/")) == "Galaxy S21")
        #expect(provider.rootTitle(url("/")) == "Galaxy S21")
        #expect(adb.calls.map(\.args) == [["devices", "-l"]])
    }

    @Test func titleFallsBackToTheSerial() throws {
        try adb.reply("List of devices attached\n")
        #expect(provider.rootTitle(url("/")) == "R58N123")
    }
}
