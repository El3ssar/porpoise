import Foundation
import Testing
import PorpoiseCore
import PorpoiseTestSupport
@testable import PorpoiseServices

/// FTPProvider drives curl. With no FTP server to test against, curl is replaced by a `RecordingTool`: these tests
/// check what curl would be given (arguments, the login on stdin) and how its output is read. Logins are looked up
/// and saved in a throwaway keychain.
@Suite(.serialized) struct FTPProviderTests {
    let curl: RecordingTool
    let keychain: TestKeychain

    init() throws {
        curl = try RecordingTool()
        keychain = try TestKeychain()
    }

    private func provider(_ url: String) -> FTPProvider {
        FTPProvider(url: URL(string: url)!, curl: curl.path, keychain: keychain.keychain)
    }

    static let listing = """
        drwxr-xr-x    2 ftp      ftp          4096 Jan  5  2024 pub dir\r
        -rw-r--r--    1 ftp      ftp            12 Mar  1  2024 report[1] {a,b}.txt\r
        lrwxrwxrwx    1 ftp      ftp             7 Mar  1  2024 latest -> pub dir\r

        """

    @Test func listsThroughCurlWithTheLoginOnStdinOnly() throws {
        try curl.reply(Self.listing)
        let items = try provider("ftp://me:s3cret@h.invalid/pub/").list(URL(string: "ftp://me:s3cret@h.invalid/pub/")!)

        #expect(items.map(\.name) == ["pub dir", "report[1] {a,b}.txt", "latest"])
        #expect(items[0].isDirectory && items[1].size == 12 && items[2].linkDestination == "pub dir")
        // FTP servers list in UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        #expect(utc.dateComponents([.year, .month, .day], from: items[1].modificationDate!) == DateComponents(year: 2024, month: 3, day: 1))

        let call = try #require(curl.calls.first)
        #expect(call.args.last == "ftp://h.invalid/pub/")
        #expect(call.args.contains("--globoff") && call.args.contains("--config"))
        #expect(!call.args.contains { $0.contains("s3cret") })     // never visible in `ps`
        #expect(call.stdin == "user = \"me:s3cret\"\n")
    }

    @Test func loginIsEscapedForCurlsConfigSyntax() throws {
        try curl.reply("")
        // Typed in a URL, the password is percent-encoded: curl must get the password itself.
        _ = try provider("ftp://me:a%22b%5Cc%0D%0Ad%40@h.invalid/").list(URL(string: "ftp://h.invalid/")!)
        #expect(curl.calls.first?.stdin == "user = \"me:a\\\"b\\\\c\\r\\nd@\"\n")
    }

    @Test func withoutALoginCurlGetsNoConfig() throws {
        try curl.reply("")
        _ = try provider("ftp://h.invalid/").list(URL(string: "ftp://h.invalid/")!)
        let call = try #require(curl.calls.first)
        #expect(!call.args.contains("--config") && call.stdin.isEmpty)
    }

    @Test func ftpsRequiresTLSAndKeepsThePort() throws {
        try curl.reply("")
        _ = try provider("ftps://h.invalid:2121/").list(URL(string: "ftps://h.invalid:2121/a b/")!)
        let call = try #require(curl.calls.first)
        #expect(call.args.contains("--ssl-reqd"))
        #expect(call.args.last == "ftp://h.invalid:2121/a%20b/")
    }

    @Test func uploadedNamesAreNotCurlPatterns() throws {
        let local = try Scratch()
        let file = try local.file("report[1] {a,b}.txt", "x")
        try curl.reply("")
        try provider("ftp://h.invalid/").upload(file, into: URL(string: "ftp://h.invalid/in/")!)
        let call = try #require(curl.calls.first)
        #expect(call.args.contains("--globoff"))
        #expect(call.args.suffix(3) == ["-T", file.path, "ftp://h.invalid/in/report%5B1%5D%20%7Ba,b%7D.txt"])
    }

    @Test func downloadsAFileAfterCheckingItIsNotAFolder() throws {
        let local = try Scratch()
        try curl.reply(Self.listing, call: 0)
        try curl.reply("file body", call: 1)
        let got = try provider("ftp://h.invalid/").download(URL(string: "ftp://h.invalid/pub/report%5B1%5D%20%7Ba,b%7D.txt")!, into: local.url)
        #expect(got.lastPathComponent == "report[1] {a,b}.txt")
        #expect(local.read("report[1] {a,b}.txt") == "file body")
        #expect(curl.calls.map { $0.args.last } == ["ftp://h.invalid/pub/", "ftp://h.invalid/pub/report%5B1%5D%20%7Ba,b%7D.txt"])
    }

    @Test func commandsArePathsRelativeToTheLoginFolder() throws {
        try curl.reply("")
        let p = provider("ftp://h.invalid/")
        try p.makeFolder(URL(string: "ftp://h.invalid/pub/new%20dir")!)
        try p.rename(URL(string: "ftp://h.invalid/pub/a.txt")!, to: "b c.txt")
        let calls = curl.calls
        #expect(calls[0].args.suffix(5) == ["-Q", "MKD pub/new dir", "-o", "/dev/null", "ftp://h.invalid/"])
        // Rename lists the folder first: most servers would let RNTO replace an existing file.
        #expect(calls[1].args.last == "ftp://h.invalid/pub/")
        #expect(calls[2].args.suffix(7) == ["-Q", "RNFR pub/a.txt", "-Q", "RNTO pub/b c.txt", "-o", "/dev/null", "ftp://h.invalid/"])
    }

    @Test func renameNeverReplacesAnExistingFile() throws {
        try curl.reply(Self.listing)
        #expect { try provider("ftp://h.invalid/").rename(URL(string: "ftp://h.invalid/x.txt")!, to: "pub dir") } throws: {
            $0.localizedDescription.contains("already exists")
        }
        #expect(curl.calls.count == 1)   // only the listing
    }

    @Test func deletesFilesWithDELEAndRefusesTheTopFolder() throws {
        try curl.reply(Self.listing)
        let p = provider("ftp://h.invalid/")
        try p.delete([URL(string: "ftp://h.invalid/report%5B1%5D%20%7Ba,b%7D.txt")!])
        #expect(curl.calls.last?.args.contains("DELE report[1] {a,b}.txt") == true)
        let before = curl.calls.count
        #expect(throws: (any Error).self) { try p.delete([URL(string: "ftp://h.invalid/")!]) }
        #expect(curl.calls.count == before)
    }

    /// A line break in a raw FTP command would end it and start another (here: delete everything in "/").
    @Test(arguments: ["ftp://h.invalid/a%0D%0ADELE%20x", "ftp://h.invalid/a%0ARMD%20x"])
    func lineBreaksNeverReachTheControlConnection(_ url: String) throws {
        try curl.reply(Self.listing)
        let p = provider("ftp://h.invalid/")
        let target = URL(string: url)!
        #expect(throws: (any Error).self) { try p.makeFolder(target) }
        #expect(throws: (any Error).self) { try p.move([target], into: URL(string: "ftp://h.invalid/pub/")!) }
        #expect(throws: (any Error).self) { try p.rename(URL(string: "ftp://h.invalid/a")!, to: "b\r\nDELE x") }
        #expect(curl.calls.allSatisfy { call in !call.args.contains { RemoteFS.hasLineBreak($0) } })
    }

    @Test func curlErrorsBecomeMessages() throws {
        try curl.reply("", status: 9)
        #expect(throws: (any Error).self) { try provider("ftp://h.invalid/").list(URL(string: "ftp://h.invalid/")!) }
    }

    // MARK: Logins

    @Test func aRefusedLoginAsksOnceAndSavesTheNewLogin() throws {
        try curl.reply("530 Login incorrect.", status: 67)
        nonisolated(unsafe) var asked: [(String, String?)] = []
        RemoteFS.askLogin = { host, user in asked.append((host, user)); return ("you", "n3w\"pw") }
        defer { RemoteFS.askLogin = { _, _ in nil } }

        #expect(throws: (any Error).self) { try provider("ftp://me:old@h.invalid/").list(URL(string: "ftp://h.invalid/")!) }

        #expect(asked.count == 1 && asked[0].0 == "h.invalid" && asked[0].1 == "me")
        #expect(curl.calls.map(\.stdin) == ["user = \"me:old\"\n", "user = \"you:n3w\\\"pw\"\n"])
        #expect(keychain.password(server: "h.invalid", account: "you", protocol: kSecAttrProtocolFTP) == "n3w\"pw")
    }

    @Test func aCancelledLoginPromptStopsAtTheFirstFailure() throws {
        try curl.reply("", status: 67)
        #expect(throws: (any Error).self) { try provider("ftp://me:old@h.invalid/").list(URL(string: "ftp://h.invalid/")!) }
        #expect(curl.calls.count == 1)
    }

    @Test func aSavedLoginIsUsedWhenTheURLHasNoPassword() throws {
        keychain.add(server: "h.invalid", account: "me", password: "from keychain", protocol: kSecAttrProtocolFTP)
        try curl.reply("")
        _ = try provider("ftp://me@h.invalid/").list(URL(string: "ftp://h.invalid/")!)
        #expect(curl.calls.first?.stdin == "user = \"me:from keychain\"\n")
    }
}
