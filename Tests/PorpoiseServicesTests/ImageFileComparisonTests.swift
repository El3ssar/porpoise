import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PorpoiseServices

struct ImageFileComparisonTests {
    @Test func exactPixelsAndOrientation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.png"), b = root.appendingPathComponent("b.png")
        var pixels = [UInt8](repeating: 0, count: 3 * 2 * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        try write(pixels, width: 3, height: 2, to: a); try write(pixels, width: 3, height: 2, to: b)
        #expect(try ImageFileComparison.load(a, b).changedPercent == 0)
        pixels[0] = 255
        try write(pixels, width: 3, height: 2, to: b)
        let result = try ImageFileComparison.load(a, b)
        #expect(abs((result.changedPercent ?? 0) - 100.0 / 6) < 0.0001)
        #expect(!result.sampled)
        let image = try #require(result.difference)
        let bytes = try #require(image.dataProvider?.data) as Data
        #expect(bytes[0] == 255)
        #expect(bytes[3 * 4] == 0)  // Must not flip the differing pixel into the opposite row.
    }
    private func write(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        let data = Data(pixels) as CFData, provider = CGDataProvider(data: data)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
