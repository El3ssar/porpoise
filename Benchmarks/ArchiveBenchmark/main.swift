import Foundation
import PorpoiseServices

// A fixed, local-only listing probe. Fixture creation is outside the timed region; provider lookup and the
// first listing are included. No cache folder is accessed or created by listing.
let arguments = CommandLine.arguments
if arguments.count != 2 {
    FileHandle.standardError.write(Data("Usage: swift run -c release ArchiveBenchmark /path/to/archive.zip\n".utf8))
    exit(2)
}
// An isolated cache root also makes accidental extraction observable, without touching the operator's cache.
Settings.isTesting = true
let cache = Settings.cachesFolder
func cacheFiles() -> Set<String> { Set((try? FileManager.default.subpathsOfDirectory(atPath: cache.path)) ?? []) }
let before = cacheFiles()
let file = URL(fileURLWithPath: arguments[1])
let root = ArchiveLocation(archive: file).url
let clock = ContinuousClock()
let start = clock.now
guard let provider = RemoteFS.provider(for: root) else { fatalError("No archive provider") }
let items = try provider.list(root)
let elapsed = start.duration(to: clock.now)
let components = elapsed.components
let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
let added = cacheFiles().subtracting(before)
let result: [String: Any] = [
    "archiveBytes": try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
    "entries": items.count, "seconds": seconds, "cacheFilesAdded": added.count,
]
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
guard items.count == 100_000, seconds < 2, added.isEmpty else { exit(1) }
