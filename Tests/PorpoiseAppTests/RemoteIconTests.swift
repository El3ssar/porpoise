import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import Testing
import UniformTypeIdentifiers

@testable import Porpoise

/// Cloud and remote items have no file on this Mac: the Native theme shows the icon of their type, not the blank page
/// macOS answers for a path that doesn't exist (operator report, 2026-10-23).
@Suite(.serialized) @MainActor struct RemoteIconTests {
    init() { _ = NSApplication.shared }

    /// `image` drawn at 32 × 32 px, as RGBA bytes.
    private func pixels(_ image: NSImage) -> [UInt8] {
        let ctx = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            image.draw(in: CGRect(x: 0, y: 0, width: 32, height: 32))
            NSGraphicsContext.restoreGraphicsState()
        }
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 32 * 32 * 4))
    }

    private func remote(_ name: String, folder: Bool = false, scheme: String = "dropbox", contentType: String? = nil) -> FileItem {
        FileItem(url: URL(string: "\(scheme)://account/\(name)")!, name: name, isDirectory: folder, contentType: contentType)
    }

    @Test func remoteItemsResolveToTheirType() {
        #expect(Icons.nativeType(for: remote("Projects", folder: true)) == .folder)
        #expect(Icons.nativeType(for: remote("Projects.v2", folder: true, scheme: "sftp")) == .folder)
        for (name, type): (String, UTType) in [
            ("a.pdf", .pdf), ("b.jpg", .jpeg), ("c.mp4", .mpeg4Movie), ("d.zip", .zip), ("e.swift", .swiftSource), ("f.mp3", .mp3),
        ] {
            #expect(Icons.nativeType(for: remote(name)) == type, "\(name)")
        }
        #expect(Icons.nativeType(for: remote("Makefile", scheme: "ftp")) == .data)
        #expect(Icons.nativeType(for: remote("x.porpoise-unknown-ext", scheme: "s3")) == .data)
    }

    @Test func googleDocsShowTheOfficeDocumentOfTheirKind() {
        func doc(_ kind: String) -> UTType { Icons.nativeType(for: remote("Doc", scheme: "gdrive", contentType: "com.google.apps.\(kind)")) }
        #expect(doc("document").identifier == "org.openxmlformats.wordprocessingml.document")
        #expect(doc("spreadsheet").identifier == "org.openxmlformats.spreadsheetml.sheet")
        #expect(doc("presentation").identifier == "org.openxmlformats.presentationml.presentation")
        #expect(doc("drawing") == .image)
        #expect(doc("form") == .internetLocation)
    }

    @Test(.isolatedSettings) func aRemoteFolderLooksLikeALocalOne() throws {
        #expect(Settings.shared.appearancePreferences.iconTheme == "Native macOS")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-icon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let localFolder = FileItem(url: local, name: local.lastPathComponent, isDirectory: true)
        let localImage = pixels(Icons.shared.image(for: localFolder, size: 32))
        for scheme in ["gdrive", "dropbox", "sftp", "ftp"] {
            #expect(pixels(Icons.shared.image(for: remote("Shared", folder: true, scheme: scheme), size: 32)) == localImage, "\(scheme)")
        }
    }

    @Test(.isolatedSettings) func remoteFilesAreNotABlankPage() {
        let blank = pixels(NSWorkspace.shared.icon(for: .data))
        var seen: Set<[UInt8]> = []
        for name in ["a.pdf", "b.jpg", "c.mp4", "d.zip", "e.swift", "f.docx"] {
            let image = pixels(Icons.shared.image(for: remote(name, scheme: "gdrive"), size: 32))
            #expect(image != blank, "\(name)")
            seen.insert(image)
        }
        #expect(seen.count == 6)
    }

    @Test(.isolatedSettings) func itemsAtTheSamePathOnTwoServersKeepTheirOwnIcons() {
        // The cache was keyed by path alone: the first item drawn at /x gave its icon to every other one.
        let folder = Icons.shared.image(for: remote("x", folder: true, scheme: "sftp"), size: 32)
        let file = Icons.shared.image(for: remote("x", scheme: "ftp", contentType: UTType.pdf.identifier), size: 32)
        #expect(pixels(folder) != pixels(file))
    }
}
