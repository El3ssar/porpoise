// Renders an SVG to a square PNG with AppKit (used to build the .icns without extra tools).
import AppKit
let a = CommandLine.arguments
let img = NSImage(contentsOfFile: a[1])!
let size = Int(a[3])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// The SVG already follows the Mac icon grid (824 body on a 1024 canvas), so it fills the image.
let inset = 0.0
img.draw(in: NSRect(x: inset, y: inset, width: Double(size) - 2 * inset, height: Double(size) - 2 * inset))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
