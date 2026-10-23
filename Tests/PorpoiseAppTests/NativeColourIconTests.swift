import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import Testing
import UniformTypeIdentifiers

@testable import Porpoise

@Suite(.serialized) @MainActor struct NativeColourIconTests {
    init() { _ = NSApplication.shared }

    private func item(_ name: String, local: Bool = false, folder: Bool = false, type: String? = nil) -> FileItem {
        FileItem(
            url: local ? URL(fileURLWithPath: "/tmp/" + name) : URL(string: "sftp://demo/" + name)!,
            name: name, isDirectory: folder, contentType: type)
    }

    private func pixels(_ image: NSImage, dark: Bool = false, size: Int = 64) -> Data {
        var data = Data()
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let rep = Icons.nativeBitmap(image, pixels: size)
            data = Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
        }
        return data
    }

    @Test func familiesUseTypesAndProviderMetadata() {
        let examples: [(String, Icons.NativeFamily)] = [
            ("a.pdf", .pdf), ("a.docx", .word), ("a.xlsx", .sheet), ("a.csv", .sheet), ("a.pptx", .slides),
            ("a.png", .image), ("a.mp4", .video), ("a.mp3", .audio), ("a.zip", .archive), ("a.dmg", .archive),
            ("a.py", .code), ("a.json", .code), ("a.md", .prose), ("a.txt", .prose), ("a.unknown-porpoise", .unknown),
        ]
        for (name, family) in examples {
            #expect(Icons.nativeFamily(for: item(name)) == family, "\(name)")
            #expect(Icons.nativeFamily(for: item(name, local: true)) == family, "\(name)")
        }
        #expect(Icons.nativeFamily(for: item("Report", type: "com.google.apps.spreadsheet")) == .sheet)
        #expect(Icons.nativeFamily(for: item("Report", type: "com.google.apps.document")) == .word)
        #expect(Icons.nativeFamily(for: item("Report", type: "com.google.apps.presentation")) == .slides)
        #expect(Icons.nativeFamily(for: item("NoExtension", type: UTType.pdf.identifier)) == .pdf)
    }

    @Test(.isolatedSettings) func defaultAndFoldersStayNative() {
        #expect(Settings.shared.appearancePreferences.iconTheme == "Native macOS")
        let folder = item("Demo", folder: true)
        let before = pixels(Icons.shared.image(for: folder, size: 64))
        Settings.shared.updateAppearance { $0.iconTheme = Icons.nativeColourTheme }
        #expect(pixels(Icons.shared.image(for: folder, size: 64)) == before)
    }

    @Test(.isolatedSettings) func colouredArtworkPassesThroughAndNeutralArtworkChanges() {
        for ext in ["swift", "html", "rtf", "pdf", "csv", "zip"] {
            let file = item("Demo." + ext)
            let original = Icons.shared.image(for: file, size: 64)
            let coloured = Icons.hasNativeColour(NSWorkspace.shared.icon(for: Icons.nativeType(for: file)))
            Settings.shared.updateAppearance { $0.iconTheme = Icons.nativeColourTheme }
            let result = Icons.shared.image(for: file, size: 64)
            #expect((pixels(result) == pixels(original)) == coloured, "\(ext)")
            Settings.shared.updateAppearance { $0.iconTheme = "Native macOS" }
        }
    }

    @Test(.isolatedSettings) func cacheKeepsSizeLabelAndLookSeparate() {
        Settings.shared.updateAppearance { $0.iconTheme = Icons.nativeColourTheme }
        let file = item("Demo.pdf")
        let first = Icons.shared.image(for: file, size: 64)
        #expect(first === Icons.shared.image(for: file, size: 64))
        #expect(first === Icons.shared.image(for: file, size: 64, selected: true))
        #expect(first !== Icons.shared.image(for: file, size: 32))
        #expect(pixels(first) != pixels(first, dark: true))
        #expect(pixels(first) != pixels(Icons.shared.image(for: item("Demo.csv"), size: 64)))
    }

    @Test(.isolatedSettings) func localAndRemoteMatchAndCustomArtworkIsPreserved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let local = FileItem(url: url, name: url.lastPathComponent, isDirectory: false)
        Settings.shared.updateAppearance { $0.iconTheme = Icons.nativeColourTheme }
        let localImage = Icons.shared.image(for: local, size: 64)
        let remoteImage = Icons.shared.image(for: item("Demo.pdf"), size: 64)
        #expect(pixels(localImage) == pixels(remoteImage))
        #expect(localImage === remoteImage)
        let custom = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.gray.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 8, dy: 8)).fill()
            return true
        }
        #expect(NSWorkspace.shared.setIcon(custom, forFile: url.path, options: []))
        Settings.shared.updateAppearance { $0.iconTheme = "Native macOS" }
        let before = pixels(Icons.shared.image(for: local, size: 64))
        Settings.shared.updateAppearance { $0.iconTheme = Icons.nativeColourTheme }
        #expect(pixels(Icons.shared.image(for: local, size: 64)) == before)
    }

    @Test func smallBandHasNoLabelAndKeepsTransparentBorder() throws {
        let source = NSWorkspace.shared.icon(for: .pdf)
        for size in [16, 32, 64, 128] {
            let a = Icons.colourNative(source, size: CGFloat(size), label: "PDF", family: .pdf, dark: false)
            let b = Icons.colourNative(source, size: CGFloat(size), label: "VERYLONGEXTENSION", family: .pdf, dark: false)
            #expect((pixels(a, size: size) == pixels(b, size: size)) == (size < 32))
            let rep = Icons.nativeBitmap(a, pixels: size)
            #expect(try #require(rep.colorAt(x: 0, y: size / 2)).alphaComponent == 0)
        }
        for family in Icons.NativeFamily.allCases {
            #expect(family.color(dark: true).brightnessComponent > family.color(dark: false).brightnessComponent)
        }
    }
}
