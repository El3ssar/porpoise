import AppKit
import Testing

@testable import Porpoise

/// The shared chrome: capacity bars show how full a disk or account is with one table, in both appearances, and thin
/// progress tracks follow Reduce Motion. Set PORPOISE_CHROME_SHOTS to a folder to also get the renderings as PNGs.
@Suite(.serialized) @MainActor struct ChromeKitTests {
    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    /// `view` drawn offscreen in `appearance`.
    private func render(_ view: NSView, _ appearance: NSAppearance.Name, name: String) throws -> NSBitmapImageRep {
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["PORPOISE_CHROME_SHOTS"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        return rep
    }

    private func close(_ a: NSColor?, _ b: NSColor, _ appearance: NSAppearance.Name) -> Bool {
        var expected = b
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { expected = b.usingColorSpace(.deviceRGB) ?? b }
        guard let a = a?.usingColorSpace(.deviceRGB) else { return false }
        return abs(a.redComponent - expected.redComponent) < 0.06 && abs(a.greenComponent - expected.greenComponent) < 0.06
            && abs(a.blueComponent - expected.blueComponent) < 0.06
    }

    /// One table: under 80 % the accent, then amber, red past 95 %, whatever draws the bar.
    @Test func capacityBarsUseOneThresholdTable() throws {
        #expect(StorageCapacity(used: 50, total: 100).severity == .normal)
        #expect(StorageCapacity(used: 85, total: 100).severity == .nearlyFull)
        #expect(StorageCapacity(used: 97, total: 100).severity == .full)
        #expect(StorageCapacity(free: 8, total: 100).severity == .nearlyFull)
        #expect(StorageCapacity(used: 1, total: 0).fraction == 0)
        #expect(StorageCapacity(free: 750, total: 1000).summary.hasSuffix("(25% used)"))
        for (label, appearance) in Self.appearances {
            for (fraction, severity) in [(0.5, StorageCapacity.Severity.normal), (0.85, .nearlyFull), (0.97, .full)] {
                let bar = CapacityBarView(fraction: fraction)
                bar.frame = CGRect(x: 0, y: 0, width: 200, height: 4)
                let rep = try render(bar, appearance, name: "capacity-\(label)-\(Int(fraction * 100))")
                #expect(close(rep.colorAt(x: 40, y: 2), CapacityBar.color(severity), appearance), "\(label) \(fraction)")
            }
        }
    }

    /// The band stands still with Reduce Motion, and moves without it; the fill shows how far the work got.
    @Test func thinProgressFollowsReduceMotion() throws {
        let reduces = Animator.reducesMotion
        defer { Animator.reducesMotion = reduces }
        for (label, appearance) in Self.appearances {
            for reduce in [true, false] {
                Animator.reducesMotion = { reduce }
                let bar = ThinProgressView()
                bar.frame = CGRect(x: 0, y: 0, width: 200, height: 4)
                bar.isIndeterminate = true
                bar.layoutSubtreeIfNeeded()
                let band = try #require(bar.subviews.first?.subviews.first)
                #expect((band.layer?.animation(forKey: "indeterminate") != nil) == !reduce, "\(label) reduce \(reduce)")
                bar.isIndeterminate = false
                bar.fraction = 0.4
                bar.layoutSubtreeIfNeeded()
                if reduce { #expect(abs(band.frame.width - 80) < 0.5) }
                #expect(bar.accessibilityValueDescription() == "40 percent")
                _ = try render(bar, appearance, name: "progress-\(label)-\(reduce ? "still" : "moving")")
            }
        }
    }
}
