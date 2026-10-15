import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The helper in a test run: everything that would reach it (or an administrator dialog) answers "no" at once.
/// Nothing is installed, no connection is made and nothing runs as root.
@Suite(.isolatedSettings) struct PrivilegedHelperTestRunTests {
    @Test func nothingReachesTheHelper() {
        #expect(Settings.isTesting)
        #expect(!PrivilegedHelper.enable())
        #expect(!PrivilegedHelper.ping(timeout: 0.1))
        #expect(!PrivilegedHelper.checkFullDiskAccess(timeout: 0.1))
        // Not this test binary's helper: there is no bundled one to compare an installed one with.
        #expect(!PrivilegedHelper.isEnabled)
        #expect(!PrivilegedHelper.ensureOn())
    }

    @Test func runIsUnavailable() {
        guard case .unavailable(let why) = PrivilegedHelper.run([["/bin/chmod", "644", "/nonexistent"]]) else {
            Issue.record("a test run must not use the helper")
            return
        }
        #expect(why.contains("Test instances"))
        guard case .unavailable = PrivilegedHelper.run([], bestEffort: ["/bin/chmod"]) else {
            Issue.record("a test run must not use the helper")
            return
        }
    }

    @Test func takingOwnershipDoesNothing() throws {
        let s = try Scratch()
        let f = try s.file("trashed.txt", "x")
        let before = try FileManager.default.attributesOfItem(atPath: f.path)[.ownerAccountID] as? NSNumber
        PrivilegedHelper.takeOwnership(of: [])
        PrivilegedHelper.takeOwnership(of: [f.path])
        #expect(try FileManager.default.attributesOfItem(atPath: f.path)[.ownerAccountID] as? NSNumber == before)
        #expect(s.read("trashed.txt") == "x")
    }

    @Test func loginItemsMigrationIsSkipped() {
        PrivilegedHelper.migrateFromLoginItems()
        #expect(Settings.store.object(forKey: "helperMigrated") == nil)
    }
}

/// The App Management check against a folder of "apps" made here (never /Applications, never another real app).
@Suite(.isolatedSettings, .serialized) struct AppManagementCheckTests {
    /// A program signed with a developer team (Xcode's), if this Mac has one; App Management only checks those.
    static let teamSignedTool: String? = {
        let candidates = [
            ProcessInfo.processInfo.environment["DEVELOPER_DIR"].map { $0 + "/usr/bin/xcodebuild" },
            "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
        ]
        for case let path? in candidates where FileManager.default.isExecutableFile(atPath: path) {
            guard let r = try? Shell.run("/usr/bin/codesign", ["-dv", path], timeout: 30) else { continue }
            if r.err.split(separator: "\n").contains(where: { $0.hasPrefix("TeamIdentifier=") && !$0.hasSuffix("not set") }) {
                return path
            }
        }
        return nil
    }()

    func check(in folder: URL) -> PrivacyAccess.AccessState? {
        PrivacyAccess.applicationsFolder = folder.path
        defer { PrivacyAccess.applicationsFolder = "/Applications" }
        return PrivacyAccess.checkAppManagement()
    }

    @Test func noAppToCheckAgainst() throws {
        let s = try Scratch()
        #expect(check(in: s.path("missing")) == nil)
        #expect(check(in: s.url) == nil)
        // Not apps, unsigned, or signed without a team (ad hoc): none of them is checked.
        _ = try s.file("notes.txt", "x")
        _ = try s.file("Plain.app/Contents/Info.plist", "<plist/>")
        _ = try s.folder("Adhoc.app/Contents/MacOS")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: s.path("Adhoc.app/Contents/MacOS/Adhoc").path)
        _ = try Shell.run("/usr/bin/codesign", ["--force", "-s", "-", s.path("Adhoc.app/Contents/MacOS/Adhoc").path], timeout: 30)
        #expect(check(in: s.url) == nil)
        #expect(Settings.store.object(forKey: "appManagement") == nil)  // nothing checked, nothing kept
        #expect(s.listing().sorted() == ["Adhoc.app", "Plain.app", "notes.txt"])
    }

    /// A developer-signed program named like an app: it is picked, but nothing can be created inside it (it's a
    /// file), so the answer is unknown, and it's kept.
    @Test(.enabled(if: teamSignedTool != nil, "no developer-signed program (Xcode) on this Mac"))
    func anAppThatCantBeProbedIsUnknown() throws {
        let tool = try #require(Self.teamSignedTool)
        let s = try Scratch()
        try FileManager.default.copyItem(atPath: tool, toPath: s.path("Signed.app").path)
        Settings.store.set("allowed", forKey: "appManagement")
        #expect(check(in: s.url) == .unknown)
        #expect(Settings.store.string(forKey: "appManagement") == "unknown")
        #expect(s.listing() == ["Signed.app"])
    }

    /// Without the system's permission list, the last answer kept is the state (unknown before any check).
    @Test func stateFallsBackToTheLastAnswer() {
        let real = "/Library/Application Support/com.apple.TCC/TCC.db"
        // Another suite may point the list at a database of its own meanwhile: only judge a run that used the real one.
        let usesReal = { PrivacyAccess.tccDatabase == real }
        let own = PrivacyAccess.tccAuthValue(service: "kTCCServiceSystemPolicyAppBundles")
        for stored in [nil, "denied", "allowed", "nonsense"] {
            Settings.store.set(stored, forKey: "appManagement")
            let before = usesReal()
            let state = PrivacyAccess.appManagementState
            guard before, usesReal(), own == nil else { continue }
            #expect(state == (stored.flatMap(PrivacyAccess.AccessState.init(rawValue:)) ?? .unknown), "\(stored ?? "nil")")
        }
    }
}

/// The last known Local Network answer. (Asking, which browses and may show macOS's prompt, is never done here.)
@Suite(.isolatedSettings) struct LocalNetworkAccessTests {
    @Test func isAllowedIsTheLastAnswer() {
        let access = LocalNetworkAccess.shared
        #expect(!access.isAllowed)
        Settings.store.set(true, forKey: "localNetworkAllowed")
        #expect(access.isAllowed)
        Settings.store.set(false, forKey: "localNetworkAllowed")
        #expect(!access.isAllowed)
    }
}

@Suite struct SettingsEnumTitleTests {
    @Test func appearanceTitles() {
        #expect(AppearanceChoice.allCases.map(\.title) == ["Match macOS", "Light", "Dark"])
        #expect(ContextMenuEntry.allCases.filter { !$0.defaultOn } == [.deleteAlongsideTrash, .copyMoveTo, .revealInFinder])
        #expect(Set(ContextMenuEntry.allCases.map(\.title)).count == ContextMenuEntry.allCases.count)
    }
}
