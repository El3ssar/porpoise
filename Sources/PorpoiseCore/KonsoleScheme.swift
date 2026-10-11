import Foundation

/// A Konsole `.colorscheme`: 16 ANSI colors plus background and foreground.
public struct KonsoleScheme {
    public typealias RGB = (Int, Int, Int)
    public var palette: [RGB]
    public var background: RGB?
    public var foreground: RGB?

    /// Desert-Konsole from the bundle (or the project's Resources under `swift run`), else the built-in copy.
    public static let desert: KonsoleScheme = {
        let name = "Desert-Konsole.colorscheme"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/" + name),
        ]
        for case let u? in candidates {
            if let text = try? String(contentsOf: u, encoding: .utf8) { return parse(text) }
        }
        return KonsoleScheme(palette: builtInDesertPalette)
    }()

    /// The light look's terminal: dark text on the light window color, with ANSI colors deep enough to read on it.
    public static let light = KonsoleScheme(
        palette: [
            (34, 38, 52), (192, 57, 68), (0, 122, 96), (160, 112, 0), (36, 112, 186), (140, 72, 150), (24, 120, 150), (238, 240, 245),
            (98, 105, 128), (210, 90, 60), (40, 150, 110), (190, 140, 20), (66, 132, 210), (170, 100, 180), (40, 150, 180), (255, 255, 255),
        ],
        background: (238, 240, 245), foreground: (34, 38, 52))

    public static let builtInDesertPalette: [RGB] = [
        (29, 33, 47), (191, 97, 106), (0, 160, 128), (235, 203, 139), (65, 129, 194), (180, 142, 173), (58, 129, 179), (214, 219, 241),
        (85, 97, 128), (208, 135, 112), (98, 194, 162), (240, 216, 160), (114, 159, 207), (199, 166, 199), (110, 170, 210), (255, 255, 255),
    ]

    /// Reads `[ColorN]` / `[ColorNIntense]` / `[Background]` / `[Foreground]` sections; missing colors use the built-in palette.
    public static func parse(_ text: String) -> KonsoleScheme {
        var colors: [Int: RGB] = [:]
        var scheme = KonsoleScheme(palette: builtInDesertPalette)
        var section = ""
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { section = l; continue }
            guard l.hasPrefix("Color=") else { continue }
            let parts = l.dropFirst(6).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 3 else { continue }
            let rgb = (parts[0], parts[1], parts[2])
            // Color0…7 only: "[Color9]" would fill a slot of its own, and 16 entries would no longer mean 0…15.
            if let m = section.range(of: #"^\[Color([0-7])(Intense)?\]$"#, options: .regularExpression) {
                let s = section[m]
                let idx = Int(s.dropFirst(6).prefix(1)) ?? 0
                colors[idx + (s.contains("Intense") ? 8 : 0)] = rgb
            } else if section == "[Background]" {
                scheme.background = rgb
            } else if section == "[Foreground]" {
                scheme.foreground = rgb
            }
        }
        if colors.count == 16 { scheme.palette = (0..<16).map { colors[$0]! } }
        return scheme
    }
}
