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
            markOpened(zip, at: date)
            #expect(abs(RevealInference.lastUsed(zip)!.timeIntervalSince(date)) < 1)
        }
        let out = folder.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    /// What LaunchServices records when it opens a document.
    private func markOpened(_ u: URL, at date: Date) {
        var ts = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        #expect(setxattr(u.path, "com.apple.lastuseddate#PS", &ts, MemoryLayout<timespec>.size, 0, 0) == 0)
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
        // Long after, nothing is: the reopen just reopens.
        #expect(RevealInference.reopenItem(reopen, folders: [folder], now: Date().addingTimeInterval(120)) == nil)
    }

    // Nothing is guessed: without an archive opened before it, next to it, a just-added item isn't revealed.
    @Test func onlyAnItemUnpackedNextToItsArchiveIsRevealed() throws {
        let reopen = try sandboxedReopen(from: RevealInference.archiveUtility)
        let zip = folder.appendingPathComponent("Photos.zip")
        // No archive was opened (a download that just finished, say).
        try unpacked(openedAt: nil)
        #expect(RevealInference.reopenItem(reopen, folders: [folder]) == nil)
        #expect(RevealInference.launchItem(folders: [folder]) == nil)
        // The archive was opened after the item came, or long before.
        for opened in [Date().addingTimeInterval(60), Date().addingTimeInterval(-7200)] {
            markOpened(zip, at: opened)
            #expect(RevealInference.reopenItem(reopen, folders: [folder]) == nil)
            #expect(RevealInference.launchItem(folders: [folder]) == nil)
        }
        // A document opened there isn't an archive.
        try FileManager.default.removeItem(at: zip)
        let doc = folder.appendingPathComponent("Notes.txt")
        try Data("hi".utf8).write(to: doc)
        markOpened(doc, at: Date().addingTimeInterval(-5))
        #expect(RevealInference.reopenItem(reopen, folders: [folder]) == nil)
        // An archive in another folder doesn't count either.
        let other = folder.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let elsewhere = other.appendingPathComponent("Photos.zip")
        try Data("PK".utf8).write(to: elsewhere)
        markOpened(elsewhere, at: Date().addingTimeInterval(-5))
        #expect(RevealInference.unpackedItem(in: [folder], within: 30) == nil)
    }

    // Other events (the Dock's reopen, other sandboxed apps, an explicit open) never get a guessed item.
    @Test func otherEventsRevealNothing() throws {
        try unpacked()
        let dock = event("aevt", "rapp")
        dock.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: SystemIntegration.fourCC("frnt"))
        dock.setAttribute(NSAppleEventDescriptor(int32: getpid()), forKeyword: keySenderPIDAttr)  // its own pid says nothing
        #expect(RevealInference.sender(of: dock) == nil)
        #expect(RevealInference.reopenItem(dock, folders: [folder]) == nil)
        #expect(RevealInference.reopenItem(try sandboxedReopen(from: "com.apple.Safari"), folders: [folder]) == nil)
        // An 'odoc' names its items itself (application(_:open:)), even one Archive Utility sent; a launch goes
        // through launchItem.
        for (c, id) in [("aevt", "odoc"), ("aevt", "oapp")] {
            let e = event(c, id)
            e.setParam(
                try sandboxedReopen(from: RevealInference.archiveUtility).paramDescriptor(forKeyword: SystemIntegration.fourCC("qtnp"))!,
                forKeyword: SystemIntegration.fourCC("qtnp"))
            #expect(RevealInference.reopenItem(e, folders: [folder]) == nil)
            #expect(!AppDelegate.shared.revealUnpacked(after: e))
        }
        #expect(!AppDelegate.shared.revealUnpacked(after: dock) && !AppDelegate.shared.revealUnpacked(after: nil))
    }

    // Cold launch: LaunchServices sends the launch, so only an item unpacked seconds ago beside the archive just opened
    // tells it was a reveal; then it is shown instead of the last session.
    @Test func launchRevealsOnlyWhatWasJustUnpacked() throws {
        let out = try unpacked()
        #expect(same(RevealInference.launchItem(folders: [folder]), out))
        // Seconds, not the half minute a running Porpoise allows.
        #expect(RevealInference.launchItem(folders: [folder], now: Date().addingTimeInterval(20)) == nil)
        // Hidden items aren't what was unpacked.
        let hidden = folder.appendingPathComponent(".partial", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        #expect(same(RevealInference.launchItem(folders: [folder]), out))
    }

    @Test func foldersAreTheUsualPlacesThenTheShownOnes() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let found = RevealInference.folders(shown: [folder, downloads, URL(string: "sftp://me@host/home/me/")!, folder])
        #expect(found.first == downloads && found.last == folder)
        #expect(found.filter { $0 == folder }.count == 1 && found.filter { $0 == downloads }.count == 1 && found.allSatisfy(\.isFileURL))
    }
}
