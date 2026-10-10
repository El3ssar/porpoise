import Foundation
import PorpoiseCore

// MARK: Remote jobs (SSH, FTP, Android)

extension FileOperationsController {
    /// Copies/moves between local folders and providers. There is no conflict dialog here, so an item
    /// whose name already exists at the destination is reported and left alone, never overwritten.
    func runRemote(_ kind: FileOperationKind, _ urls: [URL], to folder: URL?, window: AnyObject?, done: (([URL]) -> Void)?) {
        let job = FileJob(kind: kind, sources: urls, destinationFolder: folder)   // used for the progress row only
        ui?.jobStarted(job)
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            var results: [URL] = []
            var existing: Set<String>?
            for (i, src) in urls.enumerated() {
                if job.isCancelled { break }
                DispatchQueue.main.async {
                    self.ui?.jobProgressed(job, JobProgress(kind: kind, totalBytes: 0, doneBytes: 0, totalItems: urls.count,
                                                            doneItems: i, currentName: src.lastPathComponent, destination: folder))
                }
                do {
                    switch kind {
                    case .delete, .trash:
                        if let p = RemoteFS.provider(for: src) { try p.delete([src]) } else { try FileManager.default.removeItem(at: src) }
                    case .link:
                        throw RemoteError.unsupported("Links can't be created across remote locations.")
                    case .copy, .move:
                        guard let dest = folder else { continue }
                        let name = src.lastPathComponent
                        if kind == .move, Self.sameLocation(src.deletingLastPathComponent(), dest) { continue }
                        if existing == nil { existing = try Self.names(in: dest) }
                        if existing?.contains(name) == true {
                            throw RemoteError.exists(name)
                        }
                        try Self.transferRemote(kind, src, into: dest)
                        existing?.insert(name)
                        results.append(dest.appendingPathComponent(name))
                    }
                } catch {
                    errors.append("\(src.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.ui?.jobFinished(job)
                Self.notifyChanged(urls + (folder.map { [$0] } ?? []) + results)
                if !errors.isEmpty { self.showErrors(errors, window: window) }
                done?(results)
            }
        }
    }

    /// Same folder, ignoring a trailing "/" (remote folder URLs carry one, typed ones may not).
    private static func sameLocation(_ a: URL, _ b: URL) -> Bool {
        func key(_ u: URL) -> String {
            let s = u.standardized
            var p = s.path
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return "\(s.scheme ?? "")://\(s.user ?? "")@\(s.host ?? ""):\(s.port ?? 0)\(p)"
        }
        return key(a) == key(b)
    }

    /// Names in a local or remote folder.
    private static func names(in folder: URL) throws -> Set<String> {
        if let p = RemoteFS.provider(for: folder) { return Set(try p.list(folder).map(\.name)) }
        return Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// One copy/move where the source, the destination or both are remote.
    private static func transferRemote(_ kind: FileOperationKind, _ src: URL, into dest: URL) throws {
        let fm = FileManager.default
        switch (RemoteFS.provider(for: src), RemoteFS.provider(for: dest)) {
        case let (s?, d?) where s === d:
            if kind == .copy { try s.copy([src], into: dest) } else { try s.move([src], into: dest) }
        case let (s?, nil):
            _ = try s.download(src, into: dest)
            if kind == .move { try s.delete([src]) }
        case let (nil, d?):
            try d.upload(src, into: dest)
            if kind == .move { try fm.removeItem(at: src) }
        case let (s?, d?):
            // Between two remote hosts: through a local temporary copy.
            let tmp = fm.temporaryDirectory.appendingPathComponent("xfer-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            try d.upload(try s.download(src, into: tmp), into: dest)
            if kind == .move { try s.delete([src]) }
        case (nil, nil):
            // A local item in a mixed local/remote selection (its name was checked to be free).
            guard src.isFileURL, dest.isFileURL else {
                throw RemoteError.unsupported("Items can't be put into “\(dest.absoluteString)”.")
            }
            let dst = dest.appendingPathComponent(src.lastPathComponent)
            if kind == .copy { try fm.copyItem(at: src, to: dst) } else { try fm.moveItem(at: src, to: dst) }
        }
    }
}
