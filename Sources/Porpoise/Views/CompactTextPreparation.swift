import AppKit
import PorpoiseCore

/// Only the main thread owns the request and snapshots labels from the model. A worker
/// receives a bounded array of strings and an immutable font, never the live model/settings.
final class CompactTextPreparation {
    static let queue = DispatchQueue(label: "Porpoise.CompactText", qos: .userInitiated)
    static let rowsPerBatch = 128

    var revision: UInt64
    let roles: [ItemRole]
    let relativeMinute: Int?
    let font: NSFont
    let limit: CGFloat
    var nextRow: Int
    var widest: CGFloat

    init(revision: UInt64, roles: [ItemRole], relativeMinute: Int?, font: NSFont, limit: CGFloat, nextRow: Int, widest: CGFloat) {
        self.revision = revision
        self.roles = roles
        self.relativeMinute = relativeMinute
        self.font = font
        self.limit = limit
        self.nextRow = nextRow
        self.widest = widest
    }

    /// NSString already measures multiline strings by their widest line. Joining a small
    /// batch amortizes its text-system setup for ordinary printable ASCII labels.
    /// Measure controls, Unicode and trailing spaces individually: paragraph layout can
    /// change their bidi/whitespace behavior. Bound text too: huge attributed strings
    /// can trigger Core Text's simplified layout.
    static func widest(_ labels: [String], font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var joined = "", units = 0
        var widest: CGFloat = 0
        func flush() {
            guard !joined.isEmpty else { return }
            widest = max(widest, (joined as NSString).size(withAttributes: attributes).width)
            joined = ""
            units = 0
        }
        for label in labels {
            let count = label.utf16.count
            let plain = label.utf8.last != 32 && label.utf8.allSatisfy { (32...126).contains($0) }
            if units + count + 1 > 2048 { flush() }
            if !plain || count > 2048 {
                widest = max(widest, (label as NSString).size(withAttributes: attributes).width)
            } else {
                if !joined.isEmpty { joined.append("\n") }
                joined.append(label)
                units += count + 1
            }
        }
        flush()
        return widest
    }
}
