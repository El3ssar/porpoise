import AppKit
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct AirDropGlyphTests {
    private func mask(_ image: NSImage) throws -> [Bool] {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        return (0..<64).flatMap { y in (0..<64).map { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 } }
    }

    @Test func nativeArtworkMatchesFinderAndMissingSystemGlyphUsesVisiblePortableFallback() throws {
        _ = NSApplication.shared
        let reference = try #require(Icons.systemAirDropGlyph)
        let expected = try mask(reference)
        #expect(expected.contains(true) && expected.contains(false))
        for theme in ["Native macOS", Icons.nativeColourTheme] {
            var preferences = Settings.shared.appearancePreferences
            preferences.iconTheme = theme
            Settings.shared.appearancePreferences = preferences
            for selected in [false, true] {
                let native = try #require(Icons.shared.image("airdrop", size: 32, selected: selected))
                #expect(try mask(native) == expected)
            }
        }
        let fallback = try #require(Icons.shared.airDropImage(size: 32, selected: false, systemGlyph: nil))
        let fallbackMask = try mask(fallback)
        #expect(fallbackMask.contains(true) && fallbackMask != expected)
        var preferences = Settings.shared.appearancePreferences
        preferences.iconTheme = "Breeze"
        Settings.shared.appearancePreferences = preferences
        let portable = try #require(Icons.shared.image("airdrop", size: 32))
        #expect(try mask(portable) == fallbackMask)
    }

    @Test func comparisonCapturesUseFinderSystemResourceBesideNativeAndPortableIcons() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PORPOISE_SHARING_CAPTURES"] else { return }
        let app = NSApplication.shared, previous = NSApplication.shared.appearance
        defer { app.appearance = previous; Theme.lookChanged() }
        app.setActivationPolicy(.prohibited)
        let source = try #require(Icons.systemAirDropGlyph)
        for look in [AppearanceChoice.light, .dark] {
            Settings.shared.appearance = look; app.appearance = Theme.appearance
            var preferences = Settings.shared.appearancePreferences
            preferences.iconTheme = "Native macOS"; Settings.shared.appearancePreferences = preferences
            let native = try #require(Icons.shared.image("airdrop", size: 48))
            preferences.iconTheme = "Breeze"; Settings.shared.appearancePreferences = preferences
            let portable = try #require(Icons.shared.image("airdrop", size: 48))
            let reference = try #require(source.copy() as? NSImage); reference.isTemplate = true
            let columns = NSStackView(); columns.spacing = 24
            for (title, image, template) in [
                ("Finder system glyph", reference, true), ("Porpoise · Native macOS", native, false), ("Porpoise · Breeze", portable, false),
            ] {
                let icon = NSImageView(image: image); icon.imageScaling = .scaleProportionallyUpOrDown
                if template { icon.contentTintColor = Theme.windowText }
                icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
                let column = NSStackView(views: [icon, NSTextField(labelWithString: title)])
                column.orientation = .vertical; column.spacing = 16; columns.addArrangedSubview(column)
            }
            let note = NSTextField(labelWithString: "Reference loaded from macOS; no Apple artwork is bundled with Porpoise.")
            note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 12)
            let stack = NSStackView(views: [columns, note]); stack.orientation = .vertical; stack.spacing = 28
            let window = NSWindow(
                contentRect: NSRect(x: 180, y: 180, width: 660, height: 230), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "AirDrop glyph comparison"; window.appearance = Theme.appearance
            window.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
            ])
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.level = .floating
            window.orderFrontRegardless(); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            let captured = try #require(WindowCapture.image(of: window.windowNumber))
            let png = try #require(NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("airdrop-glyphs-\(look.rawValue).png"))
        }
    }
}
