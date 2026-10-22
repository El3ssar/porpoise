import Foundation
import PorpoiseCore

/// The saved connections (connections.json in the support folder). Profiles hold no secrets: passwords and S3 secret
/// keys are in the Keychain (`ConnectionCredentials`). Read from any thread; changed on the main thread.
public final class ConnectionProfiles: @unchecked Sendable {
    public static let shared = ConnectionProfiles(storeURL: Settings.supportFolder.appendingPathComponent("connections.json"))
    public static let changed = Notification.Name("PorpoiseConnectionProfilesChanged")

    private let storeURL: URL?
    private let fileManager: FileManager
    private let lock = NSLock()
    private var stored: [ConnectionProfile] = []
    private var loaded = false

    /// Profiles kept in `storeURL`; nil keeps them in memory (tests).
    public convenience init(storeURL: URL?) { self.init(storeURL: storeURL, fileManager: .default) }

    init(storeURL: URL?, fileManager: FileManager) {
        self.storeURL = storeURL
        self.fileManager = fileManager
    }

    private struct File: Codable {
        var version: Int
        var profiles: [ConnectionProfile]
    }
    private static let version = 1

    public var profiles: [ConnectionProfile] {
        lock.lock(); defer { lock.unlock() }
        // Reading remains nonthrowing for sidebar consumers. A failed load is retried by the next read or mutation;
        // mutations return the error and never overwrite a file we could not read or preserve.
        try? loadIfNeeded()
        return stored
    }

    public func profile(_ id: UUID) -> ConnectionProfile? { profiles.first { $0.id == id } }

    /// The profile `url` is in, if any (the first saved, when two describe the same server).
    public func profile(for url: URL) -> ConnectionProfile? { profiles.first { $0.covers(url) } }

    /// Adds `profile`, or replaces the saved one with its id. Success means the atomic write completed; failures
    /// leave the in-memory list unchanged and post no changed notification. nil-store instances are memory-only.
    @discardableResult
    public func save(_ profile: ConnectionProfile) -> Result<Void, Error> {
        change { list in
            if let i = list.firstIndex(where: { $0.id == profile.id }) { list[i] = profile } else { list.append(profile) }
        }
    }

    /// Removes the profile, and the secrets kept for it alone (an S3 secret key). Passwords are kept under the
    /// server rather than the profile, so one Finder or another profile also uses is left in place.
    @discardableResult
    public func remove(_ id: UUID, credentials: ConnectionCredentials = .shared) -> Result<Void, Error> {
        var removed: ConnectionProfile?
        let result = change(skipIfUnchanged: true) { list in
            removed = list.first { $0.id == id }
            list.removeAll { $0.id == id }
        }
        return result.flatMap {
            Result { if let removed, removed.kind == .s3 { try credentials.removeSecret(for: removed) } }
        }
    }

    @discardableResult
    public func move(_ id: UUID, to index: Int) -> Result<Void, Error> {
        change { list in
            guard let from = list.firstIndex(where: { $0.id == id }) else { return }
            let p = list.remove(at: from)
            list.insert(p, at: max(0, min(index, list.count)))
        }
    }

    private func change(skipIfUnchanged: Bool = false, _ edit: (inout [ConnectionProfile]) -> Void) -> Result<Void, Error> {
        // Keep loading, editing and writing in the same critical section: an older snapshot must never overwrite a
        // newer one. Publish only after the durable write, and release the lock before observers read the list.
        lock.lock()
        do {
            try loadIfNeeded()
            var candidate = stored
            edit(&candidate)
            if skipIfUnchanged && candidate == stored { lock.unlock(); return .success(()) }
            try write(candidate)
            stored = candidate
            lock.unlock()
        } catch {
            lock.unlock()
            return .failure(error)
        }
        let post = { NotificationCenter.default.post(name: Self.changed, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
        return .success(())
    }

    /// Called with the lock held. Do not mark a failed load as complete: the user can fix the folder and retry.
    private func loadIfNeeded() throws {
        guard !loaded else { return }
        guard let storeURL else { loaded = true; return }
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            loaded = true
            return
        }
        if let file = try? JSONDecoder().decode(File.self, from: data), file.version == Self.version {
            stored = file.profiles
        } else {
            // Preserve each damaged/newer file before allowing a replacement. Never delete an earlier backup, and
            // never claim recovery succeeded or overwrite the original when copying fails.
            var backup = storeURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            if fileManager.fileExists(atPath: backup.path) {
                backup = storeURL.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
            }
            try fileManager.copyItem(at: storeURL, to: backup)
        }
        loaded = true
    }

    private func write(_ list: [ConnectionProfile]) throws {
        guard let storeURL else { return }
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(version: Self.version, profiles: list)).write(to: storeURL, options: .atomic)
    }

    // MARK: Sidebar

    /// The profiles as sidebar rows in Remote, in their saved order.
    public var placeEntries: [PlaceEntry] {
        profiles.compactMap { p in
            guard let url = p.url else { return nil }
            return PlaceEntry(title: p.name, url: url, icon: "folder-remote", section: .remote)
        }
    }

    // MARK: ssh

    /// The ssh options a profile adds for `url`'s server: its jump hosts and key. A profile made from a
    /// ~/.ssh/config Host adds only what the user set on top, since ssh reads the rest from the file.
    public func sshOptions(for url: URL) -> [String] {
        guard let p = profile(for: url), p.kind == .sftp else { return [] }
        return Self.sshOptions(for: p)
    }

    /// The ssh options `p` adds (see `sshOptions(for:)` of a URL).
    public static func sshOptions(for p: ConnectionProfile) -> [String] {
        var a: [String] = []
        if !p.jumpHosts.isEmpty { a += ["-J", p.jumpHosts.joined(separator: ",")] }
        if let key = p.identityFile?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            // Only this key, so the agent's other keys don't use up the server's login attempts first.
            a += ["-i", (key as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        return a
    }
}
