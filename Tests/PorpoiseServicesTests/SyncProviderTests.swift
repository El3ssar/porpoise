import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

extension SSHProviderTests {
    @Test func syncPublishesStagedBytesAndPreservesDateOnRealSSH() throws {
        let directory = try server.folder()
        let staged = directory.appendingPathComponent(".porpoise-sync-it's staged")
        let target = directory.appendingPathComponent("target 'quoted'.txt")
        try Data("complete".utf8).write(to: staged)
        try Data("original".utf8).write(to: target)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = server.provider()
        try provider.publishSyncFile(server.url(staged), to: server.url(target), modified: date)
        #expect(try String(contentsOf: target, encoding: .utf8) == "complete")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let modified = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(modified == date)
        #expect(throws: (any Error).self) {
            try provider.publishSyncFile(server.url(staged), to: server.url(target), modified: date)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "complete")
    }
}

extension FTPProviderTests {
    @Test func syncSetsDateBeforeAtomicRenameAndNeverDeletes() throws {
        try curl.reply("")
        let root = URL(string: "ftp://h.invalid/")!
        let provider = FTPProvider(url: root, curl: curl.path, keychain: keychain.keychain)
        try provider.publishSyncFile(
            root.appendingPathComponent("stage"), to: root.appendingPathComponent("target"),
            modified: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(curl.calls.count == 2)
        #expect(curl.calls[0].args.contains("MFMT 20231114221320 stage"))
        #expect(curl.calls[1].args.contains("RNFR stage") && curl.calls[1].args.contains("RNTO target"))
        #expect(!curl.calls.flatMap(\.args).contains { $0.hasPrefix("DELE") })
    }
    @Test func unsupportedFTPDatePreservationStopsBeforePublish() throws {
        try curl.reply("MFMT unsupported", status: 21)
        let root = URL(string: "ftp://h.invalid/")!
        let provider = FTPProvider(url: root, curl: curl.path, keychain: keychain.keychain)
        #expect(throws: (any Error).self) {
            try provider.publishSyncFile(root.appendingPathComponent("stage"), to: root.appendingPathComponent("target"), modified: Date())
        }
        #expect(curl.calls.count == 1)
        #expect(!curl.calls[0].args.contains { $0.hasPrefix("RNTO") || $0.hasPrefix("DELE") })
    }
}

extension FTPProviderTests {
    @Test func syncUsesMDTMTimestampsInsteadOfMinutePrecisionListingDates() throws {
        try curl.reply("Content-Length: 42\r\nLast-Modified: Tue, 14 Nov 2023 22:13:20 GMT\r\n")
        let root = URL(string: "ftp://h.invalid/")!
        let provider = FTPProvider(url: root, curl: curl.path, keychain: keychain.keychain)
        #expect(try provider.syncModificationDate(root.appendingPathComponent("file")) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(curl.calls[0].args.contains("--head"))
        try curl.reply("Content-Length: 42\r\n")
        #expect(throws: (any Error).self) { try provider.syncModificationDate(root.appendingPathComponent("file")) }
    }
}
