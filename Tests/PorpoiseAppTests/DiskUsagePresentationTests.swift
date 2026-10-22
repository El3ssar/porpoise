import AppKit
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized) @MainActor struct DiskUsagePresentationTests {
    init() { _ = NSApplication.shared }

    @Test func theFooterSaysWhereFromTheFolderScanned() {
        let root = URL(fileURLWithPath: "/Users/u/Demo")
        #expect(DiskUsageWindow.place(of: root, in: [root]) == "Demo")
        #expect(DiskUsageWindow.place(of: root.appendingPathComponent("Photos/2024"), in: [root]) == "Demo › Photos › 2024")
        #expect(DiskUsageWindow.place(of: URL(fileURLWithPath: "/Users/u/Demo2"), in: [root]) == "Demo2")
        #expect(DiskUsageWindow.place(of: nil, in: [root]) == "Selection")
        #expect(DiskUsageWindow.place(of: URL(fileURLWithPath: "/Library"), in: [URL(fileURLWithPath: "/")]) == "/ › Library")
    }

    @Test func zeroCountsAreLeftOut() {
        let quiet = DiskUsageWindow.summary(place: "Demo", logical: 0, allocated: 0, files: 1, hardLinkAliases: 0, errors: 0)
        #expect(quiet.hasPrefix("Demo · ") && quiet.hasSuffix(" · 1 file"))
        #expect(!quiet.contains("alias") && !quiet.contains("error"))
        let busy = DiskUsageWindow.summary(place: "Demo", logical: 0, allocated: 0, files: 20, hardLinkAliases: 2, errors: 1)
        #expect(busy.hasSuffix("20 files · 2 hard-link aliases · 1 error"))
    }

    @Test func tilesAreColoredByWhatTheyHold() {
        typealias Kind = DiskTreemapView.Kind
        #expect(Kind(name: "Photos", folder: true) == .folder)
        #expect(Kind(name: "IMG_1.jpg", folder: false) == .image)
        #expect(Kind(name: "clip.mp4", folder: false) == .video)
        #expect(Kind(name: "tone.m4a", folder: false) == .audio)
        #expect(Kind(name: "Backup.zip", folder: false) == .archive)
        #expect(Kind(name: "disk.img", folder: false) == .archive)
        #expect(Kind(name: "Roadmap.pdf", folder: false) == .document)
        #expect(Kind(name: "notes.txt", folder: false) == .document)
        #expect(Kind(name: "README", folder: false) == .other)
        // Each kind its own color.
        #expect(Set(Kind.allCases.map { $0.color.hexString }).count == Kind.allCases.count)
    }

    @Test func theErrorsButtonShowsOnlyWithErrors() throws {
        let scratch = try Scratch()
        let window = DiskUsageWindow(roots: [scratch.url])
        defer { window.close() }
        #expect(window.errorsButton.isHidden)
        window.errors = ["/x: Permission denied"]
        #expect(!window.errorsButton.isHidden && window.errorsButton.title == "Errors (1)…")
        window.errors = []
        #expect(window.errorsButton.isHidden)
    }
}
