import Foundation

public enum Version {
    /// Numeric comparison of dotted versions, ignoring a leading "v": "0.10.0" > "0.9.2", "1.0" == "1.0.0".
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { (s.hasPrefix("v") ? String(s.dropFirst()) : s).split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
