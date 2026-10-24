import AppKit
import PorpoiseCore
import PorpoiseServices

/// Letter glyphs preserve meaning without relying on colour; folders use a quiet dot.
enum GitBadge {
    static func color(_ status: GitFileStatus, selected: Bool) -> NSColor {
        if selected { return Theme.selectionText }
        switch status {
        case .conflicted, .deleted: return Theme.transferDanger
        case .added, .untracked: return Theme.transferPositive
        case .renamed: return .systemPurple
        case .modified: return Theme.transferChanged
        case .ignored, .changedFolder: return Theme.viewTextInactive
        }
    }
    /// Upper-left corner stays clear of labels and of cloud/link emblems in the lower corners.
    static func iconRect(imageRect: CGRect, iconSize: CGFloat) -> CGRect {
        let size = max(10, min(16, iconSize * 0.28))
        // Tiny icons leave the lower-right cloud disc room; larger icons carry the glyph inside their corner.
        let inset: CGFloat = iconSize < 24 ? -size * 0.4 : 2
        return CGRect(x: imageRect.minX + inset, y: imageRect.minY + inset, width: size, height: size)
    }
    static func draw(_ status: GitFileStatus?, in rect: CGRect, selected: Bool, halo: Bool = false) {
        guard let status, status != .ignored else { return }
        let font = NSFont.monospacedSystemFont(ofSize: min(13, rect.height - 2), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(status, selected: selected)]
        let size = (status.symbol as NSString).size(withAttributes: attributes)
        let point = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        if halo {
            // Draw the outline first so it doesn't thin the foreground letter's stems at small sizes.
            var outline = attributes
            outline[.strokeColor] = Theme.viewBackground
            outline[.strokeWidth] = 4.0
            (status.symbol as NSString).draw(at: point, withAttributes: outline)
        }
        (status.symbol as NSString).draw(at: point, withAttributes: attributes)
    }
}

extension ItemListView {
    func gitBadge(_ item: FileItem) -> GitFileStatus? { model.gitStatus?.status(for: item) }
}
