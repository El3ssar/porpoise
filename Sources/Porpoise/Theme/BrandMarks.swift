import AppKit
import PorpoiseServices

/// Cloud providers' marks (Resources/brands, vector) and account pictures, drawn the same way everywhere: Connect sheet
/// tiles, sidebar account headers, Settings › Accounts.
enum BrandMarks {
    private static let root: URL = {
        if let env = ProcessInfo.processInfo.environment["PORPOISE_RESOURCES"] {
            return URL(fileURLWithPath: env).appendingPathComponent("brands")
        }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("brands"), FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/brands")
    }()

    private static var cache: [String: NSImage] = [:]

    /// The mark for `name` ("google-drive"), following Light/Dark when a "-dark" variant exists. Keeps its aspect ratio
    /// inside a square of `size` points.
    static func image(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)|\(size)"
        if let img = cache[key] { return img }
        guard let light = NSImage(contentsOf: root.appendingPathComponent(name + ".svg")) else { return nil }
        let dark = NSImage(contentsOf: root.appendingPathComponent(name + "-dark.svg")) ?? light
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let src = NSAppearance.currentDrawing().isDark ? dark : light
            let s = src.size
            let scale = min(r.width / max(s.width, 1), r.height / max(s.height, 1))
            let w = s.width * scale, h = s.height * scale
            src.draw(in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
            return true
        }
        cache[key] = img
        return img
    }

    /// The account's picture in a circle, or its initial on a colour derived from the email when there's no picture.
    static func avatar(_ data: Data?, name: String, email: String, size: CGFloat) -> NSImage {
        let photo = data.flatMap(NSImage.init(data:))
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let circle = NSBezierPath(ovalIn: r)
            if let photo {
                NSGraphicsContext.saveGraphicsState()
                circle.addClip()
                photo.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                return true
            }
            initialColor(email).setFill()
            circle.fill()
            let initial = (name.first ?? email.first).map { String($0).uppercased() } ?? "?"
            let font = NSFont.systemFont(ofSize: size * 0.48, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let t = initial as NSString
            let ts = t.size(withAttributes: attrs)
            t.draw(at: CGPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2), withAttributes: attrs)
            return true
        }
    }

    /// A calm, stable colour per account (Google's own fallback avatars are coloured the same way).
    static func initialColor(_ email: String) -> NSColor {
        let palette: [NSColor] = [
            NSColor(srgbRed: 0.36, green: 0.42, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.18, green: 0.55, blue: 0.47, alpha: 1),
            NSColor(srgbRed: 0.70, green: 0.40, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.55, green: 0.33, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.25, green: 0.50, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.62, green: 0.30, blue: 0.38, alpha: 1),
        ]
        let sum = email.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

extension URL {
    /// A folder's name as shown in titles, breadcrumbs and menus: cloud items are ids in the URL, named by their
    /// provider; a remote server's root is its title.
    var folderName: String {
        if isFileURL { return path == "/" ? "/" : lastPathComponent }
        if RemoteFS.isRemote(self) { return RemoteFS.displayName(for: self) }
        return lastPathComponent
    }
}
