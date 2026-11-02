import Foundation

/// Compiled component rules for the index crawler's hottest predicate. Scans native UTF-8 once,
/// without repeated Foundation substring searches or allocating an array of path components.
struct GeneratedPathExclusions: Sendable {
    let gitObjects: Bool
    let nodeModules: Bool
    let buildOutput: Bool

    private static let git = Array(".git".utf8)
    private static let objects = Array("objects".utf8)
    private static let modules = Array("node_modules".utf8)
    private static let build = Array(".build".utf8)
    private static let derived = Array("DerivedData".utf8)

    func matches(_ path: String) -> Bool {
        guard gitObjects || nodeModules || buildOutput else { return false }
        if let answer = path.utf8.withContiguousStorageIfAvailable({ scan($0) }) { return answer }
        // Bridged/noncontiguous strings are uncommon here; retain exactly the same byte-boundary policy.
        return Array(path.utf8).withUnsafeBufferPointer { scan($0) }
    }

    private func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var start = 0, previousWasGit = false
        for end in 0...bytes.count where end == bytes.count || bytes[end] == 47 {
            let component = UnsafeBufferPointer(rebasing: bytes[start..<end])
            if nodeModules && component.elementsEqual(Self.modules) { return true }
            if buildOutput && (component.elementsEqual(Self.build) || component.elementsEqual(Self.derived)) { return true }
            if gitObjects && previousWasGit && component.elementsEqual(Self.objects) { return true }
            previousWasGit = component.elementsEqual(Self.git)
            start = end + 1
        }
        return false
    }
}
