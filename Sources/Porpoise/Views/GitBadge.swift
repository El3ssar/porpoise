import AppKit
import PorpoiseCore
import PorpoiseServices

/// Letter glyphs preserve meaning without relying on colour; folders use a quiet dot.
enum GitBadge {
    static func color(_ status: GitFileStatus, selected: Bool) -> NSColor {
        if selected { return Theme.selectionText }
        switch status {
        case .conflicted, .deleted: return .systemRed
        case .added, .untracked: return .systemGreen
        case .renamed: return .systemPurple
        case .modified: return .systemOrange
        case .ignored, .changedFolder: return Theme.viewTextInactive
        }
    }
    static func draw(_ status: GitFileStatus?, in rect: CGRect, selected: Bool, disc: Bool = false) {
        guard let status, status != .ignored else { return }
        if disc {
            Theme.viewBackground.setFill(); NSBezierPath(ovalIn: rect).fill()
        }
        let font = NSFont.monospacedSystemFont(ofSize: min(13, rect.height - 2), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(status, selected: selected)]
        let size = (status.symbol as NSString).size(withAttributes: attributes)
        (status.symbol as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}

extension ItemListView {
    func gitBadge(_ item: FileItem) -> GitFileStatus? { model.gitStatus?.status(for: item) }
}
