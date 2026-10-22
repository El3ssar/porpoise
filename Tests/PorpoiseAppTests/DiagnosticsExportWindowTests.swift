import AppKit
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized) @MainActor struct DiagnosticsExportWindowTests {
    init() { _ = NSApplication.shared }

    @Test func showsExactlyWhatItSaves() throws {
        let store = DiagnosticStore()
        store.record(.transferFailed, failure: .notFound)
        store.record(.providerError, failure: .network)
        let window = DiagnosticsExportWindowController(export: try store.preview())
        defer { window.window?.close() }
        // Recorded after the window opened: neither shown nor saved.
        store.record(.helperFailed, failure: .unknown)
        #expect(window.textView.string == window.export.text)
        #expect(window.textView.string.contains("transfer.failed") && !window.textView.string.contains("helper.failed"))
        #expect(!window.textView.isEditable)
        let s = try Scratch()
        let file = s.path("Porpoise Diagnostics.json")
        try window.write(to: file)
        #expect(try Data(contentsOf: file) == window.export.data)
        // Replacing a file the save panel asked about.
        try Data("old".utf8).write(to: file)
        try window.write(to: file)
        #expect(try Data(contentsOf: file) == window.export.data)
    }
}
