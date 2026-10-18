import AppKit
import Testing

@testable import Porpoise

/// Reveal requests from other apps ("Show in Finder", Archive Utility after unpacking) land on the item, with synthesized
/// Apple Events shaped like the ones macOS delivers to the NSFileViewer app.
@MainActor @Suite(.serialized) struct RevealRequestTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("reveal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func event(_ eventClass: String, _ eventID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: SystemIntegration.fourCC(eventClass), eventID: SystemIntegration.fourCC(eventID), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// The reopen macOS sends when a sandboxed app reveals: no items, only the sender's quarantine info.
    private func sandboxedReopen(from app: String) throws -> NSAppleEventDescriptor {
        let e = event("aevt", "rapp")
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["LSQuarantineAgentBundleIdentifier": app, "LSQuarantineAgentName": "Archive Utility"], format: .binary, options: 0)
        e.setParam(
            NSAppleEventDescriptor(descriptorType: SystemIntegration.fourCC("qtnd"), data: info)!, forKeyword: SystemIntegration.fourCC("qtnp"))
        return e
    }

    /// An archive LaunchServices opened at `date`, and the folder unpacked from it (added now).
    @discardableResult private func unpacked(openedAt date: Date? = Date().addingTimeInterval(-5)) throws -> URL {
        let zip = folder.appendingPathComponent("Photos.zip")
        try Data("PK".utf8).write(to: zip)
        if let date {
            var ts = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
            #expect(setxattr(zip.path, "com.apple.lastuseddate#PS", &ts, MemoryLayout<timespec>.size, 0, 0) == 0)
            #expect(abs(RevealInference.lastUsed(zip)!.timeIntervalSince(date)) < 1)
        }
        let out = folder.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    private func same(_ a: URL?, _ b: URL) -> Bool { a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }

    // Unsandboxed apps' 'misc'/'mvis' and Finder's 'FNDR'/'show' carry the items: all of them are revealed.
    @Test func makeVisibleEventsRevealTheirItems() {
        let a = folder.appendingPathComponent("a.txt"), b = folder.appendingPathComponent("b.txt")
        let mvis = event("misc", "mvis")
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: a), at: 1)
        list.insert(NSAppleEventDescriptor(fileURL: b), at: 2)
        mvis.setParam(list, forKeyword: keyDirectObject)
        let show = event("FNDR", "show")
        show.setParam(NSAppleEventDescriptor(fileURL: b), forKeyword: keyDirectObject)

        let handler = SystemIntegration.RevealHandler()
        var revealed: [[URL]] = []
        handler.reveal = { revealed.append($0) }
        handler.handle(mvis, reply: NSAppleEventDescriptor.null())
        handler.handle(show, reply: NSAppleEventDescriptor.null())
        handler.handle(event("misc", "mvis"), reply: NSAppleEventDescriptor.null())  // nothing to show: ignored
        #expect(revealed == [[a, b], [b]])
    }

    // Archive Utility (sandboxed) reveals with a bare reopen: the folder it just unpacked beside the archive is revealed.
    @Test func archiveUtilityReopenRevealsWhatItUnpacked() throws {
        let out = try unpacked()
        let reopen = try sandboxedReopen(from: RevealInference.archiveUtility)
        #expect(RevealInference.sender(of: reopen) == RevealInference.archiveUtility)
        #expect(same(RevealInference.reopenItem(reopen, folders: [folder]), out))
        // Even with the unpacked item elsewhere than the archive (Archive Utility's "Save expanded files" setting).
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Photos.zip"))
        #expect(same(RevealInference.reopenItem(reopen, folders: [folder]), out))
        // Long after, nothing is: the reopen just reopens.
        #expect(RevealInference.reopenItem(reopen, folders: [folder], now: Date().addingTimeInterval(120)) == nil)
    }

    // Other reopens (the Dock, other sandboxed apps) aren't reveals, even right after something was unpacked.
    @Test func otherReopensRevealNothing() throws {
        try unpacked()
        let dock = event("aevt", "rapp")
        dock.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: SystemIntegration.fourCC("frnt"))
        dock.setAttribute(NSAppleEventDescriptor(int32: getpid()), forKeyword: keySenderPIDAttr)  // its own pid says nothing
        #expect(RevealInference.sender(of: dock) == nil)
        #expect(RevealInference.reopenItem(dock, folders: [folder]) == nil)
        #expect(RevealInference.reopenItem(try sandboxedReopen(from: "com.apple.Safari"), folders: [folder]) == nil)
        // Only reopens: a launch from Archive Utility goes through launchItem.
        #expect(RevealInference.reopenItem(event("aevt", "oapp"), folders: [folder]) == nil)
        #expect(!AppDelegate.shared.revealUnpacked(after: dock) && !AppDelegate.shared.revealUnpacked(after: nil))
    }

    // Cold launch: LaunchServices sends the launch, so only the unpacked item beside the archive just opened (or Archive
    // Utility still running) tells it was a reveal; then it is shown instead of the last session.
    @Test func launchRevealsOnlyWhatWasJustUnpacked() throws {
        let out = try unpacked()
        #expect(same(RevealInference.launchItem(folders: [folder], archiveUtilityRunning: false), out))
        #expect(RevealInference.launchItem(folders: [folder], archiveUtilityRunning: false, now: Date().addingTimeInterval(120)) == nil)
        // Hidden items aren't what was unpacked.
        let hidden = folder.appendingPathComponent(".partial", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        #expect(same(RevealInference.launchItem(folders: [folder], archiveUtilityRunning: false), out))
    }

    @Test func launchWithoutAnOpenedArchiveRestoresTheSession() throws {
        let out = try unpacked(openedAt: nil)
        #expect(RevealInference.launchItem(folders: [folder], archiveUtilityRunning: false) == nil)
        #expect(same(RevealInference.launchItem(folders: [folder], archiveUtilityRunning: true), out))
        // An archive opened after the item came didn't produce it.
        let zip = folder.appendingPathComponent("Photos.zip")
        var ts = timespec(tv_sec: Int(Date().timeIntervalSince1970) + 60, tv_nsec: 0)
        setxattr(zip.path, "com.apple.lastuseddate#PS", &ts, MemoryLayout<timespec>.size, 0, 0)
        #expect(RevealInference.launchItem(folders: [folder], archiveUtilityRunning: false) == nil)
    }

    @Test func foldersAreTheUsualPlacesThenTheShownOnes() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let found = RevealInference.folders(shown: [folder, downloads, URL(string: "sftp://me@host/home/me/")!, folder])
        #expect(found.first == downloads && found.last == folder)
        #expect(found.filter { $0 == folder }.count == 1 && found.filter { $0 == downloads }.count == 1 && found.allSatisfy(\.isFileURL))
    }
}
