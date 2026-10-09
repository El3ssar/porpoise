import Foundation

/// Text formatting the way KDE does it (KFormat): binary sizes with IEC units, relative dates.
public enum FileFormat {
    /// "0 B", "512 B", "1.5 KiB", "12.3 MiB"…
    public static func size(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var v = Double(bytes) / 1024
        var i = 0
        // Switch units where "%.1f" would round up to "1024.0".
        while v >= 1023.95 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }

    public static func itemCount(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    /// KFormat::formatRelativeDateTime: "Today at 14:05", "Yesterday at 09:12", otherwise a date.
    public static func relativeDate(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d),
                                           to: calendar.startOfDay(for: now)).day ?? 99
        let time = timeFormatter.string(from: d)
        switch days {
        case 0: return "Today at \(time)"
        case 1: return "Yesterday at \(time)"
        case 2..<7:
            return "\(formatter("EEEE", calendar: calendar).string(from: d)) at \(time)"
        default: return dateTimeFormatter.string(from: d)
        }
    }

    public static func longDate(_ d: Date) -> String { longFormatter.string(from: d) }

    nonisolated(unsafe) private static var formatterCache: [String: DateFormatter] = [:]
    private static let formatterLock = NSLock()

    /// Cached formatter for a fixed format (creating DateFormatters is slow; grouping calls this per item).
    static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let key = "\(format)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(calendar.locale?.identifier ?? "")"
        formatterLock.lock(); defer { formatterLock.unlock() }
        if let f = formatterCache[key] { return f }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if let l = calendar.locale { f.locale = l }
        f.dateFormat = format
        formatterCache[key] = f
        return f
    }

    /// "drwxr-xr-x" style.
    public static func permissions(_ mode: Int, isDirectory: Bool) -> String {
        var s = isDirectory ? "d" : "-"
        let chars: [(Int, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"),
                                         (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x")]
        for (bit, c) in chars { s.append(mode & bit != 0 ? c : "-") }
        return s
    }

    /// Status bar summary: "3 folders, 12 files (4.2 MiB)" — Dolphin's wording (KIO::itemsSummaryString).
    public static func summary(folders: Int, files: Int, bytes: Int64, selected: Bool) -> String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        var parts: [String] = []
        if selected {
            if folders > 0 { parts.append(plural(folders, "folder selected", "folders selected")) }
            if files > 0 { parts.append(plural(files, "file selected", "files selected")) }
        } else {
            if folders > 0 { parts.append(plural(folders, "folder", "folders")) }
            if files > 0 { parts.append(plural(files, "file", "files")) }
        }
        var text = parts.joined(separator: ", ")
        if files > 0 { text += " (\(size(bytes)))" }
        return text
    }

    /// Splits "name.ext" for numbering; keeps double extensions such as ".tar.gz" together and
    /// treats dot files (".bashrc") as having no extension.
    static func splitExtension(_ name: String) -> (base: String, ext: String) {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        guard !ext.isEmpty, !base.isEmpty, base != "." else { return (name, "") }
        let inner = base as NSString
        if inner.pathExtension.lowercased() == "tar", !inner.deletingPathExtension.isEmpty {
            return (inner.deletingPathExtension, inner.pathExtension + "." + ext)
        }
        return (base, ext)
    }

    private static func join(_ base: String, _ ext: String) -> String { ext.isEmpty ? base : base + "." + ext }

    /// Name for a duplicate: "name copy.ext", "name copy 2.ext"…
    public static func duplicateName(for name: String, existing: Set<String>) -> String {
        let (base, ext) = splitExtension(name)
        var n = 1
        while true {
            let candidate = join(base + (n == 1 ? " copy" : " copy \(n)"), ext)
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// Unused name for KIO's "Suggest New Name": "name (1).ext", "name (2).ext"…
    public static func suggestedName(for name: String, existing: Set<String>) -> String {
        var (base, ext) = splitExtension(name)
        var n = 1
        if let r = base.range(of: #" \((\d+)\)$"#, options: .regularExpression),
           let num = Int(base[r].dropFirst(2).dropLast()) {
            n = num + 1
            base.removeSubrange(r)
        }
        while true {
            let candidate = join("\(base) (\(n))", ext)
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }
}
