import Darwin
import Foundation

@testable import PorpoiseCore
@testable import PorpoiseFileSystem
@testable import PorpoiseServices

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func footprintMB() -> Double {
    var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1
}
let args = CommandLine.arguments
func arg(_ i: Int, _ d: String) -> String { args.count > i ? args[i] : d }
let mode = arg(1, "help")

switch mode {
case "move":
    // Same-volume move of a tree: preparing (inventory) time vs total.
    let src = URL(fileURLWithPath: arg(2, "."))
    let dest = URL(fileURLWithPath: arg(3, "."))
    let job = FileJob(kind: .move, sources: [src], destinationFolder: dest)
    let t0 = now(); var transferAt = 0.0
    job.onProgress = { p in if p.phase == .transferring && transferAt == 0 { transferAt = now() } }
    _ = try job.run()
    let total = now() - t0
    print(String(format: "move: preparing %.2f s, total %.2f s", transferAt - t0, total))
case "checksum":
    // FileChecksums.digest in one GCD block with no pool: does footprint grow with bytes read?
    let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: arg(2, ".")), includingPropertiesForKeys: nil)
    let f0 = footprintMB(); var peak = f0
    let t = now()
    DispatchQueue.global().sync {
        let pooled = arg(3, "") == "pool"
        for f in files {
            if pooled { autoreleasepool { _ = try? FileChecksums.digest(f) } } else { _ = try? FileChecksums.digest(f) };
            peak = max(peak, footprintMB())
        }
    }
    print(
        String(format: "digest %d files: %.2f s, footprint start %.0f MB peak %.0f MB end %.0f MB", files.count, now() - t, f0, peak, footprintMB()))
case "trash":
    // TrashService.record per item with an existing origins map of n keys.
    let n = Int(arg(2, "10000"))!, items = Int(arg(3, "500"))!
    let suite = "perfbench.trash.\(getpid())"
    Settings.store = UserDefaults(suiteName: suite)!
    var map: [String: String] = [:]
    for i in 0..<n { map["/Users/someone/.Trash/old-file-\(i).txt"] = "/Users/someone/Documents/old-file-\(i).txt" }
    Settings.store.set(map, forKey: "trashOrigins")
    let svc = TrashService()
    var t = now()
    for i in 0..<items {
        svc.record([
            (original: URL(fileURLWithPath: "/Users/someone/Desktop/new-\(i)"), inTrash: URL(fileURLWithPath: "/Users/someone/.Trash/new-\(i)"))
        ])
    }
    let per = (now() - t) / Double(items)
    t = now(); svc.flush()
    let flush = now() - t
    t = now(); svc.record([]); svc.flush()
    let prune = now() - t
    print(String(format: "batch flush %.1f ms", flush * 1000))
    print(
        String(
            format: "record(1 pair) with %d keys: %.2f ms each (%d items = %.2f s); prune + flush %.1f ms", n, per * 1000, items,
            per * Double(items), prune * 1000))
    UserDefaults.standard.removePersistentDomain(forName: suite)
case "verify":
    // Activity.verify: CopyVerification.verify on a copied folder inside one global-queue async block.
    let a = URL(fileURLWithPath: arg(2, ".")), b = URL(fileURLWithPath: arg(3, "."))
    let f0 = footprintMB(); var peak = f0
    let timer = DispatchSource.makeTimerSource(queue: .global()); timer.schedule(deadline: .now(), repeating: 0.02)
    timer.setEventHandler { peak = max(peak, footprintMB()) }; timer.resume()
    let t = now()
    DispatchQueue.global(qos: .utility).async {
        let r = CopyVerification.verify(a, b)
        print(
            String(
                format: "verify %d files %.0f MB: %.2f s, footprint start %.0f MB, peak inside the block %.0f MB", r.files, Double(r.bytes) / 1048576,
                now() - t, f0, max(peak, footprintMB())))
        exit(0)
    }
    dispatchMain()
case "remote":
    let root = URL(fileURLWithPath: arg(2, ".build/perfjobs/remote"))
    let n = Int(arg(3, "500"))!
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let local = root.appendingPathComponent(UUID().uuidString), server = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: server.appendingPathComponent("dst"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: server) }
    let provider = CountingTransferProvider(root: server)
    let destination = URL(string: "sftp://perfjobs-fake/dst")!
    RemoteFS.use(provider, for: destination)
    defer { RemoteFS.use(nil, for: destination) }
    let sources = try (0..<n).map { i -> URL in
        let file = local.appendingPathComponent("f\(i)")
        try Data("payload".utf8).write(to: file)
        return file
    }
    let job = RemoteTransferJob(kind: .copy, sources: sources, destination: destination, control: JobControl(), rule: .ask, options: .init())
    let t = now()
    job.run()
    print(
        String(
            format: "remote: %d files %.3f s, listings %d, stage folders %d, live target checks %d, errors %d", job.results.count, now() - t,
            provider.lists, provider.folders, provider.targetChecks, job.errors.count))
    if !job.errors.isEmpty { print(job.errors); exit(1) }
default:
    print("modes: verify <original> <copy> | checksum <folder> | move <source> <destination> | trash [keys] [items] | remote <scratch-root> [items]")
}

final class CountingTransferProvider: RemoteProvider, RemoteTransferTargetChecking {
    let root: URL
    var lists = 0, folders = 0, targetChecks = 0
    var onUpload: () throws -> Void = {}
    init(root: URL) { self.root = root }
    func local(_ url: URL) -> URL { root.appendingPathComponent(url.path) }
    func list(_ folder: URL) throws -> [FileItem] {
        lists += 1
        return try FileManager.default.contentsOfDirectory(at: local(folder), includingPropertiesForKeys: nil).compactMap { url in
            guard let item = FileItem.load(url) else { return nil }
            return FileItem(url: folder.appendingPathComponent(item.name), name: item.name, isDirectory: item.isDirectory, size: item.size)
        }
    }
    func download(_ remote: URL, into folder: URL) throws -> URL {
        let target = folder.appendingPathComponent(remote.lastPathComponent)
        try FileManager.default.copyItem(at: local(remote), to: target)
        return target
    }
    func upload(_ source: URL, into folder: URL) throws {
        try FileManager.default.copyItem(at: source, to: local(folder).appendingPathComponent(source.lastPathComponent))
        try onUpload()
    }
    func delete(_ urls: [URL]) throws { for url in urls { try FileManager.default.removeItem(at: local(url)) } }
    func makeFolder(_ url: URL) throws { folders += 1; try FileManager.default.createDirectory(at: local(url), withIntermediateDirectories: false) }
    func removeEmptyFolder(_ url: URL) throws {
        guard rmdir(local(url).path) == 0 else { throw POSIXError(.ENOTEMPTY) }
    }
    func rename(_ url: URL, to name: String) throws {
        try FileManager.default.moveItem(at: local(url), to: local(url).deletingLastPathComponent().appendingPathComponent(name))
    }
    func move(_ urls: [URL], into folder: URL) throws {
        for url in urls { try FileManager.default.moveItem(at: local(url), to: local(folder).appendingPathComponent(url.lastPathComponent)) }
    }
    func copy(_ urls: [URL], into folder: URL) throws {
        for url in urls { try FileManager.default.copyItem(at: local(url), to: local(folder).appendingPathComponent(url.lastPathComponent)) }
    }
    func rootTitle(_ url: URL) -> String { "Test server" }
    func transferTargetExists(_ target: URL) throws -> Bool { targetChecks += 1; return FileJob.itemExists(at: local(target)) }
}
