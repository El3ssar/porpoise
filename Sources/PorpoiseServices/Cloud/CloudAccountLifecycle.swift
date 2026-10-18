import Foundation

/// Why connecting or disconnecting a cloud account was refused, the same for every service.
public enum CloudConnectionError: LocalizedError, Equatable {
    /// The account signed in to is connected already (its id).
    case alreadyConnected(UUID)
    /// Signing in again chose a different account than the one being repaired.
    case wrongAccount
    /// A sign-in is still waiting in the browser.
    case busy
    /// Changes saved in another app haven't reached the service yet: signing out would lose them.
    case unsentEdits

    public var errorDescription: String? {
        switch self {
        case .alreadyConnected: return "This account is already connected."
        case .wrongAccount: return "Choose the same account you signed in with before."
        case .busy: return "A sign-in is already waiting in your browser. Finish or close it first."
        case .unsentEdits: return "Some changes haven’t been sent yet. Try again once they have."
        }
    }
}

extension CloudConnectError {
    /// A sign-in's failure as the Connect sheet and Accounts settings say it: closing the browser is no error, and an
    /// account already connected is named.
    static func from(_ error: Error, cancelled: (Error) -> Bool = { _ in false }, account: (UUID) -> CloudAccount?) -> CloudConnectError {
        if error is CancellationError || cancelled(error) { return .cancelled }
        if case .cancelled? = error as? CloudOAuthError { return .cancelled }
        if case .alreadyConnected(let id)? = error as? CloudConnectionError, let existing = account(id) { return .alreadyConnected(existing) }
        return .failed(error.localizedDescription)
    }
}

/// Each connected account's state as the sidebar shows it: OK, offline (steadied, so a flaky network doesn't flicker
/// it) or waiting to be signed in again, which only a successful request or a new sign-in clears.
@MainActor public final class CloudAccountStatus {
    public private(set) var statuses: [UUID: CloudAccount.Status] = [:]
    /// Called whenever a status changes.
    public var onChange: () -> Void = {}
    private var gates: [UUID: OfflineHysteresis] = [:]
    private var checks: [UUID: DispatchWorkItem] = [:]
    /// What time it is for the steadying. Tests move it on themselves, so what they see doesn't depend on how fast
    /// the machine runs (a stall between two requests looked like a network that had come back).
    var clock: () -> Date = Date.init

    public init() {}

    public subscript(id: UUID) -> CloudAccount.Status? { statuses[id] }

    /// A newly signed-in (or restored) account: OK.
    public func track(_ id: UUID) {
        gates[id] = OfflineHysteresis()
        checks.removeValue(forKey: id)?.cancel()
        set(id, .ok)
    }

    public func forget(_ id: UUID) {
        gates[id] = nil
        checks.removeValue(forKey: id)?.cancel()
        set(id, nil)
    }

    /// A request's result (nil: it succeeded). `signInNeeded`: the service refused the sign-in. `skipped`: the request
    /// never went (the client already knew it was offline). Only a request that never reached the service counts
    /// against the connection.
    public func record(_ id: UUID, _ error: Error?, signInNeeded: Bool = false, skipped: Bool = false) {
        guard gates[id] != nil else { return }
        if signInNeeded {
            // Until signed in again: a re-check scheduled before mustn't call it OK.
            checks.removeValue(forKey: id)?.cancel()
            set(id, .signInNeeded)
            return
        }
        if skipped { return }
        let reached: Bool
        switch error {
        case nil: reached = true
        case let failure as URLError:
            guard failure.code != .cancelled else { return }
            reached = false
        default: reached = true
        }
        if error == nil, statuses[id] == .signInNeeded { set(id, .ok) }
        _ = gates[id]?.record(reached: reached, at: clock())
        settle(id)
    }

    /// What the steadied connection says now, and when to look again.
    func settle(_ id: UUID) {
        guard var gate = gates[id] else { return }
        let now = clock()
        _ = gate.update(at: now)
        gates[id] = gate
        if statuses[id] != .signInNeeded { set(id, gate.isOffline ? .offline : .ok) }
        checks.removeValue(forKey: id)?.cancel()
        guard let next = gate.nextCheck(after: now) else { return }
        let check = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settle(id) } }
        checks[id] = check
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, next.timeIntervalSince(now)), execute: check)
    }

    private func set(_ id: UUID, _ status: CloudAccount.Status?) {
        guard statuses[id] != status else { return }
        statuses[id] = status
        onChange()
    }
}

/// The accounts kept between launches, with the client each signed in with (never a credential): a list in the
/// settings under the service's own key and field names, which stay as they were.
struct CloudAccountRecords<Account: Codable> {
    struct Record {
        var account: Account
        var clientID: String
    }
    let defaults: UserDefaults
    let key: String
    /// The record's field for the client ("clientID", "appKey").
    let clientField: String

    func load() -> [Record] {
        guard let data = defaults.data(forKey: key), let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let client = entry[clientField] as? String, let object = entry["account"],
                let bytes = try? JSONSerialization.data(withJSONObject: object), let account = try? JSONDecoder().decode(Account.self, from: bytes)
            else { return nil }
            return Record(account: account, clientID: client)
        }
    }

    func save(_ records: [Record]) throws {
        let raw = try records.map { record -> [String: Any] in
            [clientField: record.clientID, "account": try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.account))]
        }
        defaults.set(try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), forKey: key)
    }
}

/// What a sign-in's browser step listens on (Drive's adapter names its errors in Drive's words).
protocol CloudSignInListener {
    func finish(_ page: CloudOAuthPage)
    func cancel()
}
extension CloudOAuthLoopback: CloudSignInListener {}

/// One sign-in at a time per service, its browser page telling how it ended.
@MainActor final class CloudSignIn {
    private(set) var inProgress = false
    let provider: String
    init(provider: String) { self.provider = provider }

    func run<Listener: CloudSignInListener, Account>(
        listener make: () throws -> Listener, email: (Account) -> String, _ body: (Listener) async throws -> Account
    ) async throws -> Account {
        guard !inProgress else { throw CloudConnectionError.busy }
        inProgress = true
        defer { inProgress = false }
        var listener: Listener?
        defer { listener?.cancel() }
        do {
            let opened = try make()
            listener = opened
            let account = try await body(opened)
            opened.finish(.signedIn(provider: provider, account: email(account)))
            return account
        } catch {
            listener?.finish(.failed(provider: provider, reason: error.localizedDescription))
            throw error
        }
    }

    /// Signing in again must choose the same account; connecting must choose one not connected yet.
    nonisolated static func check(expected: UUID?, isExpected: Bool, existing: UUID?) throws {
        if expected != nil, !isExpected { throw CloudConnectionError.wrongAccount }
        if expected == nil, let existing { throw CloudConnectionError.alreadyConnected(existing) }
    }
}

/// What signing out leaves behind: nothing.
enum CloudAccountWipe {
    static func transfers(_ account: String) throws {
        let journals = RemoteFS.transferJournals + CloudTransferJournal.known
        for journal in Dictionary(journals.map { ($0.folder, $0) }, uniquingKeysWith: { a, _ in a }).values { try journal.forget(account: account) }
    }
    /// The account's offline copies and their index.
    @MainActor static func offlineCopies(_ account: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CloudOffline.shared.wipe(account: account) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Removes a folder, again if something was still being written into it as it went (a late listing).
    static func remove(_ folder: URL) throws {
        let fm = FileManager.default
        for attempt in 1...3 {
            guard fm.fileExists(atPath: folder.path) else { return }
            do {
                try fm.removeItem(at: folder)
                return
            } catch  where attempt < 3 { Thread.sleep(forTimeInterval: 0.05) }
        }
    }
}
