import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Properties lines each label up with its value: on the value's first baseline (a field, a pop-up, wrapped text), or
/// on its middle when it has no text (the tag dots). Labels used to sit at the row's top, a few points off.
@MainActor @Suite(.serialized, .isolatedSettings) struct PropertiesAlignmentTests {
    init() { _ = NSApplication.shared }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func labelsSitOnTheirValuesBaselines() async throws {
        let scratch = try Scratch(), file = try scratch.file("photo.txt", "bytes")
        let item = try #require(FileItem.load(file))
        let properties = PropertiesWindow(urls: [file], items: [item])
        try #require(await eventually { !properties.localItems.isEmpty })
        let window = try #require(properties.window)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let labels = descendants(try #require(window.contentView)).compactMap { $0 as? NSTextField }
            .filter { $0.alignment == .right && $0.stringValue.hasSuffix(":") }
        #expect(labels.count >= 5)
        var checked = 0
        for label in labels {
            guard let row = label.superview, let value = row.subviews.first(where: { $0 !== label }) else { continue }
            let l = label.frame.maxY - label.firstBaselineOffsetFromTop
            if value is NSControl {
                let v = value.frame.maxY - value.firstBaselineOffsetFromTop
                #expect(abs(l - v) <= 1, "\(label.stringValue) is \(l - v) pt off its value's baseline")
            } else {
                #expect(abs(label.frame.midY - value.frame.midY) <= 1, "\(label.stringValue) is off its value's middle")
            }
            checked += 1
        }
        #expect(checked == labels.count)
    }
}
