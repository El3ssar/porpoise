import Foundation
import Darwin
import PorpoiseCore
import PorpoiseServices

func seconds(_ block: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try block()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}
func option(_ flag: String, default value: Int) -> Int {
    guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return value }
    return Int(CommandLine.arguments[i + 1]) ?? value
}
let entries = max(1, option("--entries", default: 1_000_000))
let files = max(0, option("--files", default: 0))
print("Porpoise index benchmark; \(ProcessInfo.processInfo.operatingSystemVersionString); \(ProcessInfo.processInfo.processorCount) logical CPUs")
var index = NameIndex()
let build = seconds {
    let root = index.append(name: "/fixture", directory: true)
    for n in 0..<entries {
        let parent = n % 1000 == 0 ? index.append(name: "directory-\(n)", parent: root, directory: true) : root
        index.append(name: "document-\(n)-\(n % 97 == 0 ? "annual-report" : "project").\(n % 3 == 0 ? "pdf" : "txt")", parent: parent,
                     size: Int64(n * 101), modified: 1767225600 + Double(n))
    }
}
print(String(format: "Synthetic build: %d records, %.3f s; compact storage %.1f MiB", index.count, build, Double(index.storageBytes) / 1048576))
let queries = ["not-present-anywhere", "annual report ext:pdf", "document-999999", "project ext:txt size:>10mb", "annual path:directory", "dm:>=2026-01-02 report"]
var samples: [Double] = []
for text in queries {
    let q = try IndexQuery(text)
    _ = index.search(q) // Warm cache.
    var times: [Double] = [], hits = 0
    for _ in 0..<15 {
        times.append(seconds { hits = index.search(q, scope: "/fixture").count } * 1000)
    }
    times.sort(); samples.append(contentsOf: times)
    print(String(format: "query %@: hits=%d p50=%.3f ms p95=%.3f ms", text, hits, times[times.count / 2], times[Int(Double(times.count - 1) * 0.95)]))
}
samples.sort()
print(String(format: "Aggregate query p50=%.3f ms p95=%.3f ms", samples[samples.count / 2], samples[Int(Double(samples.count - 1) * 0.95)]))
let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/index-benchmark-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let snapshotURL = dir.appendingPathComponent("snapshot.idx")
let save = try seconds { try index.encoded().write(to: snapshotURL, options: .atomic) }
var loaded: NameIndex?
let load = try seconds { loaded = try NameIndex(encoded: Data(contentsOf: snapshotURL, options: .mappedIfSafe)) }
print(String(format: "Snapshot save %.3f s; mapped load + validation %.3f s; loaded %d records", save, load, loaded!.count))
if files > 0 {
    let root = dir.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let generate = try seconds {
        for bucket in 0..<((files + 999) / 1000) {
            let folder = root.appendingPathComponent("d\(bucket)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for n in (bucket * 1000)..<min(files, (bucket + 1) * 1000) {
                let path = folder.appendingPathComponent("fixture-\(n).txt").path
                let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                let text = n == files - 1 ? "unique xylophonicneedle here\n" : "status ready task \(n)\n"
                text.utf8CString.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress!, $0.count - 1) }
                close(fd)
            }
        }
    }
    var crawled = NameIndex()
    let crawl = seconds { crawled = IndexCrawler.crawl(root.path, exclusions: []) }
    print(String(format: "Disk fixture: %d files generated in %.3f s; crawl %d records in %.3f s; storage %.1f MiB", files, generate, crawled.count, crawl, Double(crawled.storageBytes) / 1048576))
    let contentBuild = seconds { crawled = IndexCrawler.crawl(root.path, exclusions: [], content: true) }
    var candidates: [Int] = [], matches = 0
    let contentQuery = try seconds {
        candidates = crawled.contentCandidates("xylophonicneedle", scope: root.path)
        for id in candidates {
            if try String(contentsOfFile: crawled.path(id), encoding: .utf8).contains("xylophonicneedle") { matches += 1 }
        }
    }
    guard matches == 1 else { throw NSError(domain: "IndexBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected exactly one verified content hit"]) }
    print(String(format: "Content filter build %.3f s; candidates %d/%d; verified hits %d; query %.3f ms", contentBuild, candidates.count, files, matches, contentQuery * 1000))
    let rg = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/search-tools/rg")
    if FileManager.default.isExecutableFile(atPath: rg.path) {
        let baseline = try seconds {
            let process = Process(); process.executableURL = rg
            process.arguments = ["--files-with-matches", "--fixed-strings", "--ignore-case", "--hidden", "--no-ignore", "--", "xylophonicneedle", root.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "IndexBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "ripgrep baseline failed"]) }
        }
        print(String(format: "ripgrep content baseline %.3f ms; indexed speedup %.1fx", baseline * 1000, baseline / contentQuery))
    }
}
var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
print(String(format: "Process peak RSS %.1f MiB (includes original + encoded + loaded snapshot and optional disk fixture)", Double(usage.ru_maxrss) / 1048576))
fflush(stdout)
if samples[samples.count / 2] >= 50 { fputs("FAIL: aggregate p50 >=50 ms\n", stderr); exit(1) }
