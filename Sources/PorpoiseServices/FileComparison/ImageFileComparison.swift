import CoreGraphics
import Foundation
import ImageIO

public struct ImageFileComparison {
    public let left: CGImage
    public let right: CGImage
    public let difference: CGImage?
    public let changedPercent: Double?
    public let sampled: Bool
    public static func load(_ left: URL, _ right: URL) throws -> ImageFileComparison {
        func image(_ url: URL) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return image
        }
        let a = try image(left), b = try image(right)
        let fullW = max(a.width, b.width), fullH = max(a.height, b.height)
        // Display diff is bounded at 16M pixels. The label makes sampling explicit for huge photographs.
        let factor = min(1, sqrt(16_000_000 / Double(fullW * fullH))), w = max(1, Int(Double(fullW) * factor)),
            h = max(1, Int(Double(fullH) * factor))
        let space = CGColorSpaceCreateDeviceRGB(), options = CGImageAlphaInfo.premultipliedLast.rawValue
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: options)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: Double(image.width) * factor, height: Double(image.height) * factor))
            }; return bytes
        }
        let x = pixels(a), y = pixels(b); var output = [UInt8](repeating: 0, count: x.count), changed = 0
        for p in stride(from: 0, to: output.count, by: 4) {
            var different = false
            for c in 0..<4 { let d = abs(Int(x[p + c]) - Int(y[p + c])); different = different || d > 0; if c < 3 { output[p + c] = UInt8(d) } }
            // An alpha-only change must be visible too.
            let alpha = UInt8(abs(Int(x[p + 3]) - Int(y[p + 3])))
            for c in 0..<3 { output[p + c] = max(output[p + c], alpha) }; output[p + 3] = 255
            if different { changed += 1 }
        }
        let provider = CGDataProvider(data: Data(output) as CFData)!
        let diff = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: options),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        return ImageFileComparison(left: a, right: b, difference: diff, changedPercent: Double(changed) / Double(w * h) * 100, sampled: factor < 1)
    }
}
