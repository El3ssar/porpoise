import Foundation
import PorpoiseCore

/// The saved connections (connections.json in the support folder). Profiles hold no secrets: passwords and S3 secret
/// keys are in the Keychain (`ConnectionCredentials`). Read from any thread; changed on the main thread.
public final class ConnectionProfiles: @unchecked Sendable {
    public static let shared = ConnectionProfiles(storeURL: Settings.supportFolder.appendingPathComponent("connections.json"))
    public static let changed = Notification.Name("PorpoiseConnectionProfilesChanged")

    private let storeURL: URL?
    private let lock = NSLock()
    private var stored: [ConnectionProfile] = []
    private var loaded = false

    /// Profiles kept in `storeURL`; nil keeps them in memory (tests).
    public init(storeURL: URL?) { self.storeURL = storeURL }

    private struct File: Codable {
        var version: Int
        var profiles: [ConnectionProfile]
    }
    private static let version = 1

    public var profiles: [ConnectionProfile] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return stored
    }

    public func profile(_ id: UUID) -> ConnectionProfile? { profiles.first { $0.id == id } }

    /// The profile `url` is in, if any (the first saved, when two describe the same server).
    public func profile(for url: URL) -> ConnectionProfile? { profiles.first { $0.covers(url) } }

    /// Adds `profile`, or replaces the saved one with its id.
    public func save(_ profile: ConnectionProfile) {
        change { list in
            if let i = list.firstIndex(where: { $0.id == profile.id }) { list[i] = profile } else { list.append(profile) }
        }
    }

    /// Removes the profile, and the secrets kept for it alone (an S3 secret key). Passwords are kept under the
    /// server rather than the profile, so one Finder or another profile also uses is left in place.
    public func remove(_ id: UUID, credentials: ConnectionCredentials = .shared) {
        guard let p = profile(id) else { return }
        change { $0.removeAll { $0.id == id } }
        if p.kind == .s3 { try? credentials.removeSecret(for: p) }
    }

    public func move(_ id: UUID, to index: Int) {
        change { list in
            guard let from = list.firstIndex(where: { $0.id == id }) else { return }
            let p = list.remove(at: from)
            list.insert(p, at: max(0, min(index, list.count)))
        }
    }

    private func change(_ edit: (inout [ConnectionProfile]) -> Void) {
        lock.lock()
        loadIfNeeded()
        edit(&stored)
        let snapshot = stored
        lock.unlock()
        write(snapshot)
        let post = { NotificationCenter.default.post(name: Self.changed, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    /// Called with the lock held.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL) else { return }
        if let file = try? JSONDecoder().decode(File.self, from: data) {
            stored = file.profiles
        } else {
            // Unreadable (damaged, or from a newer version): keep a copy rather than overwrite it on the next save.
            let backup = storeURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: storeURL, to: backup)
            NSLog("Porpoise: connections.json could not be read; a copy was kept as \(backup.lastPathComponent)")
        }
    }

    private func write(_ list: [ConnectionProfile]) {
        guard let storeURL else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(version: Self.version, profiles: list)) else { return }
        try? data.write(to: storeURL, options: .atomic)
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
