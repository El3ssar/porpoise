import Darwin
import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseHelperKit

/// Answers for the system's authorization dialog, and records what the helper asked.
final class FakeAuthorizer: HelperAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [(right: String, prompt: String)] = []
    var asked: [(right: String, prompt: String)] { lock.withLock { _asked } }
    /// What the person does when asked for `right` (also: anything the test does while the dialog is up).
    let answer: (String) -> HelperAuthorizationResult
    var intact = true

    init(_ answer: @escaping (String) -> HelperAuthorizationResult = { _ in .granted }) { self.answer = answer }

    func authorize(_ externalForm: Data, right: String, prompt: String) -> HelperAuthorizationResult {
        lock.withLock { _asked.append((right, prompt)) }
        return answer(right)
    }

    func rulesIntact() -> Bool { intact }
}

/// W-245: every root action is approved by the person, at the tier the helper finds for what it will actually do.
@Suite struct HelperTierTests {
    let me: uid_t = 501
    var policy: HelperPolicy { HelperPolicy(caller: me, otherHomes: [("/Users/bob", "bob"), ("/Volumes/Homes/carol", "carol")]) }
    let form = Data(repeating: 7, count: 32)

    private func tier(_ args: [String], facts: [String: HelperPathFacts] = [:]) throws -> (HelperTier, String?) {
        let op = try HelperOperation(args)
        let r = policy.tier(of: op) { facts[$0] ?? HelperPathFacts(path: $0) }
        return (r.tier, r.reason)
    }

    // MARK: Tiers (pure: facts given, nothing read)

    @Test func standardForTheUsualAdministratorActions() throws {
        for args in [
            ["/bin/mv", "--", "/Applications/Pages.app", "/Users/me/.Trash/Pages.app"], ["/bin/rm", "-rf", "--", "/Applications/Old.app"],
            ["/bin/cp", "-pR", "--", "/Users/me/a", "/Library/Fonts/a"], ["/bin/mkdir", "--", "/Library/Application Support/X"],
            ["/bin/chmod", "-h", "--", "755", "/Applications/A.app"], ["/usr/bin/chflags", "-R", "nouchg,noschg", "/Library/Old/thing"],
            ["/usr/bin/chflags", "-h", "uchg", "/Library/Old/thing"], ["/usr/sbin/chown", "-h", "--", "501:20", "/Library/Old/thing"],
            ["/bin/ln", "-s", "--", "/x", "/usr/local/bin/tool"], ["/bin/rm", "-rf", "--", "/Users/Shared/x"],
            ["/bin/cp", "--", "/System/Library/CoreServices/SystemVersion.plist", "/Users/me/v.plist"],  // reading SIP files is fine
        ] {
            #expect(try tier(args).0 == .standard, "\(args)")
        }
    }

    @Test func protectedWithItsReason() throws {
        let cases: [([String], String)] = [
            (["/bin/rm", "-rf", "--", "/Library/LaunchDaemons/com.vendor.plist"], "changes what runs when your Mac starts"),
            (["/bin/cp", "--", "/tmp/evil", "/Library/LaunchAgents/x.plist"], "changes what runs when your Mac starts"),
            (["/bin/ln", "-s", "--", "/tmp/evil", "/Library/StartupItems/x"], "changes what runs when your Mac starts"),
            (["/bin/cp", "--", "/tmp/x", "/private/etc/sudoers"], "changes system settings"),
            (["/bin/cp", "--", "/private/var/db/dslocal/x", "/Users/me/x"], "is the system's own configuration"),
            (["/bin/mv", "--", "/Users/bob/Documents/a", "/Users/me/a"], "belongs to bob"),
            (["/bin/cp", "--", "/Volumes/Homes/carol/secret", "/Users/me/x"], "belongs to carol"),
            (["/bin/chmod", "-h", "--", "4755", "/Applications/A.app/Contents/MacOS/A"], "sets setuid"),
            (["/bin/chmod", "-h", "--", "1777", "/Library/x"], "sets the sticky bit"),
            (["/usr/sbin/chown", "-h", "--", "0:0", "/Library/x"], "makes root the owner"),
            (["/usr/sbin/chown", "-h", "--", "502:20", "/Library/x"], "changes who owns it"),
            (["/usr/bin/chflags", "-h", "schg", "/Library/x"], "sets a system lock"),
        ]
        for (args, reason) in cases {
            let (t, r) = try tier(args)
            #expect(t == .protected && r == reason, "\(args): \(t) \(r ?? "")")
        }
        // Another person's file outside their home, and a setuid program, by what the item is.
        let theirs = HelperPathFacts(path: "/Library/Shared/x", owner: 502, mode: S_IFREG | 0o644)
        #expect(try tier(["/bin/rm", "-rf", "--", "/Library/Shared/x"], facts: ["/Library/Shared/x": theirs]).0 == .protected)
        let setuid = HelperPathFacts(path: "/usr/local/bin/x", owner: 0, mode: S_IFREG | S_ISUID | 0o755)
        #expect(try tier(["/bin/rm", "-rf", "--", "/usr/local/bin/x"], facts: ["/usr/local/bin/x": setuid]) == (.protected, "is a setuid program"))
        // Paths are compared as their on-disk case (realpath gives it): another case isn't the protected folder.
        #expect(try tier(["/bin/cp", "--", "/tmp/x", "/users/bob/x"]).0 == .standard)
    }

    /// B1 (review): re-owning, re-moding or locking a top-level or fixed folder is refused outright, and a folder
    /// that holds the protected ones is never changed (its owner could swap what's inside).
    @Test func foldersHoldingTheProtectedOnesAreNeverChanged() throws {
        for p in ["/", "/Library", "/private", "/private/var", "/Applications", "/Users", "/Volumes/X", "/System", "/Library/LaunchDaemons"] {
            for args in [
                ["/usr/sbin/chown", "-h", "--", "501:20", p], ["/bin/chmod", "-h", "--", "0777", p], ["/usr/bin/chflags", "-h", "uchg", p],
            ] {
                #expect(HelperRequests.refusal(args) != nil, "\(args)")
            }
        }
        // Below the top level: a folder holding another person's home, or the startup folders' parent.
        #expect(policy.tier(of: HelperPathFacts(path: "/Volumes/Homes"), role: .change) == (.never, HelperPolicy.containsReason))
        #expect(policy.tier(of: HelperPathFacts(path: "/private/var"), role: .remove).tier == .never)
        #expect(policy.tier(of: HelperPathFacts(path: "/Library/Application Support"), role: .change).tier == .standard)
    }

    /// M1/M2 (review): another person's items are protected to read and to replace, and so is writing into their folder;
    /// keychains, swap, logs and audit trails to read.
    @Test func otherPeoplesItemsAndPrivateDataAreProtected() throws {
        let theirs = HelperPathFacts(path: "/private/var/folders/zz/abc/T/secret", owner: 502, mode: S_IFREG | 0o600)
        #expect(policy.tier(of: theirs, role: .read).tier == .protected)
        let replaced = HelperPathFacts(path: "/Applications/Foo.app/Contents/MacOS/Foo", owner: 502, mode: S_IFREG | 0o755)
        #expect(policy.tier(of: replaced, role: .write).tier == .protected)
        let intoTheirs = HelperPathFacts(path: "/Applications/Foo.app/Contents/MacOS/New", parentOwner: 502)
        #expect(policy.tier(of: intoTheirs, role: .write).tier == .protected)
        #expect(policy.tier(of: HelperPathFacts(path: "/Applications/Mine/New", parentOwner: me), role: .write).tier == .standard)
        #expect(policy.tier(of: HelperPathFacts(path: "/Applications/Root/New", parentOwner: 0), role: .write).tier == .standard)
        for p in ["/Library/Keychains/System.keychain", "/private/var/vm/sleepimage", "/private/var/audit/x", "/private/var/log/system.log"] {
            #expect(policy.tier(of: HelperPathFacts(path: p), role: .read) == (.protected, "contains private data"), "\(p)")
        }
        #expect(policy.tier(of: HelperPathFacts.read("/Library/Keychains/System.keychain"), role: .read).tier == .protected)
    }

    @Test func neverWhatSystemIntegrityProtectionKeeps() throws {
        for args in [
            ["/bin/rm", "-rf", "--", "/System/Library/x"], ["/bin/mkdir", "--", "/usr/libexec/x"], ["/bin/cp", "--", "/tmp/x", "/bin/x"],
            ["/bin/chmod", "-h", "--", "755", "/sbin/x"], ["/bin/mv", "--", "/usr/bin/true", "/tmp/true"],
        ] {
            #expect(try tier(args) == (.never, HelperPolicy.sipMessage), "\(args)")
        }
        let restricted = HelperPathFacts(path: "/Library/Apple/x", restricted: true)
        #expect(try tier(["/bin/rm", "-rf", "--", "/Library/Apple/x"], facts: ["/Library/Apple/x": restricted]).0 == .never)
        #expect(HelperPolicy.normalized("/System/Volumes/Data/Users/bob/x") == "/Users/bob/x")
    }

    /// Read from the disk: SF_RESTRICTED found on the item or a folder above it.
    @Test func sipPathsAreNeverRun() {
        for p in ["/System/Library/CoreServices", "/usr/bin/true", "/bin/ls"] {
            #expect(HelperPathFacts.read(p).restricted, "\(p)")
            #expect(policy.tier(of: HelperPathFacts.read(p), role: .remove).tier == .never)
        }
        #expect(!HelperPathFacts.read("/usr/local/x").restricted)
        #expect(!HelperPathFacts.read(NSTemporaryDirectory() + "x").restricted)
    }

    @Test func otherPeoplesHomesComeFromDirectoryServices() {
        let others = HomeDirectories.others(than: getuid())
        #expect(!others.contains { $0.path == ExistingPath.resolve(NSHomeDirectory()) })
        #expect(others.allSatisfy { $0.path.hasPrefix("/") && !$0.name.isEmpty })
    }

    // MARK: The prompt

    @Test func pathsAreShownSafely() {
        #expect(HelperDisplay.path("/Users/me/a\nrename b.txt") == "“/Users/me/a\\nrename b.txt”")
        #expect(HelperDisplay.path("/Users/me/\u{202E}txt.exe") == "“/Users/me/\\u{202e}txt.exe”")
        #expect(HelperDisplay.path("/x/a\u{200B}b\u{00A0}c d") == "“/x/a\\u{200b}b\\u{a0}c d”")
        // A name can't close its quote and seem to start another item.
        let forged = HelperDisplay.path("/x/x”, then delete “/private/etc/hosts")
        #expect(forged == "“/x/x\\u{201d}, then delete \\u{201c}/private/etc/hosts”")
        #expect(HelperDisplay.path("/x/a\"b") == "“/x/a\\u{22}b”")
        let long = "/Users/me/" + String(repeating: "d/", count: 2000) + "evil.plist"
        let shown = HelperDisplay.path(long)
        #expect(shown.count <= HelperDisplay.limit + 2 && shown.hasSuffix("/evil.plist”") && shown.contains("…"))
        let longName = "/x/" + String(repeating: "n", count: 10_000)
        #expect(HelperDisplay.path(longName).count <= HelperDisplay.limit + 2)
    }

    /// One protected item among many standard ones is named first, with its reason, never hidden in "and N more".
    @Test func aProtectedItemIsNeverHiddenInABatch() throws {
        let s = try Scratch()
        var requests = (0..<50).map { ["/bin/rm", "-rf", "--", s.path("app\($0)").path] }
        requests.insert(["/bin/rm", "-rf", "--", "/Library/LaunchDaemons/com.evil.plist"], at: 40)
        let auth = FakeAuthorizer { _ in .denied }
        let r = HelperRequests.perform(
            requests, authorization: form, handOver: [], caller: me, group: 20, home: s.url.path, authorizer: auth, policy: policy)
        #expect(r.cancelled && r.message == nil)
        let asked = try #require(auth.asked.first)
        #expect(auth.asked.count == 1 && asked.right == HelperRights.protected)
        #expect(
            asked.prompt.hasPrefix("Porpoise wants to delete “/Library/LaunchDaemons/com.evil.plist”, which changes what runs when your Mac starts"))
        #expect(asked.prompt.contains("and 50 other items") && asked.prompt.hasSuffix("This can change what runs when your Mac starts."))
    }

    @Test func aStandardPromptNamesThreeAndCounts() throws {
        let s = try Scratch()
        let trash = try s.folder(".Trash")
        let requests = (0..<5).map { i in ["/bin/mv", "--", s.path("a\(i)").path, trash.appendingPathComponent("a\(i)").path] }
        let auth = FakeAuthorizer { _ in .denied }
        _ = HelperRequests.perform(
            requests, authorization: form, handOver: [], caller: me, group: 20, home: s.url.path, authorizer: auth, policy: policy)
        let prompt = try #require(auth.asked.first?.prompt)
        #expect(auth.asked.first?.right == HelperRights.standard)
        #expect(prompt.hasPrefix("Porpoise wants to move to the Trash “\(HelperRequests.resolvedParent(s.path("a0").path))”"))
        #expect(prompt.hasSuffix("and 2 more."), "\(prompt)")
    }

    // MARK: Approval before anything runs

    @Test func invalidOrForeignAuthorizationRunsNothing() throws {
        let s = try Scratch()
        let item = try s.file("item", "x")
        let auth = FakeAuthorizer { _ in .invalid }
        let r = HelperRequests.perform(
            [["/bin/rm", "-rf", "--", item.path]], authorization: Data([1, 2]), handOver: [], caller: me, group: 20, home: s.url.path,
            authorizer: auth, policy: policy)
        #expect(r.message == HelperRequests.notVerified && !r.cancelled)
        #expect(FileManager.default.fileExists(atPath: item.path))
        // The system's own check: a malformed external form is refused before any dialog.
        #expect(SystemAuthorizer().authorize(Data([1, 2, 3]), right: HelperRights.standard, prompt: "x") == .invalid)
        #expect(SystemAuthorizer().authorize(Data(repeating: 0, count: 32), right: HelperRights.standard, prompt: "x") == .invalid)
    }

    @Test func deniedOrCancelledRunsNothing() throws {
        let s = try Scratch()
        let item = try s.file("item", "x")
        let r = HelperRequests.perform(
            [["/usr/bin/chflags", "-R", "nouchg,noschg", item.path], ["/bin/rm", "-rf", "--", item.path]], authorization: form, handOver: [],
            caller: me, group: 20, home: s.url.path, authorizer: FakeAuthorizer { _ in .denied }, policy: policy)
        #expect(r.cancelled)
        #expect(s.read("item") == "x")
    }

    /// The helper asks for the right the batch needs: an approval for standard doesn't cover a protected change.
    @Test func aStandardApprovalIsNotEnoughForAProtectedChange() throws {
        let s = try Scratch()
        let item = try s.file("Protected/item", "x")
        var p = policy
        p.configuration = [try #require(ExistingPath.resolve(s.path("Protected").path))]
        let auth = FakeAuthorizer { $0 == HelperRights.standard ? .granted : .denied }
        let r = HelperRequests.perform(
            [["/bin/rm", "-rf", "--", item.path]], authorization: form, handOver: [], caller: me, group: 20, home: s.url.path,
            authorizer: auth, policy: p)
        #expect(r.cancelled && auth.asked.map(\.right) == [HelperRights.protected])
        #expect(s.read("Protected/item") == "x")
    }

    @Test func approvedBatchesRunInOrderAndHandOverOnlyTheirOwnTrashedItems() throws {
        let s = try Scratch()
        let a = try s.file("a", "a"), b = try s.file("b", "b")
        let trash = try s.folder(".Trash")
        let auth = FakeAuthorizer()
        let r = HelperRequests.perform(
            [["/bin/mv", "--", a.path, trash.appendingPathComponent("a").path], ["/bin/rm", "-rf", "--", b.path]], authorization: form,
            handOver: [trash.appendingPathComponent("a").path, "/private/etc/hosts"], caller: getuid(), group: getgid(), home: s.url.path,
            authorizer: auth, policy: HelperPolicy(caller: getuid(), otherHomes: []))
        #expect(r == .done && auth.asked.count == 1)
        #expect(s.read(".Trash/a") == "a" && !FileManager.default.fileExists(atPath: b.path))
    }

    @Test func aRefusedRequestStopsTheBatchBeforeAsking() throws {
        let s = try Scratch()
        let auth = FakeAuthorizer()
        for requests in [[["/bin/rm", "-rf", "--", s.path("x").path], ["/bin/sh", "-c", "id"]], [["/bin/rm", "-rf", "--", "/System/Library/x"]]] {
            let r = HelperRequests.perform(
                requests, authorization: form, handOver: [], caller: me, group: 20, home: s.url.path, authorizer: auth, policy: policy)
            #expect(r.message != nil && !r.cancelled)
        }
        #expect(auth.asked.isEmpty)
    }

    /// M3: the tier that runs is the one of what was opened. A folder swapped for a link into a protected folder
    /// while the person approves (standard) is refused when the step opens it, and nothing there changes.
    @Test func aFolderSwappedDuringTheApprovalCantRaiseTheTier() throws {
        let s = try Scratch()
        try s.file("parent/item", "mine")
        let guarded = try s.file("Protected/item", "guarded")
        var p = HelperPolicy(caller: getuid(), otherHomes: [])
        p.configuration = [try #require(ExistingPath.resolve(s.path("Protected").path))]
        let auth = FakeAuthorizer { _ in
            try! FileManager.default.moveItem(at: s.path("parent"), to: s.path("saved"))
            try! FileManager.default.createSymbolicLink(at: s.path("parent"), withDestinationURL: s.path("Protected"))
            return .granted
        }
        let r = HelperRequests.perform(
            [["/bin/rm", "-rf", "--", s.path("parent/item").path]], authorization: form, handOver: [], caller: getuid(), group: getgid(),
            home: s.url.path, authorizer: auth, policy: p)
        #expect(auth.asked.map(\.right) == [HelperRights.standard])
        #expect(r.message?.hasPrefix(HelperFileOperations.changedTier.errorDescription!) == true)
        #expect(s.read("Protected/item") == "guarded" && FileManager.default.fileExists(atPath: guarded.path))
    }

    // MARK: The rights

    @Test func weakenedOrMissingRulesAreRefused() throws {
        let s = try Scratch()
        let auth = FakeAuthorizer()
        auth.intact = false
        let r = HelperRequests.perform(
            [["/bin/rm", "-rf", "--", s.path("x").path]], authorization: form, handOver: [], caller: me, group: 20, home: s.url.path,
            authorizer: auth, policy: policy)
        #expect(r.message == HelperRequests.rightsChanged && auth.asked.isEmpty)
        for right in [HelperRights.standard, HelperRights.protected] {
            #expect(HelperRights.isIntact(HelperRights.rule(right), as: right))
            #expect(!HelperRights.isIntact(nil, as: right))
            for (key, weaker) in [("class", "allow" as Any), ("timeout", 86_400), ("shared", true), ("allow-root", true), ("session-owner", true)] {
                var rule = HelperRights.rule(right)
                rule[key] = weaker
                #expect(!HelperRights.isIntact(rule, as: right), "\(right) \(key)")
            }
            var missing = HelperRights.rule(right)
            missing["authenticate-user"] = nil
            #expect(!HelperRights.isIntact(missing, as: right))
        }
        #expect(HelperRights.rule(HelperRights.protected)["timeout"] as? Int == 0)
        // The plist the install writes reads back as the rule.
        let data = Data(HelperRights.plist(HelperRights.standard).utf8)
        let back = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(HelperRights.isIntact(back, as: HelperRights.standard))
        // Not registered on this Mac (tests never install them): fails closed.
        if !FileManager.default.fileExists(atPath: PorpoiseHelperInfo.installedPlist) { #expect(!SystemAuthorizer().rulesIntact()) }
    }

    // MARK: Who's asking (H2)

    @Test func aConnectionWithoutAnAuditTokenIsRefused() {
        var checked = 0
        let ok: (Data, String) -> Bool = { _, _ in
            checked += 1; return true
        }
        #expect(!CodeSigning.accepts(auditToken: nil, requirement: "x", isIntact: ok))
        #expect(!CodeSigning.accepts(auditToken: Data([1, 2, 3]), requirement: "x", isIntact: ok))
        #expect(!CodeSigning.accepts(auditToken: Data(count: MemoryLayout<audit_token_t>.size), requirement: nil, isIntact: ok))
        #expect(checked == 0)
        #expect(CodeSigning.accepts(auditToken: Data(count: MemoryLayout<audit_token_t>.size), requirement: "x", isIntact: ok) && checked == 1)
        #expect(!CodeSigning.accepts(auditToken: Data(count: MemoryLayout<audit_token_t>.size), requirement: "x") { _, _ in false })
    }

    /// This test process, by its own audit token: checked through its program on disk (it isn't the helper's
    /// requirement, so it fails, as any other process does).
    @Test func anAuditTokenNamesTheProcess() throws {
        var token = audit_token_t()
        var size = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &size) }
        }
        try #require(kr == KERN_SUCCESS)
        let data = withUnsafeBytes(of: &token) { Data($0) }
        #expect(!CodeSigning.isIntact(auditToken: data, requirement: "identifier \"app.porpoise.Porpoise\" and anchor apple"))
    }
}
